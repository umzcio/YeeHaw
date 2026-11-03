import AppKit
import ApplicationServices
import os
import YeeHawCore

/// Opens a hidden app's menu from its real icon (spec "Clicking an icon", option B): the icon is
/// revealed right next to YeeHaw's, pressed, and hidden again once the app is done with its menu.
@MainActor
final class RevealCoordinator {
    /// An inactivity timeout, not a hard limit: it restarts on the app's own activity (a menu or
    /// window opening, a click inside its windows), so someone still working in a window the reveal
    /// opened isn't cut off. The reveal ends after this long with no such activity.
    static let inactivityTimeout: Double = 30
    /// How often a reveal checks whether the app's menu or popover is still on screen.
    static let windowPollInterval: Double = 0.25
    /// How long one AX press may block. An app busy tracking the menu it just opened can run past
    /// this and return `-25204`, so a timeout isn't treated as a failure.
    nonisolated static let pressTimeout: Float = 0.2
    /// After a failed press, how long to wait for a menu or window before trying the next method.
    static let pressGrace: Double = 0.3
    /// Between a synthesized click's pointer move, press and release.
    nonisolated static let clickSettle: Duration = .milliseconds(60)
    /// How long to keep re-reading the app's extras bar when the revealed item isn't in it yet.
    static let findTimeout: Double = 0.5
    static let findInterval: Double = 0.1
    /// Before retrying a failed `endReveal`.
    static let endRetryDelay: Double = 1
    private static let log = Logger(subsystem: Log.subsystem, category: "reveal")

    private let controller: MenuBarController
    private let trace: @MainActor (String) -> Void
    private var busy = false
    /// The click waiting for the open reveal to end: resumed with true to run next, or false when
    /// a later click replaced it.
    private var waiting: CheckedContinuation<Bool, Never>?

    /// Awaited just before the press (the strip's fade-out has to finish first; see
    /// `StripPanel.waitUntilOffScreen`).
    var beforePress: (@MainActor () async -> Void)?

    /// `trace` receives each step with its timing; debug runs write it to probe.txt.
    init(controller: MenuBarController, trace: @escaping @MainActor (String) -> Void = { _ in }) {
        self.controller = controller
        self.trace = trace
    }

    /// How a call to `open` went, as far as the app appearing is concerned.
    enum Outcome {
        /// The app was drawn next to YeeHaw (whatever happened with the press afterwards).
        case revealed
        /// A later click replaced this one while it waited for the open reveal to end.
        case ignored
        /// `beginReveal` threw; the reveal was ended.
        case failed(Error)
    }

    /// Reveal → press → wait until the app is done with its menu → `endReveal`. A click made while
    /// a reveal is open (or still ending) waits for it and then runs, so two reveals never share
    /// the controller's one slot and the click isn't lost; only the latest waiting click runs.
    @discardableResult
    func open(_ id: BundleID, nextTo yeehaw: MenuBarItem) async -> Outcome {
        let start = ContinuousClock.now
        let step: @MainActor (String) -> Void = { [trace] text in
            let line = "reveal \(id) +\(Self.milliseconds(ContinuousClock.now - start)) ms: \(text)"
            Self.log.notice("\(line, privacy: .public)")
            trace(line)
        }
        if busy {
            step("waiting for the open reveal to end")
            waiting?.resume(returning: false)
            let runs = await withCheckedContinuation { waiting = $0 }
            guard runs else {
                step("replaced by a later click")
                return .ignored
            }
        } else {
            busy = true
        }
        defer { handOff() }
        return await run(id, nextTo: yeehaw, step: step)
    }

    /// Passes the coordinator to the waiting click, if any (it stays busy), else frees it.
    private func handOff() {
        if let next = waiting {
            waiting = nil
            next.resume(returning: true)
        } else {
            busy = false
        }
    }

