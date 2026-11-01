import AppKit
import os
import SwiftUI
import YeeHawCore

/// Opens the layout window, or brings it to the front if it's already open (one instance).
/// `requestGrant` asks for a file grant again, for the "Fix…" of a missing-grant message.
@MainActor
func showLayoutWindow(controller: MenuBarController, images: IconImageProvider,
                      requestGrant: @escaping (GrantedFile) async -> Bool = { _ in false }) {
    let window = LayoutWindowController.current
        ?? LayoutWindowController(controller: controller, images: images, requestGrant: requestGrant)
    LayoutWindowController.current = window
    window.show()
}

/// The layout window (spec "The layout window", mockup B): a titled, closable window hosting
/// `LayoutView`, one instance, brought to the front when opened again. YeeHaw is a menu bar app:
/// while the window is open it becomes a regular app (in Command-Tab, with its own menus) and
/// activates; when it closes it hands activation back and returns to the menu bar. The window is
/// a non-activating panel, so it still comes to the front and takes the keyboard if macOS
/// declines the activation (see `activate`).
///
/// It reflects outside changes: it re-reads the bar when it becomes key, when an app launches or
/// quits, and when the Allow list changes on disk (`allowListChanged`).
@MainActor
final class LayoutWindowController: NSObject, NSWindowDelegate {
    /// The open (or last opened) window; it's kept and reused.
    static var current: LayoutWindowController?
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "layout")
    /// After an app launches or quits, how long to wait before re-reading the bar, so its icon
    /// has been drawn or removed.
    static let appChangeDelay: Duration = .milliseconds(800)

    private let model: LayoutModel
    private let spacing: SpacingModel
    private let window: NSWindow
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    /// Watches the window's own key and mouse-down events, to show the focus ring only for the
    /// keyboard.
    private var inputMonitor: Any?
    /// Polls the Esc key while a tile is dragged (see `watchEscape`).
    private var escapeWatch: Timer?
    /// Whether the window has been placed yet; later opens keep it where the user left it.
    private var placed = false

    init(controller: MenuBarController, images: IconImageProvider, requestGrant: @escaping (GrantedFile) async -> Bool) {
        model = LayoutModel(controller: controller, images: images, requestGrant: requestGrant)
        spacing = SpacingModel(applier: SpacingApplier(hidden: { Set(controller.state.hidden) }))
        window = LayoutPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        let hosting = NSHostingController(rootView: LayoutView(model: model, spacing: spacing))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.title = "Layout"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
        model.onDraggingChange = { [weak self] dragging in self?.watchEscape(dragging) }
        // Apps quit and reopen during Apply; read the list again once it's done.
        spacing.onApplied = { [weak self] in self?.refresh() }
        // Layout edits wait while Apply restarts apps.
        spacing.onApplyingChange = { [weak model] applying in model?.spacingBusy = applying }
    }

    func show() {
        let wasVisible = window.isVisible
        updateMaxRowWidth()
        if !placed, let content = window.contentView {
            // Sized to its content first, so it's centred at its real size.
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
            window.center()
            placed = true
        }
        // Regardless: YeeHaw usually isn't the active app (see `activate`).
        activate()
        window.orderFrontRegardless()
        window.makeKey()
        if !wasVisible {
            startObserving()
            refresh()
        }
    }

    /// Makes YeeHaw a regular app while the window is open, so it's in Command-Tab and has its
    /// own menus, and brings it to the front.
    ///
    /// On 27.2 the plain request is refused when the window opens from the status menu
    /// (WindowServer: "activation count being 0"), and so is a request made while the menu is
    /// still closing. Asked again once the menu has gone, ignoring other apps (the user just chose
    /// Layout…), it's granted. Should it ever be declined, the window, a non-activating panel,
    /// still comes to the front and takes the keyboard.
    private func activate() {
        if NSApp.activationPolicy() != .regular {
            NSApp.mainMenu = NSApp.mainMenu ?? Self.mainMenu()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        Task { [weak self] in
            try? await Task.sleep(for: Self.activationRetryDelay)
            guard let self, self.window.isVisible else { return }
            if NSWorkspace.shared.frontmostApplication != .current {
                NSApp.activate(ignoringOtherApps: true)
            }
            try? await Task.sleep(for: .milliseconds(200))
            let active = NSWorkspace.shared.frontmostApplication == .current
            Self.log.notice("Layout window open; YeeHaw frontmost: \(active, privacy: .public)")
        }
    }

    static let escapeKeyCode: CGKeyCode = 53

    /// Esc cancels a drag. While SwiftUI tracks a drag, macOS doesn't deliver key events to the
    /// window at all (measured on 27.2: an Esc pressed mid-drag never arrived, not even after the
    /// mouse-up), so the key's state is polled instead, only while a drag is under way.
    private func watchEscape(_ dragging: Bool) {
        escapeWatch?.invalidate()
        escapeWatch = nil
        guard dragging else { return }
        var wasDown = CGEventSource.keyState(.combinedSessionState, key: Self.escapeKeyCode)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let down = CGEventSource.keyState(.combinedSessionState, key: Self.escapeKeyCode)
                if down, !wasDown { self?.model.requestDragCancel() }
                wasDown = down
            }
        }
        // Common modes: the timer keeps firing while the mouse is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        escapeWatch = timer
    }

    /// How long after opening to ask for activation again: the status menu has closed by then.
    static let activationRetryDelay: Duration = .milliseconds(150)

    /// The menus YeeHaw shows while it's a regular app: Quit, and the window's Close.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "YeeHaw")
        app.addItem(withTitle: "Quit YeeHaw", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        for menu in [app, window] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = window
        return main
    }

    /// The rows may grow to the width of the screen the window is on, less a margin, and the
    /// content to its height less the title bar and a margin; beyond that the content scrolls.
    private func updateMaxRowWidth() {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        model.maxRowWidth = visible.width - 2 * LayoutMetrics.windowPadding - 160
        let titleBar = window.frameRect(forContentRect: .zero).height
        model.maxContentHeight = max(visible.height - titleBar - Self.screenMargin, 240)
    }

    /// Room kept free above and below the window when it's as tall as the screen allows.
    static let screenMargin: CGFloat = 24

    /// Call after the controller applied an Allow-list change from disk.
    func allowListChanged() {
        guard window.isVisible else { return }
        model.allowListChanged()
    }

    private func refresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [model, spacing] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await model.refresh()
            spacing.reloadCurrent()
            let controller = model.controller
            spacing.setApps(await RunningMenuBarApps.list(drawn: controller.items, hidden: controller.state.hidden,
                                                         exempt: spacing.applier.hiddenAfterRestart))
        }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(after: Self.appChangeDelay) }
            })
        }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, event.window === self.window else { return event }
            let fromKeyboard = event.type == .keyDown
            if self.model.showsFocusRing != fromKeyboard { self.model.showsFocusRing = fromKeyboard }
            return event
        }
    }

    private func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
        refreshTask?.cancel()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !observers.isEmpty else { return } // The first show refreshes already.
        refresh()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateMaxRowWidth()
    }

    func windowWillClose(_ notification: Notification) {
        stopObserving()
        model.windowClosed()
        spacing.windowClosed()
        // Back to a plain menu bar app: hand activation to whatever was in front before, then
        // leave Command-Tab and the Dock. Not `hide`, which would keep the strip from opening
        // until YeeHaw is activated again.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.deactivate()
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// The layout window: a titled panel that looks and orders like a standard window but can be key
/// without YeeHaw being the active app. YeeHaw has no main menu while it's a menu bar app, so
/// Command-W is handled here.
private final class LayoutPanelWindow: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
