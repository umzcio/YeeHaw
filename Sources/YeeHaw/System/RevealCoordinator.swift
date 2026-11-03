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
    /// After a press, how long to wait for a menu or window before trying another method (the
    /// window poll is the signal; zWhisper's popover sends no notification).
    static let pressGrace: Double = 0.6
    /// How often that wait checks for a menu or window.
    static let surfaceCheckInterval: Double = 0.05
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

    /// Awaited once the app's menu or popover closes, while the icon is still drawn (the strip
    /// photographs it then; see `IconImageProvider.captureSettled`).
    var onClosed: (@MainActor (MenuBarItem) async -> Void)?

    /// `trace` receives each step with its timing; debug runs write it to probe.txt.
    init(controller: MenuBarController, trace: @escaping @MainActor (String) -> Void = { _ in }) {
        self.controller = controller
        self.trace = trace
    }

    /// How a call to `open` went, as far as the app appearing is concerned.
    enum Outcome {
        /// The app was drawn and pressed, and a menu or window appeared.
        case revealed
        /// The app was drawn and pressed, but no menu or window appeared before the reveal ended:
        /// its icon does something else, or the app is stuck (plan 013 counts these).
        case nothingOpened
        /// The app was drawn, but no press method reached its icon and nothing opened.
        case pressFailed
        /// A later click replaced this one while it waited for the open reveal to end.
        case ignored
        /// `beginReveal` threw; the reveal was ended (unless it was `revealInUse`, which leaves
        /// the earlier app alone).
        case failed(Error)
    }

    /// Reveal → press → wait until the app is done with its menu → `endReveal`. A click made while
    /// a reveal is open (or still ending) waits for it and then runs, so two reveals never share
    /// the controller's one slot and the click isn't lost; only the latest waiting click runs.
    @discardableResult
    /// `secondary` asks for the app's right-click menu: the icon gets a right-click, not a press.
    func open(_ id: BundleID, nextTo yeehaw: MenuBarItem, secondary: Bool = false) async -> Outcome {
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
        return await run(id, nextTo: yeehaw, secondary: secondary, step: step)
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

    private func run(_ id: BundleID, nextTo yeehaw: MenuBarItem, secondary: Bool,
                     step: @escaping @MainActor (String) -> Void) async -> Outcome {
        controller.revealTrace = { text in MainActor.assumeIsolated { step(text) } }
        defer { controller.revealTrace = nil }

        let item: MenuBarItem
        do {
            item = try await controller.beginReveal(id, nextTo: yeehaw, leftoverInUse: { leftover in
                RevealSession.anyWindowHangsFromBar(of: Set(
                    NSRunningApplication.runningApplications(withBundleIdentifier: leftover).map(\.processIdentifier)))
            })
        } catch {
            // endReveal is a no-op with nothing pending, and finishes a reveal the controller
            // couldn't undo itself (a failed write after the slot was taken, or a failed undo).
            step("beginReveal failed: \(error)")
            if case ControllerError.revealInUse(let open) = error {
                // Ending it here would switch that app off under its open menu or panel.
                step("beginReveal refused: \(open)'s menu or panel is still open from an earlier reveal")
                return .failed(error)
            }
            await end(step)
            return .failed(error)
        }
        step("reveal done, drawn at x \(item.x) width \(item.width)")

        guard let pid = Self.pressTarget(
            for: item,
            running: NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)
        ) else {
            step("app is not running")
            await end(step)
            return .revealed
        }
        let session = RevealSession(pid: pid)
        session.log = step
        session.onFirstSurface = { what in step("\(what) (first menu or window on screen)") }
        if !session.isObserving { step("AX observer unavailable; only clicks and the timeout can end it") }

        if let beforePress {
            await beforePress()
            step("strip off screen")
        }
        let pressed = secondary
            ? await rightClick(item, pid: pid, session: session, step: step)
            : await press(item, pid: pid, session: session, step: step)
        if pressed || session.surfaceOpened {
            session.startWatching(icon: item.x...(item.x + item.width))
            while true {
                let close = await session.waitForClose()
                step("close: \(close.signal.rawValue)")
                if close.skipsPhoto {
                    step("not photographing: the close was a click outside the app")
                } else if let onClosed {
                    await onClosed(item)
                    step("photographed")
                }
                if await end(step, unlessInUse: { session.isInUseAgain }) { break }
                step("the app's menu or panel opened again before the switch-off; watching again")
                session.resumeWatching()
            }
            session.tearDown()
            if !session.everOpened { step("the press opened nothing before the reveal ended") }
            return session.everOpened ? .revealed : .nothingOpened
        }
        session.tearDown()
        await end(step)
        step("press failed: nothing reached the icon")
        return .pressFailed
    }

    /// `endReveal`, retried once after `endRetryDelay`. It runs in its own unstructured task so a
    /// cancelled caller can't cut it short: `TaskSleeper` ignores cancellation, so the controller's
    /// polls would race through, and the retry's sleep would be skipped.
    /// `unlessInUse` goes to `endReveal`; this returns false only when it held the switch-off back
    /// (the app opened its menu or panel again), and true otherwise, failures included.
    @discardableResult
    private func end(_ step: @escaping @MainActor (String) -> Void,
                     unlessInUse: (@MainActor () -> Bool)? = nil) async -> Bool {
        let controller = controller
        return await Task { @MainActor in
            do {
                guard try await controller.endReveal(unlessInUse: unlessInUse) else { return false }
                step("endReveal done")
                return true
            } catch {
                step("endReveal failed: \(error); retrying in \(Int(Self.endRetryDelay)) s")
            }
            try? await Task.sleep(for: .seconds(Self.endRetryDelay))
            do {
                guard try await controller.endReveal(unlessInUse: unlessInUse) else { return false }
                step("endReveal done on retry")
            } catch {
                let message = "ERROR: endReveal failed twice (\(error)). The app may be left on and its "
                    + "position unrestored; the pending reveal stays saved for the next launch to finish."
                Self.log.fault("\(message, privacy: .public)")
                step(message)
            }
            return true
        }.value
    }

    // MARK: Pressing

    /// The process to press and watch: the copy that owns the revealed item while it still runs,
    /// since two copies of one app can run at once (a debug build beside the installed one) and
    /// only the drawing copy's extras hold the item. Otherwise the first running copy, as before.
    nonisolated static func pressTarget(for item: MenuBarItem, running: [pid_t]) -> pid_t? {
        if let pid = item.pid, running.contains(pid) { return pid }
        return running.first
    }

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

    /// A right-click on the revealed icon, as a person would give it for the app's other menu.
    /// Returns whether it was posted, or else whether the app opened something anyway.
    private func rightClick(_ item: MenuBarItem, pid: pid_t, session: RevealSession,
                            step: @MainActor (String) -> Void) async -> Bool {
        let (result, took) = await performFinding(.click, item: item, pid: pid, right: true)
        if case .done = result {
            step("right-click posted")
            return true
        }
        step("right-click: \(result) after \(took) ms")
        return session.surfaceOpened
    }

    /// AX press, then `AXShowMenu`, then a synthesized click, each logged with its duration and
    /// result. Every method runs only while nothing has opened yet, so the icon is activated at
    /// most once after the app showed its menu or window: a failed method may still have opened it
    /// while the call timed out. Returns whether the press got through or something opened.
    private func press(_ item: MenuBarItem, pid: pid_t, session: RevealSession,
                       step: @MainActor (String) -> Void) async -> Bool {
        for method in PressMethod.allCases {
            if session.surfaceOpened {
                step("press: the app opened its menu or window; no \(method.rawValue)")
                return true
            }
            let (result, took) = await performFinding(method, item: item, pid: pid)
            switch result {
            case .notFound:
                step("press \(method.rawValue): no extras-bar element at x \(item.x) width \(item.width) after \(took) ms")
                return session.surfaceOpened
            case .done where method == .click:
                step("press \(method.rawValue): click posted in \(took) ms; notifications so far: \(session.seenSummary)")
                return true
            case .done:
                step("press \(method.rawValue): worked in \(took) ms; notifications so far: \(session.seenSummary)")
                if await waitForSurface(session) {
                    step("press \(method.rawValue): menu or window on screen")
                    return true
                }
                // A SwiftUI MenuBarExtra (Fiddle) takes AXPress without error and opens nothing:
                // it only opens on a real click. AXShowMenu does no better, so click.
                step("press \(method.rawValue): nothing opened within \(Int(Self.pressGrace * 1000)) ms; clicking")
                if session.surfaceOpened { return true }
                let (clicked, _) = await performFinding(.click, item: item, pid: pid)
                if case .done = clicked {
                    step("press \(PressMethod.click.rawValue): click posted")
                    return true
                }
                step("press \(PressMethod.click.rawValue): \(clicked)")
                return session.surfaceOpened
            case .failed(let code):
                step("press \(method.rawValue): returned \(code) after \(took) ms; "
                     + "notifications so far: \(session.seenSummary)")
                if await waitForSurface(session) {
                    step("press \(method.rawValue): menu or window on screen")
                    return true
                }
                step("press \(method.rawValue): nothing opened within \(Int(Self.pressGrace * 1000)) ms; trying the next method")
            }
        }
        step("press: every method failed")
        return session.surfaceOpened
    }

    /// Waits up to `pressGrace` for the app's menu or window, returning as soon as one is up.
    private func waitForSurface(_ session: RevealSession) async -> Bool {
        let started = ContinuousClock.now
        while !session.surfaceOpened {
            guard ContinuousClock.now - started < .seconds(Self.pressGrace), !Task.isCancelled else { return false }
            try? await Task.sleep(for: .seconds(Self.surfaceCheckInterval))
        }
        return true
    }

    /// One press method, re-reading the app's extras bar for a moment while the revealed item
    /// isn't in it yet (it can lag behind what's drawn). Returns the result and how long it took.
    private func performFinding(_ method: PressMethod, item: MenuBarItem, pid: pid_t,
                                right: Bool = false) async -> (PressResult, took: Int64) {
        let started = ContinuousClock.now
        var result = await Self.perform(method, pid: pid, x: item.x, width: item.width, right: right)
        while case .notFound = result, ContinuousClock.now - started < .seconds(Self.findTimeout), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.findInterval))
            result = await Self.perform(method, pid: pid, x: item.x, width: item.width, right: right)
        }
        return (result, Self.milliseconds(ContinuousClock.now - started))
    }

    /// Re-reads the app's extras-bar children and acts on the one at the revealed item's frame.
    /// Runs off the main actor: AX calls block, and the app's notifications arrive on the main run
    /// loop while they do.
    @concurrent
    private static func perform(_ method: PressMethod, pid: pid_t, x: Double, width: Double,
                                right: Bool = false) async -> PressResult {
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
                  await postClick(at: CGPoint(x: frame.midX, y: frame.midY), right: right)
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
    private nonisolated static func postClick(at point: CGPoint, right: Bool = false) async -> Bool {
        let button: CGMouseButton = right ? .right : .left
        let source = CGEventSource(stateID: .hidSystemState)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: button),
              let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: button),
              let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: button)
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