    private func run(_ id: BundleID, nextTo yeehaw: MenuBarItem, step: @escaping @MainActor (String) -> Void) async -> Outcome {
        controller.revealTrace = { text in MainActor.assumeIsolated { step(text) } }
        defer { controller.revealTrace = nil }

        let item: MenuBarItem
        do {
            item = try await controller.beginReveal(id, nextTo: yeehaw)
        } catch {
            // endReveal is a no-op with nothing pending, and finishes a reveal the controller
            // couldn't undo itself (a failed write after the slot was taken, or a failed undo).
            step("beginReveal failed: \(error)")
            await end(step)
            return .failed(error)
        }
        step("reveal done, drawn at x \(item.x) width \(item.width)")

        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else {
            step("app is not running")
            await end(step)
            return .revealed
        }
        let session = RevealSession(pid: pid)
        session.onFirstSurface = { what in step("\(what) (first menu or window on screen)") }
        if !session.isObserving { step("AX observer unavailable; only clicks and the timeout can end it") }

        if let beforePress {
            await beforePress()
            step("strip off screen")
        }
        if await press(item, pid: pid, session: session, step: step) {
            session.startWatching(icon: item.x...(item.x + item.width))
            step("close: \(await session.waitForClose())")
        }
        session.tearDown()
        await end(step)
        return .revealed
    }

    /// `endReveal`, retried once after `endRetryDelay`. It runs in its own unstructured task so a
    /// cancelled caller can't cut it short: `TaskSleeper` ignores cancellation, so the controller's
    /// polls would race through, and the retry's sleep would be skipped.
    private func end(_ step: @escaping @MainActor (String) -> Void) async {
        let controller = controller
        await Task { @MainActor in
            do {
                try await controller.endReveal()
                step("endReveal done")
                return
            } catch {
                step("endReveal failed: \(error); retrying in \(Int(Self.endRetryDelay)) s")
            }
            try? await Task.sleep(for: .seconds(Self.endRetryDelay))
            do {
                try await controller.endReveal()
                step("endReveal done on retry")
            } catch {
                let message = "ERROR: endReveal failed twice (\(error)). The app may be left on and its "
                    + "position unrestored; the pending reveal stays saved for the next launch to finish."
                Self.log.fault("\(message, privacy: .public)")
                step(message)
            }
        }.value
    }

    // MARK: Pressing

    private enum PressMethod: String, CaseIterable {
        case axPress = "AXPress"
        case showMenu = "AXShowMenu"
        case click = "synthesized click"
    }

    private enum PressResult: Sendable {
        case done
        case failed(Int32)
        case notFound
    }

