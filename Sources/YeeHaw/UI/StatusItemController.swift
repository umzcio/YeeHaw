import AppKit
import os
import YeeHawCore

/// YeeHaw's own menu bar icon and the strip it opens (spec "Your menu bar icon", "The strip").
///
/// A plain click toggles the strip. Right-click, Control-click and Option-click show the small
/// menu (Layout…, Settings…, Quit YeeHaw); right-clicks were verified to arrive on macOS 27.2.
/// VoiceOver gets the same three as actions on the icon.
@MainActor
final class StatusItemController: NSObject {
    /// The status item's autosave name, which keeps YeeHaw's existing position key (`--reveal`'s
    /// stand-in icon uses it too).
    static let autosaveName = "YeeHaw"
    private nonisolated static let log = Logger(subsystem: Log.subsystem, category: "status")

    /// YeeHaw's own drawn item, the neighbour reveals open next to. Nil until it's drawn and has
    /// a position key.
    private(set) var yeehawItem: MenuBarItem?

    private let controller: MenuBarController
    private let reveal: RevealCoordinator
    private let openLayout: () -> Void
    private let openSettings: () -> Void
    private let icons: IconImageProvider
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var strip: StripPanel!
    /// Why the last click in the strip didn't open an app's menu, shown in the strip until it next
    /// closes or a reveal works.
    private var revealProblem: RevealProblem?
    /// Set when a click in the strip found no drawn YeeHaw icon to reveal next to.
    private var ownIconMissing = false
    private var refreshTask: Task<Void, Never>?
    /// Opens the menu straight from a secondary mouse-down (see `watchSecondaryClicks`).
    private var secondaryClickMonitor: Any?
    /// A click on the icon within this long after the strip closed by itself is the click that
    /// closed it, so it leaves the strip closed instead of reopening it.
    nonisolated static let reopenGuard: Duration = .milliseconds(300)

