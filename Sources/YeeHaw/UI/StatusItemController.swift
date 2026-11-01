import AppKit
import os
import YeeHawCore

/// YeeHaw's own menu bar icon and the strip it opens (spec "Your menu bar icon", "The strip").
///
/// A plain click toggles the strip. Right-click, Control-click and Option-click show the small
/// menu (Layout…, Settings…, Quit YeeHaw), which the strip's "…" button also shows, in case 27.2
/// stops delivering right-clicks to status items (ruling R36).
@MainActor
final class StatusItemController: NSObject {
    /// The status item's autosave name. It keeps YeeHaw's existing position key (R29).
    static let autosaveName = "YeeHaw"
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "status")

    /// YeeHaw's own drawn item, the neighbour reveals open next to. Nil until it's drawn and has
    /// a position key.
    private(set) var yeehawItem: MenuBarItem?

    private let controller: MenuBarController
    private let reveal: RevealCoordinator
    private let openLayout: () -> Void
    private let openSettings: () -> Void
    private let icons = IconImageProvider()
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var strip: StripPanel!
    /// The last reveal's failure, when macOS didn't draw the app in time; cleared by a success.
    private var revealFailure: BundleID?
    /// Set when a click in the strip found no drawn YeeHaw icon to reveal next to.
    private var ownIconMissing = false
    private var refreshTask: Task<Void, Never>?
    /// A click on the icon within this long after the strip closed by itself is the click that
    /// closed it (ruling I2), so it leaves the strip closed instead of reopening it.
    nonisolated static let reopenGuard: Duration = .milliseconds(300)

    init(controller: MenuBarController, reveal: RevealCoordinator, openLayout: @escaping () -> Void,
         openSettings: @escaping () -> Void) {
        self.controller = controller
        self.reveal = reveal
        self.openLayout = openLayout
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        if let button = statusItem.button {
            button.image = StatusGlyph.image()
            button.setAccessibilityLabel("YeeHaw")
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        buildMenu()
        strip = StripPanel(
            menu: menu,
            onSelect: { [weak self] id in self?.select(id) },
            onFix: { [weak self] in
                self?.strip.dismiss()
                self?.openSettings()
            })
        // Photograph a revealed item while it's drawn; a hidden one can't be photographed later.
        reveal.onDrawn = { [icons] item in await icons.captureIfPermitted([item]) }
    }

    /// Call before `controller.launch()`: photographs the saved hidden apps that are drawn right
    /// now (after a quit switched them back on), before the launch hides them again (ruling I3).
    func captureHiddenBeforeLaunch() async {
        let hidden = Set(controller.state.hidden)
        guard !hidden.isEmpty, CGPreflightScreenCaptureAccess() else { return }
        await controller.refresh()
        await icons.captureIfPermitted(controller.items.filter { $0.bundleID.map(hidden.contains) ?? false })
    }

    /// Call once the controller has launched: finds YeeHaw's own drawn item (waiting for its
    /// position key) and photographs the third-party items that are drawn.
    func start(grants: FileGrantStore) async {
        yeehawItem = await OwnIconLocator.waitUntilReady(grants: grants) { Self.log.notice("\($0, privacy: .public)") }
        await controller.refresh()
        await icons.captureIfPermitted(controller.items)
    }

    /// Whether a click on the icon asks for the menu rather than the strip.
    nonisolated static func isSecondaryClick(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) -> Bool {
        type == .rightMouseDown || type == .rightMouseUp
            || !modifiers.intersection([.control, .option]).isEmpty
    }

    enum ClickAction: Equatable { case open, close, stayClosed }

    /// What a plain click on the icon does. `sinceAutoDismissal` is how long ago the strip closed
    /// by itself (nil if it never did).
    nonisolated static func clickAction(stripShown: Bool, sinceAutoDismissal: Duration?) -> ClickAction {
        if stripShown { return .close }
        if let since = sinceAutoDismissal, since < reopenGuard { return .stayClosed }
        return .open
    }

    // MARK: Icon

    @objc private func iconClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if Self.isSecondaryClick(type: event?.type ?? .leftMouseDown, modifiers: event?.modifierFlags ?? []) {
            showMenu()
            return
        }
        switch Self.clickAction(stripShown: strip.isShown,
                                sinceAutoDismissal: strip.lastAutoDismissal.map { .now - $0 }) {
        case .close: strip.dismiss()
        case .open: openStrip()
        case .stayClosed: break
        }
    }

    private func showMenu() {
        strip.dismiss()
        // Attached only for this click, so a plain click keeps toggling the strip.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() {
        let items: [(String, Selector, String)] = [
            ("Layout…", #selector(layoutChosen), ""),
            ("Settings…", #selector(settingsChosen), ","),
        ]
        for (title, action, key) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit YeeHaw", action: #selector(quitChosen), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func layoutChosen() {
        strip.dismiss()
        openLayout()
    }

    @objc private func settingsChosen() {
        strip.dismiss()
        openSettings()
    }

    /// Switches back on everything YeeHaw switched off, then quits.
    @objc private func quitChosen() {
        strip.dismiss()
        do {
            try controller.quit()
        } catch {
            Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
        }
        NSApp.terminate(nil)
    }

    // MARK: Strip

    private func openStrip() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        strip.show(below: anchor, items: entries(), notice: notice(), screen: window.screen)

        // Re-read the bar in the background: YeeHaw's icon may have moved, and drawn items get
        // fresh photographs. The strip itself opens at once from the saved state.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await controller.refresh()
            if let drawn = OwnIconLocator.drawn(in: controller.items) {
                yeehawItem = drawn
                ownIconMissing = false
            }
            await icons.captureIfPermitted(controller.items)
        }
    }

    /// The hidden apps, in strip order.
    private func entries() -> [StripEntry] {
        controller.state.hidden.map { StripEntry(id: $0, image: icons.image(for: $0), name: Self.name(of: $0)) }
    }

    private func notice() -> String? {
        if !controller.state.needsGrant.isEmpty {
            return "YeeHaw needs access to the menu bar settings files."
        }
        if let id = revealFailure {
            return "\(Self.name(of: id)) didn't appear in the menu bar in time."
        }
        if ownIconMissing {
            return "YeeHaw can't find its own menu bar icon."
        }
        return nil
    }

    private func select(_ id: BundleID) {
        strip.dismiss()
        Task {
            if yeehawItem == nil {
                await controller.refresh()
                yeehawItem = OwnIconLocator.drawn(in: controller.items)
            }
            guard let yeehaw = yeehawItem else {
                Self.log.error("Cannot open \(id, privacy: .public): YeeHaw's own icon isn't drawn")
                ownIconMissing = true
                return
            }
            ownIconMissing = false
            switch await reveal.open(id, nextTo: yeehaw) {
            case .revealed:
                revealFailure = nil
            case .failed(ControllerError.notHonored(let failed)):
                revealFailure = failed
            case .failed, .ignored:
                break
            }
        }
    }

    private static func name(of id: BundleID) -> String {
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url.deletingPathExtension().lastPathComponent
        }
        return id
    }
}