/// Menu bar geometry for a reveal's click checks, kept pure so it can be tested.
enum RevealGeometry {
    struct Screen: Equatable {
        let frame: NSRect
        /// The bar's height: the screen's top inset, at least the status bar's thickness
        /// (an auto-hidden bar leaves no inset).
        let barHeight: CGFloat
    }

    @MainActor static func screens() -> [Screen] {
        NSScreen.screens.map { screen in
            Screen(frame: screen.frame,
                   barHeight: max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness))
        }
    }

    /// Whether a point (AppKit screen coordinates) is in a screen's menu bar. The top edge
    /// counts: a click on the screen's top row has `y == frame.maxY`, which `NSRect.contains`
    /// leaves out.
    static func isInMenuBar(_ point: NSPoint, screens: [Screen]) -> Bool {
        guard let screen = screens.first(where: {
            $0.frame.minX <= point.x && point.x < $0.frame.maxX
                && $0.frame.minY <= point.y && point.y <= $0.frame.maxY
        }) else { return false }
        return point.y >= screen.frame.maxY - screen.barHeight
    }

    /// Whether a point (AppKit screen coordinates) is on the revealed icon in the menu bar.
    static func isOnIcon(_ point: NSPoint, icon: ClosedRange<Double>, screens: [Screen]) -> Bool {
        icon.contains(point.x) && isInMenuBar(point, screens: screens)
    }
}