    /// AX press, then `AXShowMenu`, then a synthesized click, each logged with its duration and
    /// result. A failed method falls through only if no menu or window appeared, since the app may
    /// have opened it while the call timed out. Returns whether the press got through.
    private func press(_ item: MenuBarItem, pid: pid_t, session: RevealSession,
                       step: @MainActor (String) -> Void) async -> Bool {
        for method in PressMethod.allCases {
            let started = ContinuousClock.now
            var result = await Self.perform(method, pid: pid, x: item.x, width: item.width)
            // The app's extras bar can lag behind what's drawn; re-read it for a moment.
            while case .notFound = result, ContinuousClock.now - started < .seconds(Self.findTimeout), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.findInterval))
                result = await Self.perform(method, pid: pid, x: item.x, width: item.width)
            }
            let took = Self.milliseconds(ContinuousClock.now - started)
            switch result {
            case .notFound:
                step("press \(method.rawValue): no extras-bar element at x \(item.x) width \(item.width) after \(took) ms")
                return false
            case .done where method == .click:
                step("press \(method.rawValue): click posted in \(took) ms; notifications so far: \(session.seenSummary)")
                return true
            case .done:
                step("press \(method.rawValue): worked in \(took) ms; notifications so far: \(session.seenSummary)")
                if !session.surfaceOpened {
                    try? await Task.sleep(for: .seconds(Self.pressGrace))
                }
                if session.surfaceOpened { return true }
                // A SwiftUI MenuBarExtra (Fiddle) takes AXPress without error and opens nothing:
                // it only opens on a real click. AXShowMenu does no better, so click.
                step("press \(method.rawValue): nothing opened within \(Int(Self.pressGrace * 1000)) ms; clicking")
                let clicked = await Self.perform(.click, pid: pid, x: item.x, width: item.width)
                if case .done = clicked {
                    step("press \(PressMethod.click.rawValue): click posted")
                    return true
                }
                step("press \(PressMethod.click.rawValue): \(clicked)")
                return false
            case .failed(let code):
                if !session.surfaceOpened {
                    try? await Task.sleep(for: .seconds(Self.pressGrace))
                }
                step("press \(method.rawValue): returned \(code) after \(took) ms; "
                     + "notifications by the grace check: \(session.seenSummary)")
                if session.surfaceOpened {
                    step("press \(method.rawValue): the app opened its menu or window anyway")
                    return true
                }
            }
        }
        step("press: every method failed")
        return false
    }

    /// Re-reads the app's extras-bar children and acts on the one at the revealed item's frame.
    /// Runs off the main actor: AX calls block, and the app's notifications arrive on the main run
    /// loop while they do.
    @concurrent
    private static func perform(_ method: PressMethod, pid: pid_t, x: Double, width: Double) async -> PressResult {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, AXMenuBarReader.appTimeout)
        let extras = AXMenuBarReader.element(app, kAXExtrasMenuBarAttribute).map { AXMenuBarReader.children(of: $0) } ?? []
        guard let element = extras.first(where: {
            let frame = AXMenuBarReader.frame(of: $0)
            return abs(frame.minX - x) <= ItemMatcher.tolerance && abs(frame.width - width) <= ItemMatcher.tolerance
        }) else { return .notFound }

        switch method {
        case .axPress, .showMenu:
            AXUIElementSetMessagingTimeout(element, pressTimeout)
            let action = method == .axPress ? kAXPressAction : kAXShowMenuAction
            let error = AXUIElementPerformAction(element, action as CFString)
            return error == .success ? .done : .failed(error.rawValue)
        case .click:
            let frame = AXMenuBarReader.frame(of: element)
            // The pointer goes back where it was once the click is through.
            guard let pointer = CGEvent(source: nil)?.location,
                  await postClick(at: CGPoint(x: frame.midX, y: frame.midY))
            else { return .failed(0) }
            try? await Task.sleep(for: .milliseconds(50))
            CGWarpMouseCursorPosition(pointer)
            return .done
        }
    }

    /// A left click at a point in global top-left coordinates (the same space as AX frames).
    /// Posted like a person's click: the pointer arrives, then a press and release with a gap.
    /// MenuBarAgent ignores a bare down/up pair posted at once at a point the pointer never
    /// reached: it ran its own action and forwarded nothing, so Fiddle's MenuBarExtra never opened.
    private nonisolated static func postClick(at point: CGPoint) async -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        move.post(tap: .cghidEventTap)
        try? await Task.sleep(for: clickSettle)
        down.post(tap: .cghidEventTap)
        try? await Task.sleep(for: clickSettle)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }
}

/// One reveal's close signals. The first one to arrive wins; `tearDown` removes them all.
///
/// The app is done with its menu on: `AXMenuClosed` for its outermost menu; its popover or window
/// losing focus (`AXFocusedWindowChanged`) or being destroyed (`AXUIElementDestroyed`); the app
/// being deactivated (`AXApplicationDeactivated`, e.g. Cmd-Tab away); a global mouse-down (any
/// button, so a right-click on YeeHaw's icon counts) outside its windows; or `RevealCoordinator.inactivityTimeout` with none of the app's own
/// activity (menus or windows opening, clicks inside its windows).
@MainActor
private final class RevealSession {
    private static let appNotifications = [
        kAXMenuOpenedNotification, kAXMenuClosedNotification,
        kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationDeactivatedNotification,
    ]
    /// How far below the menu bar a menu or popover's window may start (a popover's arrow).
    private static let hangingSlack: CGFloat = 12
    /// Bounds every AX call made on the main actor (adding and removing notifications).
    private static let messagingTimeout: Float = 0.5

