import AppKit
import os
import SwiftUI
import YeeHawCore

/// Opens the layout window, or brings it to the front if it's already open (one instance).
@MainActor
func showLayoutWindow(controller: MenuBarController, images: IconImageProvider, openSettings: @escaping () -> Void = {}) {
    let window = LayoutWindowController.current
        ?? LayoutWindowController(controller: controller, images: images, openSettings: openSettings)
    LayoutWindowController.current = window
    window.show()
}

/// The layout window (spec "The layout window", mockup B): a titled, closable window hosting
/// `LayoutView`, one instance, brought to the front when opened again. YeeHaw is a menu bar app:
/// it asks to be activated while the window is open and hands activation back when it closes,
/// and the window is a non-activating panel so it works even when macOS declines (see `activate`).
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
    private let window: NSWindow
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    /// Whether the window has been placed yet; later opens keep it where the user left it.
    private var placed = false

    init(controller: MenuBarController, images: IconImageProvider, openSettings: @escaping () -> Void) {
        model = LayoutModel(controller: controller, images: images, openSettings: openSettings)
        window = LayoutPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        let visibleWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let hosting = NSHostingController(rootView: LayoutView(
            model: model, maxRowWidth: visibleWidth - 2 * LayoutMetrics.windowPadding - 160))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.title = "Layout"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        window.delegate = self
    }

    func show() {
        let wasVisible = window.isVisible
        if !placed, let content = window.contentView {
            // Sized to its content first, so it's centred at its real size.
            content.layoutSubtreeIfNeeded()
            window.setContentSize(content.fittingSize)
            window.center()
            placed = true
        }
        // Regardless: YeeHaw usually isn't the active app (see `activate`).
        window.orderFrontRegardless()
        window.makeKey()
        activate()
        if !wasVisible {
            startObserving()
            refresh()
        }
    }

    /// Asks to bring YeeHaw to the front. On 27.2 WindowServer declines it after a status-menu
    /// click ("activation count being 0": the click went to the menu bar, not to YeeHaw), which is
    /// why the window is a non-activating panel: it comes to the front and takes the keyboard
    /// either way. When the activation is granted, the window works as an ordinary app window.
    private func activate() {
        NSApp.activate()
    }

    /// Call after the controller applied an Allow-list change from disk.
    func allowListChanged() {
        guard window.isVisible else { return }
        model.allowListChanged()
    }

    private func refresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [model] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await model.refresh()
        }
    }

    private func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh(after: Self.appChangeDelay) }
            })
        }
    }

    private func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers = []
        refreshTask?.cancel()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        guard !observers.isEmpty else { return } // The first show refreshes already.
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        stopObserving()
        model.windowClosed()
        // Back to a plain menu bar app: hand activation to whatever was in front before. Not
        // `hide`, which would keep the strip from opening until YeeHaw is activated again.
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.deactivate()
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