    init(controller: MenuBarController, reveal: RevealCoordinator, icons: IconImageProvider,
         openLayout: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.icons = icons
        self.reveal = reveal
        self.openLayout = openLayout
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        statusItem.autosaveName = Self.autosaveName
        if let button = statusItem.button {
            button.image = StatusGlyph.image()
            button.setAccessibilityLabel("YeeHaw")
            button.setAccessibilityHelp("Shows the hidden menu bar icons")
            button.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Open Layout") { [weak self] in self?.layoutChosen(); return true },
                NSAccessibilityCustomAction(name: "Open Settings") { [weak self] in self?.settingsChosen(); return true },
                NSAccessibilityCustomAction(name: "Quit YeeHaw") { [weak self] in self?.quitChosen(); return true },
            ])
            button.target = self
            button.action = #selector(iconClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        buildMenu()
        watchSecondaryClicks()
        strip = StripPanel(
            sampler: .shared,
            onSelect: { [weak self] id in self?.select(id) },
            onNoticeAction: { [weak self] action in self?.noticeAction(action) },
            onLayout: { [weak self] in self?.layoutChosen() },
            onSettings: { [weak self] in self?.settingsChosen() },
            onQuit: { [weak self] in self?.quitChosen() })
        // A problem is shown once, in the strip that opens after it; closing that strip clears it.
        strip.onDismiss = { [weak self] in
            self?.revealProblem = nil
            self?.ownIconMissing = false
        }
        // Photograph a revealed item while it's drawn; a hidden one can't be photographed later.
        reveal.onDrawn = { [icons] item in await icons.captureIfPermitted([item]) }
    }

    /// Call before `controller.launch()`: photographs the saved hidden apps that are drawn right
    /// now (after a quit switched them back on), before the launch hides them again.
    /// Static: it runs before YeeHaw's own icon is shown (`LaunchRules.steps`).
    static func captureHiddenBeforeLaunch(controller: MenuBarController, icons: IconImageProvider) async {
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

    nonisolated static func isPointerEvent(_ type: NSEvent.EventType?) -> Bool {
        guard let type else { return false }
        return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp].contains(type)
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
        // Opened without the pointer (VoiceOver, Full Keyboard Access): light the first tile.
        case .open: openStrip(highlightFirst: !Self.isPointerEvent(event?.type))
        case .stayClosed: break
        }
    }

    /// Opens the menu from the mouse-down itself and consumes it, so the button never starts
    /// tracking that click. Opened from the button's action instead, the menu takes the click's
    /// mouse-up and the button keeps tracking afterwards, which swallows the next mouse-down
    /// anywhere in YeeHaw (the Layout window's first drag). `iconClicked` stays as the fallback.
    private func watchSecondaryClicks() {
        secondaryClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let (type, modifiers, window) = (event.type, event.modifierFlags, event.windowNumber)
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let button = self.statusItem.button, window == button.window?.windowNumber,
                      Self.isSecondaryClick(type: type, modifiers: modifiers) else { return false }
                self.showMenu()
                return true
            }
            return consumed ? nil : event
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
            ("Layout…", #selector(layoutChosen), "l"),
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

    private func openStrip(highlightFirst: Bool = false) {
        guard let button = statusItem.button, let window = button.window else { return }
        // Hidden with Hide YeeHaw (while a window was open), no window of YeeHaw's shows,
        // the strip included, until it's unhidden.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        strip.show(below: anchor, items: entries(), notice: currentNotice(), screen: window.screen,
                   highlightFirst: highlightFirst)

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

    /// The hidden apps, in strip order. Only apps YeeHaw switched off: one the user switched off
    /// in System Settings is theirs and never shows here.
    private func entries() -> [StripEntry] {
        controller.state.hidden.filter(controller.state.journal.contains).map { id in
            StripEntry(id: id, image: icons.image(for: id), name: AppIdentity.name(of: id),
                       isRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty)
        }
    }

    /// Why a click in the strip didn't open an app's menu.
    enum RevealProblem: Equatable {
        /// macOS didn't draw the app in time.
        case didNotAppear(BundleID)
        /// The app isn't running, so it has no icon.
        case notRunning(BundleID)
        /// Anything else (an unreadable file, no position for YeeHaw's icon yet).
        case failed(BundleID)
    }

    private func currentNotice() -> StripNotice? {
        Self.notice(needsGrant: controller.state.needsGrant, problem: revealProblem, ownIconMissing: ownIconMissing,
                    name: AppIdentity.name(of:))
    }

    /// The strip's notice, most pressing first: a missing grant (Settings fixes it), then why the
    /// last click failed, each with the button that helps, if one can.
    static func notice(needsGrant: Set<GrantedFile>, problem: RevealProblem?, ownIconMissing: Bool,
                       name: (BundleID) -> String) -> StripNotice? {
        if !needsGrant.isEmpty {
            let files = [GrantedFile.allowList, .positions].filter(needsGrant.contains)
                .compactMap(AppPermission.init(file:)).map(\.title)
            return StripNotice(message: "YeeHaw needs access to the \(files.joined(separator: " and the ")).",
                               action: .openSettings)
        }
        switch problem {
        case .didNotAppear(let id):
            return StripNotice(message: "\(name(id)) didn’t appear in the menu bar in time.", action: .retry(id))
        case .notRunning(let id):
            return StripNotice(message: "\(name(id)) isn’t open, so it has no menu to show.", action: .openApp(id))
        case .failed(let id):
            return StripNotice(message: "YeeHaw couldn’t show \(name(id))’s menu.")
        case nil:
            break
        }
        if ownIconMissing { return StripNotice(message: "YeeHaw can’t find its own menu bar icon.") }
        return nil
    }

    private func noticeAction(_ action: StripNotice.Action) {
        strip.dismiss()
        switch action {
        case .openSettings:
            openSettings()
        case .retry(let id):
            select(id)
        case .openApp(let id):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Self.log.error("Could not open \(id, privacy: .public): \(error, privacy: .public)") }
            }
        }
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
                reportProblem(nil, ownIconMissing: true)
                return
            }
            switch await reveal.open(id, nextTo: yeehaw) {
            case .revealed:
                revealProblem = nil
            case .ignored:
                break
            case .failed(ControllerError.notHonored(let failed)):
                reportProblem(.didNotAppear(failed))
            case .failed(ControllerError.notRunning(let failed)):
                reportProblem(.notRunning(failed))
            case .failed(ControllerError.needsGrant):
                reportProblem(nil) // The grant notice says it.
            case .failed:
                reportProblem(.failed(id))
            }
        }
    }

    /// Opens the strip again with the notice, so a click that came to nothing says why.
    private func reportProblem(_ problem: RevealProblem?, ownIconMissing: Bool = false) {
        strip.dismiss()
        revealProblem = problem
        self.ownIconMissing = ownIconMissing
        openStrip()
    }
}