    private let pid: pid_t
    private let app: AXUIElement
    private var observer: AXObserver?
    private var monitor: Any?
    private var timer: Task<Void, Never>?
    /// The app's popover or windows that appeared during the reveal.
    private var windows: [AXUIElement] = []
    /// Open menus, so closing a submenu doesn't count as closing the menu.
    private var menuDepth = 0
    private var reason: String?
    private var waiter: CheckedContinuation<String, Never>?
    /// Every AX notification received, in order, for the debug log.
    private var seen: [String] = []
    /// The app's on-screen windows before the press. A window that appears after it and goes away
    /// again is the menu or popover closing, which AX doesn't always announce (a popover opened by
    /// AXPress sends no notification at all on 27.2).
    private let windowsBeforePress: Set<CGWindowID>
    private var windowsSincePress: Set<CGWindowID> = []
    private var windowWatch: Task<Void, Never>?
    /// The revealed icon's span in the bar (screen x). A click on it is the app in use, not a
    /// click outside: it toggles the app's own menu or popover.
    private var icon: ClosedRange<Double>?

    var seenSummary: String { "[" + seen.joined(separator: ", ") + "]" }

    /// Called once, with the notification's name, when the app's first menu or window appears.
    var onFirstSurface: ((String) -> Void)?

    var isObserving: Bool { observer != nil }

    /// True once the press visibly did something: a menu or window opened, or it already closed.
    var surfaceOpened: Bool {
        menuDepth > 0 || !windows.isEmpty || reason != nil
            || !Self.onScreenWindows(of: pid).subtracting(windowsBeforePress).isEmpty
    }

