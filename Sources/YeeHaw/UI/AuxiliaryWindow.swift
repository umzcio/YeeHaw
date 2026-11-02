import AppKit
import os

/// How YeeHaw's windows (Layout, Settings, onboarding) come forward and go away. YeeHaw is a menu
/// bar app: while one of them is open it becomes a regular app (in Command-Tab, with its own
/// menus) and activates; when the last one closes it hands activation back and returns to the
/// menu bar.
@MainActor
enum AppWindows {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "windows")

    /// How long after opening to ask for activation again: the status menu has closed by then.
    static let activationRetryDelay: Duration = .milliseconds(150)

    /// Chosen from the app menu's Settings… while YeeHaw is a regular app.
    static var openSettings: (() -> Void)?

    /// Makes YeeHaw a regular app and brings `window` to the front, key.
    ///
    /// On 27.2 the plain activation request is refused when a window opens from the status menu
    /// (WindowServer: "activation count being 0"), and so is a request made while the menu is
    /// still closing. Asked again once the menu has gone, ignoring other apps (the user just chose
    /// the window), it's granted. Should it ever be declined, the window, a non-activating panel,
    /// still comes to the front and takes the keyboard.
    static func bringForward(_ window: NSWindow, name: String) {
        if NSApp.activationPolicy() != .regular {
            NSApp.mainMenu = NSApp.mainMenu ?? mainMenu()
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
        Task { [weak window] in
            try? await Task.sleep(for: activationRetryDelay)
            guard let window, window.isVisible else { return }
            if NSWorkspace.shared.frontmostApplication != .current {
                NSApp.activate(ignoringOtherApps: true)
            }
            try? await Task.sleep(for: .milliseconds(200))
            let active = NSWorkspace.shared.frontmostApplication == .current
            log.notice("\(name, privacy: .public) window open; YeeHaw frontmost: \(active, privacy: .public)")
        }
    }

    /// Call from `windowWillClose`. Once no YeeHaw window is left open, hands activation to
    /// whatever was in front before and leaves Command-Tab and the Dock. Not `hide`, which would
    /// keep the strip from opening until YeeHaw is activated again. (The About panel can't become
    /// main, so it doesn't hold YeeHaw in the Dock.)
    static func windowClosing() {
        DispatchQueue.main.async {
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSApp.deactivate()
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    /// The menus YeeHaw shows while it's a regular app: the standard app menu (About, Settings…,
    /// Hide, Quit) and the window's Close.
    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: "YeeHaw")
        app.addItem(withTitle: "About YeeHaw", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuActions.openSettings), keyEquivalent: ",")
        settings.target = MenuActions.shared
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide YeeHaw", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
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

    @MainActor
    private final class MenuActions: NSObject {
        static let shared = MenuActions()
        @objc func openSettings() { AppWindows.openSettings?() }
    }
}

/// A titled panel that looks and orders like a standard window but can be key without YeeHaw
/// being the active app. YeeHaw has no main menu while it's a menu bar app, so Command-W is
/// handled here.
final class AuxiliaryPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType,
                  defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isFloatingPanel = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        isRestorable = false
        tabbingMode = .disallowed
        collectionBehavior.insert(.fullScreenNone)
    }

    /// A titled, closable panel of `width`, its content hosted from SwiftUI.
    convenience init(width: CGFloat, title: String) {
        self.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                  styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
        self.title = title
        titlebarAppearsTransparent = true
    }

    /// When the content changes height (onboarding's steps opening and closing), grow and shrink
    /// at the bottom and keep the title bar where it is, rather than AppKit's fixed bottom edge.
    var keepsTopEdge = false

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(pinnedToTop(frameRect), display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(pinnedToTop(frameRect), display: displayFlag, animate: animateFlag)
    }

    /// A resize in place (same origin, new height) moved so the top edge stays put.
    private func pinnedToTop(_ rect: NSRect) -> NSRect {
        guard keepsTopEdge, isVisible, rect.origin == frame.origin, rect.height != frame.height else { return rect }
        var pinned = rect
        pinned.origin.y = frame.maxY - rect.height
        return pinned
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
