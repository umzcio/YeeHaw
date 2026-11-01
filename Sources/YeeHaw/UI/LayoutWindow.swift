import AppKit
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
/// `LayoutView`, one instance, brought to the front when opened again. While it's open YeeHaw is
/// a regular app (see `AppWindows`).
///
/// It reflects outside changes: it re-reads the bar when it becomes key, when an app launches or
/// quits, and when the Allow list changes on disk (`allowListChanged`).
@MainActor
final class LayoutWindowController: NSObject, NSWindowDelegate {
    /// The open (or last opened) window; it's kept and reused.
    static var current: LayoutWindowController?
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
        window = AuxiliaryPanel(width: 560, title: "Layout")
        super.init()

        let hosting = NSHostingController(rootView: LayoutView(model: model, spacing: spacing))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
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
        // Regardless: YeeHaw usually isn't the active app (see `AppWindows.bringForward`).
        AppWindows.bringForward(window, name: "Layout")
        if !wasVisible {
            startObserving()
            refresh()
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
        AppWindows.windowClosing()
    }
}