/// One reveal's close signals; `tearDown` removes them all.
///
/// The app may be done with its menu on: `AXMenuClosed` for its outermost menu; its popover or
/// window losing focus (`AXFocusedWindowChanged`) or being destroyed (`AXUIElementDestroyed`); the
/// app being deactivated (`AXApplicationDeactivated`, e.g. Cmd-Tab away); its post-press windows
/// going off screen; a global mouse-down (any button, so a right-click on YeeHaw's icon counts)
/// outside its windows; or `RevealCoordinator.inactivityTimeout` with none of the app's own
/// activity (menus or windows opening, clicks inside its windows). Each is only a hint:
/// `RevealClosePolicy` decides whether the reveal ends, so the app is never switched off under a
/// panel that's still up. Once the close is decided the listeners stay installed until
/// `tearDown`, watching only for the app opening its menu or panel again before the switch-off.
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
    private enum Phase { case watching, closing(RevealCloseSignal, since: ContinuousClock.Instant), ended }
    /// How a reveal's menu or popover closed, as the coordinator acts on it.
    struct Close { let signal: RevealCloseSignal; let skipsPhoto: Bool }
    private var phase = Phase.watching
    private var decided: Close?
    private var waiter: CheckedContinuation<Close, Never>?
    private var recheck: Task<Void, Never>?
    /// A menu or bar-hanging window opened after the close was decided.
    private var reopened = false
    /// When the last outside click came, so a close that follows it soon after counts as one.
    private var outsideClickAt: ContinuousClock.Instant?
    /// After an outside click in the menu bar: other processes' windows on screen at the click,
    /// and the new bar-hanging ones' bounds at the last recheck.
    private var otherAppWatch: (before: Set<CGWindowID>, lastBounds: [CGWindowID: CGRect])?
    /// True once any menu or window of the app's opened after the press.
    private(set) var everOpened = false
    /// Receives the session's own steps (the coordinator's `step`).
    var log: ((String) -> Void)?
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

    /// True once the press visibly did something: a menu or window opened since it.
    var surfaceOpened: Bool {
        everOpened || !postPressWindows().isEmpty
    }

    /// Asked right before the switch-off is written: the app opened a menu again after the close
    /// was decided, or one of its post-press windows hangs from the bar.
    var isInUseAgain: Bool { reopened || hangsFromBar() }

    /// Observes the app's AX notifications right away, so a menu that opens during the press is seen.
    init(pid: pid_t) {
        self.pid = pid
        windowsBeforePress = Self.onScreenWindows(owner: { $0 == pid })
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
            // Where the click happened, not where the pointer is now. `locationInWindow` is relative to
            // the other app's window for a global event, so flip the global Quartz location instead.
            let location = StripPanel.appKitScreenPoint(event.cgEvent?.location) ?? NSEvent.mouseLocation
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

    /// Returns once the policy decides the app is done with its menu (at once if it already has).
    func waitForClose() async -> Close {
        if let decided { return decided }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// After the app opened its menu or panel again before the switch-off: watch for the next close.
    func resumeWatching() {
        phase = .watching
        decided = nil
        reopened = false
        windowsSincePress = []
        restartTimer()
    }

    func tearDown() {
        timer?.cancel()
        timer = nil
        recheck?.cancel()
        recheck = nil
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

    /// A close hint: held, ignored or acted on as `RevealClosePolicy` decides.
    private func signal(_ s: RevealCloseSignal) {
        switch phase {
        case .ended:
            return
        case .closing(let pending, _):
            // Only an outside click outranks the hint being held: its photo is skipped.
            guard s == .outsideClick, pending != .outsideClick else { return }
            phase = .closing(.outsideClick, since: .now)
        case .watching:
            var hint = s
            if hint != .outsideClick {
                let point = NSEvent.mouseLocation
                if NSEvent.pressedMouseButtons != 0, !appWindowsContain(point), !isOnIcon(point) {
                    // Another app's click, seen here as an AX notification before (or instead of)
                    // the global mouse-down.
                    outsideClickAt = .now
                    if RevealGeometry.isInMenuBar(point, screens: RevealGeometry.screens()) { watchOtherApps() }
                    hint = .outsideClick
                } else if let at = outsideClickAt, ContinuousClock.now - at < .seconds(RevealClosePolicy.clickCap) {
                    // The surface an outside click dismissed (while it still hung from the bar)
                    // closing a moment later.
                    hint = .outsideClick
                }
            }
            phase = .closing(hint, since: .now)
        }
        evaluate()
    }

    /// Judges the pending hint against the screen and the mouse as they are now.
    private func evaluate() {
        guard case .closing(let s, let since) = phase else { return }
        let postPress = postPressWindows()
        if !postPress.isEmpty {
            windowsSincePress.formUnion(postPress)
            everOpened = true
        }
        let inputs = RevealCloseInputs(
            postPressWindowsOnScreen: !postPress.isEmpty,
            hangsFromBar: hangsFromBar(),
            mouseButtonDown: NSEvent.pressedMouseButtons != 0,
            otherAppOpening: otherAppOpening(),
            elapsed: Self.seconds(ContinuousClock.now - since))
        switch RevealClosePolicy.decide(s, inputs) {
        case .keepWaiting:
            log?("close hint \(s.rawValue) ignored: a window the press opened hangs from the bar")
            recheck?.cancel()
            recheck = nil
            // `outsideClickAt` and `otherAppWatch` stay: the surface closing a moment later is
            // that click's doing.
            phase = .watching
            if timer != nil { restartTimer() }
        case .endNow:
            finish(s)
        case .endAfterCappedWait(let remaining):
            guard recheck == nil else { return }
            var reasons: [String] = []
            if inputs.postPressWindowsOnScreen { reasons.append("a window the press opened is still up") }
            if inputs.mouseButtonDown { reasons.append("a mouse button is down") }
            if s == .outsideClick, inputs.otherAppOpening { reasons.append("another app is opening its menu") }
            let ms = Int((remaining * 1000).rounded())
            log?("close hint \(s.rawValue): holding the switch-off (\(reasons.joined(separator: ", "))), at most \(ms) ms")
            recheck = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(RevealClosePolicy.recheckInterval))
                    guard let self, !Task.isCancelled else { return }
                    self.evaluate()
                }
            }
        }
    }

    /// Whether another app's menu or panel is still opening from the outside click: true until a
    /// new window of another process hangs from the bar with the same bounds on two rechecks.
    private func otherAppOpening() -> Bool {
        guard let watch = otherAppWatch else { return false }
        let pid = pid
        let now = Self.barHangingWindows(owner: { $0 != pid }, excluding: watch.before)
        let settled = now.contains { watch.lastBounds[$0.key] == $0.value }
        otherAppWatch = (watch.before, now)
        return !settled
    }

    /// Snapshots every other process's windows (YeeHaw's own strip included), so the ones an
    /// outside click in the menu bar opens can be told apart.
    private func watchOtherApps() {
        let pid = pid
        otherAppWatch = (Self.onScreenWindows(owner: { $0 != pid }), [:])
    }

    /// The close is decided: the coordinator photographs (unless skipped) and switches the app off.
    private func finish(_ s: RevealCloseSignal) {
        recheck?.cancel()
        recheck = nil
        phase = .ended
        // A lost AXMenuClosed mustn't leave the menu counted as open.
        menuDepth = 0
        reopened = false
        outsideClickAt = nil
        otherAppWatch = nil
        let close = Close(signal: s, skipsPhoto: RevealClosePolicy.skipsPhoto(s))
        decided = close
        waiter?.resume(returning: close)
        waiter = nil
    }

    /// The app is still in use: drop a pending close hint and push the inactivity timeout back
    /// (once watching has started).
    private func activity() {
        outsideClickAt = nil
        otherAppWatch = nil
        if case .closing = phase {
            recheck?.cancel()
            recheck = nil
            phase = .watching
            log?("close hint dropped: the app is in use again")
        }
        if timer != nil { restartTimer() }
    }

    /// Inactivity, not a hard limit: `activity()` calls this again on the app's own activity, and
    /// the policy keeps the reveal (and restarts this) while a window hangs from the bar.
    private func restartTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RevealCoordinator.inactivityTimeout))
            guard !Task.isCancelled, let self else { return }
            self.signal(.inactivity)
        }
    }

    private func handle(_ name: String, _ element: AXUIElement) {
        seen.append(name)
        if [kAXMenuOpenedNotification, kAXWindowCreatedNotification].contains(name), let first = onFirstSurface {
            onFirstSurface = nil
            first(name)
        }
        if case .ended = phase {
            // Only a re-open matters now: it holds back the switch-off.
            if [kAXMenuOpenedNotification, kAXWindowCreatedNotification].contains(name) { reopened = true }
            return
        }
        switch name {
        case kAXMenuOpenedNotification:
            menuDepth += 1
            everOpened = true
            activity()
        case kAXMenuClosedNotification:
            menuDepth = max(menuDepth - 1, 0)
            if menuDepth == 0 { signal(.menuClosed) } else { activity() }
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
                signal(.focusMovedAway)
            }
        case kAXUIElementDestroyedNotification:
            if windows.contains(where: { CFEqual($0, element) }) { signal(.windowDestroyed) }
        case kAXApplicationDeactivatedNotification:
            signal(.appDeactivated)
        default:
            break
        }
    }

    private func track(_ window: AXUIElement) {
        guard !CFEqual(window, app), !windows.contains(where: { CFEqual($0, window) }) else { return }
        windows.append(window)
        everOpened = true
        if let observer {
            AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
        }
    }

    /// A close hint once every window that appeared after the press is gone again; after the
    /// close, a post-press window hanging from the bar is the app opening its panel again.
    private func checkWindows() {
        if case .ended = phase {
            if hangsFromBar() { reopened = true }
            return
        }
        let new = postPressWindows()
        if !new.isEmpty {
            windowsSincePress.formUnion(new)
            everOpened = true
        } else if !windowsSincePress.isEmpty {
            signal(.windowsGone)
        }
    }

    private func mouseDown(at screenPoint: NSPoint) {
        if case .ended = phase { return }
        if appWindowsContain(screenPoint) || isOnIcon(screenPoint) {
            activity()
            return
        }
        // A click in the menu bar doesn't close a popover, and elsewhere it closes it a moment
        // later; the policy keeps the reveal while it still hangs from the bar.
        outsideClickAt = .now
        if RevealGeometry.isInMenuBar(screenPoint, screens: RevealGeometry.screens()) { watchOtherApps() }
        signal(.outsideClick)
    }

    /// Whether a point (AppKit screen coordinates) is on the revealed icon in the menu bar.
    private func isOnIcon(_ screenPoint: NSPoint) -> Bool {
        guard let icon else { return false }
        return RevealGeometry.isOnIcon(screenPoint, icon: icon, screens: RevealGeometry.screens())
    }

    // MARK: Windows

    /// The app's on-screen windows that appeared after the press.
    private func postPressWindows() -> Set<CGWindowID> {
        let pid = pid
        return Self.onScreenWindows(owner: { $0 == pid }).subtracting(windowsBeforePress)
    }

    /// Whether a window that appeared after the press still hangs from the menu bar (its top
    /// within a few points of the bar's bottom): a menu or popover, not a window the app opened.
    private func hangsFromBar() -> Bool {
        let pid = pid
        return !Self.barHangingWindows(owner: { $0 == pid }, excluding: windowsBeforePress).isEmpty
    }

    /// Whether any visible window of these processes hangs from the menu bar (an earlier reveal's
    /// menu or panel still open).
    static func anyWindowHangsFromBar(of pids: Set<pid_t>) -> Bool {
        !barHangingWindows(owner: { pids.contains($0) }, excluding: []).isEmpty
    }

    private static func windowList() -> [[String: Any]] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        return info as? [[String: Any]] ?? []
    }

    /// A window faded out but left ordered in (alpha 0) isn't on screen to anyone looking; counting
    /// it would hold a reveal open forever.
    private static func isVisible(_ window: [String: Any]) -> Bool {
        (window[kCGWindowAlpha as String] as? Double).map { $0 > 0 } ?? true
    }

    private static func owner(of window: [String: Any]) -> pid_t? {
        (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init)
    }

    /// The visible on-screen windows of the processes `owner` accepts.
    private static func onScreenWindows(owner: (pid_t) -> Bool) -> Set<CGWindowID> {
        Set(windowList().compactMap { window in
            guard let pid = Self.owner(of: window), owner(pid), isVisible(window) else { return nil }
            return (window[kCGWindowNumber as String] as? Int).map(CGWindowID.init)
        })
    }

    /// The visible windows of the processes `owner` accepts, not in `excluding`, whose top is
    /// within `hangingSlack` of the menu bar's bottom, with their CG bounds.
    private static func barHangingWindows(owner: (pid_t) -> Bool, excluding: Set<CGWindowID>) -> [CGWindowID: CGRect] {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var hanging: [CGWindowID: CGRect] = [:]
        for window in windowList() {
            guard let pid = Self.owner(of: window), owner(pid), isVisible(window),
                  let number = (window[kCGWindowNumber as String] as? Int).map(CGWindowID.init),
                  !excluding.contains(number),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            // CG bounds have a top-left origin on the primary display; find the window's screen.
            let center = NSPoint(x: rect.midX, y: primaryHeight - rect.midY)
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { continue }
            let screenTop = primaryHeight - screen.frame.maxY
            // An auto-hidden bar leaves no top inset; it still has its own thickness.
            let barBottom = screenTop + max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
            if rect.minY <= barBottom + hangingSlack { hanging[number] = rect }
        }
        return hanging
    }

    /// Whether a point (AppKit screen coordinates) is inside any on-screen window of the app,
    /// its menus and popovers included.
    private func appWindowsContain(_ screenPoint: NSPoint) -> Bool {
        // CG window bounds use a top-left origin on the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        return Self.windowList().contains { window in
            guard Self.owner(of: window) == pid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds)
            else { return false }
            return rect.contains(point)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