    /// Observes the app's AX notifications right away, so a menu that opens during the press is seen.
    init(pid: pid_t) {
        self.pid = pid
        windowsBeforePress = Self.onScreenWindows(of: pid)
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return }
        for name in Self.appNotifications {
            AXObserverAddNotification(created, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    /// Starts the outside-click monitor and the inactivity timer, once the press is done.
    func startWatching(icon: ClosedRange<Double>) {
        self.icon = icon
        // Mouse-downs from before now (the synthesized click among them) don't count.
        let since = ProcessInfo.processInfo.systemUptime
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard timestamp >= since else { return }
                self?.mouseDown(at: location)
            }
        }
        restartTimer()
        windowWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(RevealCoordinator.windowPollInterval))
                guard let self, !Task.isCancelled else { return }
                self.checkWindows()
            }
        }
    }

    func waitForClose() async -> String {
        if let reason { return reason }
        return await withCheckedContinuation { waiter = $0 }
    }

    func tearDown() {
        timer?.cancel()
        timer = nil
        windowWatch?.cancel()
        windowWatch = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let observer {
            for name in Self.appNotifications {
                AXObserverRemoveNotification(observer, app, name as CFString)
            }
            for window in windows {
                AXObserverRemoveNotification(observer, window, kAXUIElementDestroyedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        windows = []
    }

    // MARK: Signals

    private func close(_ why: String) {
        guard reason == nil else { return }
        reason = why
        waiter?.resume(returning: why)
        waiter = nil
    }

    /// The app is still in use: push the inactivity timeout back (once watching has started).
    private func activity() {
        if timer != nil { restartTimer() }
    }

    /// Inactivity, not a hard limit: `activity()` calls this again on the app's own activity.
    private func restartTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RevealCoordinator.inactivityTimeout))
            guard !Task.isCancelled, let self else { return }
            // Hiding the icon under an open popover would leave the popover stranded.
            if self.hangsFromBar() { self.restartTimer() } else {
                self.close("no activity for \(Int(RevealCoordinator.inactivityTimeout)) s")
            }
        }
    }

    private func handle(_ name: String, _ element: AXUIElement) {
        seen.append(name)
        if [kAXMenuOpenedNotification, kAXWindowCreatedNotification].contains(name), let first = onFirstSurface {
            onFirstSurface = nil
            first(name)
        }
        guard reason == nil else { return }
        switch name {
        case kAXMenuOpenedNotification:
            menuDepth += 1
            activity()
        case kAXMenuClosedNotification:
            menuDepth = max(menuDepth - 1, 0)
            if menuDepth == 0 { close("AXMenuClosed") } else { activity() }
        case kAXWindowCreatedNotification:
            track(element)
            activity()
        case kAXFocusedWindowChangedNotification:
            if windows.contains(where: { CFEqual($0, element) }) {
                activity()
            } else if windows.isEmpty {
                // Focus moving to a new popover or window is it opening, not closing.
                track(element)
                activity()
            } else {
                close("AXFocusedWindowChanged")
            }
        case kAXUIElementDestroyedNotification:
            if windows.contains(where: { CFEqual($0, element) }) { close("AXUIElementDestroyed") }
        case kAXApplicationDeactivatedNotification:
            close("AXApplicationDeactivated")
        default:
            break
        }
    }

    private func track(_ window: AXUIElement) {
        guard !CFEqual(window, app), !windows.contains(where: { CFEqual($0, window) }) else { return }
        windows.append(window)
        if let observer {
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
    }

    /// Closes once every window that appeared after the press is gone again.
    private func checkWindows() {
        guard reason == nil else { return }
        let new = Self.onScreenWindows(of: pid).subtracting(windowsBeforePress)
        if !new.isEmpty {
            windowsSincePress.formUnion(new)
        } else if !windowsSincePress.isEmpty {
            close("the app's menu or popover went off screen")
        }
    }

    private static func onScreenWindows(of pid: pid_t) -> Set<CGWindowID> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = info as? [[String: Any]] ?? []
        return Set(windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid else { return nil }
            return (window[kCGWindowNumber as String] as? Int).map(CGWindowID.init)
        })
    }

    private func mouseDown(at screenPoint: NSPoint) {
        guard reason == nil else { return }
        if appWindowsContain(screenPoint) || isOnIcon(screenPoint) {
            activity()
        } else if hangsFromBar() {
            // A click in the menu bar doesn't close a popover, and elsewhere it closes it a moment
            // later; either way the window watch ends the reveal once it's gone. Ending it now
            // would hide the icon while its popover stays open, sliding to a neighbour's icon.
            activity()
        } else {
            close("mouse-down outside the app")
        }
    }

    /// Whether a point (AppKit screen coordinates) is on the revealed icon in the menu bar.
    private func isOnIcon(_ screenPoint: NSPoint) -> Bool {
        guard let icon, icon.contains(screenPoint.x),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) else { return false }
        let bar = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        return screenPoint.y >= screen.frame.maxY - bar
    }

    /// Whether a window that appeared after the press still hangs from the menu bar (its top
    /// within a few points of the bar's bottom): a menu or popover, not a window the app opened.
    private func hangsFromBar() -> Bool {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = info as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let number = (window[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
                  !windowsBeforePress.contains(number),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            // CG bounds have a top-left origin on the primary display; find the window's screen.
            let center = NSPoint(x: rect.midX, y: primaryHeight - rect.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return false }
            let screenTop = primaryHeight - screen.frame.maxY
            // An auto-hidden bar leaves no top inset; it still has its own thickness.
            let barBottom = screenTop + max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            return rect.minY <= barBottom + Self.hangingSlack
        }
    }

    /// Whether a point (AppKit screen coordinates) is inside any on-screen window of the app,
    /// its menus and popovers included.
    private func appWindowsContain(_ screenPoint: NSPoint) -> Bool {
        // CG window bounds use a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        let windows = info as? [[String: Any]] ?? []
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return rect.contains(point)
        }
    }

    // MARK: AX observer plumbing

    /// The session outlives its observer: `tearDown` removes the run loop source before the
    /// session can go away, so the unretained pointer is never dangling when a callback runs.
    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    private nonisolated static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        let name = notification as String
        // The source is on the main run loop, so callbacks arrive on the main thread and nothing
        // here crosses threads.
        nonisolated(unsafe) let session = refcon
        nonisolated(unsafe) let element = element
        MainActor.assumeIsolated {
            Unmanaged<RevealSession>.fromOpaque(session).takeUnretainedValue().handle(name, element)
        }
    }
}
