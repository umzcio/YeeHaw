# Plan 002: A reveal never switches an app off under its open menu or panel

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/UI/StatusItemController.swift Sources/YeeHawCore/MenuBarController.swift Sources/YeeHawCore/RevealClosePolicy.swift Tests/YeeHawCoreTests/RevealClosePolicyTests.swift Tests/YeeHawCoreTests/MenuBarControllerTests.swift Tests/YeeHawTests/StripTests.swift Tests/YeeHawTests/RevealGeometryTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before you go on. On a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L (one new pure type and its tests, a rewrite of `RevealSession`'s signal handling, small changes to `MenuBarController` and `StatusItemController`)
- **Risk**: MED (the reveal is the app's main interaction, and its timing is only fully proven live)
- **Depends on**: none. Plans 003, 006 and 013 build on this one.
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw hides menu bar icons. Clicking a hidden app's tile in YeeHaw's strip *reveals* the app: its icon is switched on next to YeeHaw's icon, pressed, and switched off again once its menu or popover closes.

Today any one AX notification ends the reveal on the spot, as does a click elsewhere. The app can then be switched off while a panel the press opened is still up, or while the user is re-opening it. The app's own open/closed toggle then goes out of sync, and the panel is left stranded or slides onto a neighbour's icon.

A click on another app's icon during a reveal has a second cost. It starts a burst of screen captures and a bar re-layout while that other app's menu is opening, which can make it open in the wrong place or not at all.

The press can also activate an item twice. A failed press is reported as a success, so the user gets no notice.

After this plan:
- every close signal is a hint, judged by one pure, unit-tested policy;
- the switch-off is held back while a post-press window is up, while a mouse button is down, or while another app is opening its menu;
- a re-opened panel cancels the switch-off right up to the moment it is written;
- an outside click skips the photo;
- the press activates at most once after something opened, and a press that reached nothing gets its own outcome and notice.

## Current state

### Background: how a reveal works on macOS 27.2

- `MenuBarAgent` draws every app's status item. A click goes to MenuBarAgent, which forwards it to the owning app. Other apps' global mouse-down monitors (YeeHaw's included) also see that press, as a global event.
- YeeHaw hides an app by setting `isAllowed=false` in its entry in macOS's Allow list, and shows it again with `isAllowed=true`. "Switch off" and "switch on" in this plan mean exactly that write.
- **A reveal**, after a tile in the strip is clicked:
  1. `MenuBarController.beginReveal` switches the app on, with its slot next to YeeHaw's icon, and waits until it's drawn.
  2. The coordinator waits until the strip is off screen.
  3. It AXPresses the item. If nothing opens within the grace period (0.3 s today), it posts a synthesized click. A right-click on a tile posts a right-click instead.
  4. A `RevealSession` watches for the menu or popover to close, through three signals: AX notifications, a global mouse-down monitor, and a 0.25 s poll of the app's on-screen CG windows.
  5. `onClosed` photographs the icon once two shots match.
  6. `MenuBarController.endReveal` switches the app off and restores positions.

### Files

- `Sources/YeeHaw/System/RevealCoordinator.swift`: `RevealCoordinator` (runs a reveal, presses the icon) and the file-private `RevealSession` (close signals). This is where most of the work happens. All AppKit and AX plumbing stays here.
- `Sources/YeeHawCore/MenuBarController.swift`: `beginReveal`, `endReveal` and the private `finishReveal`, which writes the switch-off.
- `Sources/YeeHaw/UI/StatusItemController.swift`: wires `onClosed` and `beforePress`, maps `RevealCoordinator.Outcome` to the strip's notice.
- `Sources/YeeHaw/UI/StripPanel.swift`: has `appKitScreenPoint`, the correct conversion for a global event's location. Read-only for this plan.
- `Sources/YeeHaw/System/IconImageProvider.swift`: `captureSettled`, the settled photo. Read-only for this plan.
- `Sources/YeeHawCore/RevealClosePolicy.swift`: **new**, the pure close policy.

### Excerpts at 495d26f

**`RevealCoordinator.swift:14-20`**: the timing constants.
```swift
    /// How often a reveal checks whether the app's menu or popover is still on screen.
    static let windowPollInterval: Double = 0.25
    /// How long one AX press may block. An app busy tracking the menu it just opened can run past
    /// this and return `-25204`, so a timeout isn't treated as a failure.
    nonisolated static let pressTimeout: Float = 0.2
    /// After a failed press, how long to wait for a menu or window before trying the next method.
    static let pressGrace: Double = 0.3
```

**`RevealCoordinator.swift:51-59`**: the outcome. It has no case for "the press failed".
```swift
    enum Outcome {
        /// The app was drawn next to YeeHaw (whatever happened with the press afterwards).
        case revealed
        /// A later click replaced this one while it waited for the open reveal to end.
        case ignored
        /// `beginReveal` threw; the reveal was ended.
        case failed(Error)
    }
```

**`RevealCoordinator.swift:103-142`** (`run`): after `waitForClose`, the photo runs, then `tearDown`, then `end`. The session stops listening the moment the close is decided (F2), and the photo runs whatever the close reason was (F3).
```swift
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
        ...
        let pressed = secondary
            ? await rightClick(item, pid: pid, step: step)
            : await press(item, pid: pid, session: session, step: step)
        if pressed {
            session.startWatching(icon: item.x...(item.x + item.width))
            step("close: \(await session.waitForClose())")
            if let onClosed {
                await onClosed(item)
                step("photographed")
            }
        }
        session.tearDown()
        await end(step)
        return .revealed
```

**`RevealCoordinator.swift:147-168`** (`end`): `endReveal`, retried once, inside an unstructured `Task` so that a cancelled caller can't cut it short. Keep that structure.

**`RevealCoordinator.swift:188-196`** (`rightClick`): one attempt. It has no find-retry loop, and on failure the caller still returns `.revealed` (F5).
```swift
    private func rightClick(_ item: MenuBarItem, pid: pid_t, step: @MainActor (String) -> Void) async -> Bool {
        let result = await Self.perform(.click, pid: pid, x: item.x, width: item.width, right: true)
        if case .done = result {
            step("right-click posted")
            return true
        }
        step("right-click: \(result)")
        return false
    }
```

**`RevealCoordinator.swift:200-231`** (`press`):
- `.notFound` returns `false` without checking `surfaceOpened`.
- After a successful AXPress, a click is posted whenever nothing showed within 0.3 s.
- A `.failed` result falls through to the next method, so up to three activations can happen (F5).
```swift
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
```

**`RevealCoordinator.swift:357-361`**: `surfaceOpened`.
```swift
    var surfaceOpened: Bool {
        menuDepth > 0 || !windows.isEmpty || reason != nil
            || !Self.onScreenWindows(of: pid).subtracting(windowsBeforePress).isEmpty
    }
```

**`RevealCoordinator.swift:383-390`**: the global monitor reads `event.locationInWindow`. For a global event that location is relative to the other app's window (F12).
```swift
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard timestamp >= since else { return }
                self?.mouseDown(at: location)
            }
        }
```

**`RevealCoordinator.swift:428-433`**: the first close wins. After that, every handler returns early (`guard reason == nil`), so nothing is watched during the photo or the `endReveal` call.
```swift
    private func close(_ why: String) {
        guard reason == nil else { return }
        reason = why
        waiter?.resume(returning: why)
        waiter = nil
    }
```

**`RevealCoordinator.swift:443-450`**: the inactivity timer checks `hangsFromBar()`.
```swift
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(RevealCoordinator.inactivityTimeout))
            guard !Task.isCancelled, let self else { return }
            // Hiding the icon under an open popover would leave the popover stranded.
            if self.hangsFromBar() { self.restartTimer() } else {
                self.close("no activity for \(Int(RevealCoordinator.inactivityTimeout)) s")
            }
        }
```

**`RevealCoordinator.swift:459-486`**: four AX close signals that ignore any window still up (F2).
```swift
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
```

**`RevealCoordinator.swift:499-507`**: the window poll. It is the only close signal for zWhisper's popover, which sends no AX notification.
```swift
    private func checkWindows() {
        guard reason == nil else { return }
        let new = Self.onScreenWindows(of: pid).subtracting(windowsBeforePress)
        if !new.isEmpty {
            windowsSincePress.formUnion(new)
        } else if !windowsSincePress.isEmpty {
            close("the app's menu or popover went off screen")
        }
    }
```

**`RevealCoordinator.swift:518-538`**: the outside click and `isOnIcon`. `isOnIcon` finds the screen with `frame.contains`, which excludes the top row (`y == frame.maxY`).
```swift
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
```

**`RevealCoordinator.swift:542-561`**: `hangsFromBar()`. A post-press window counts when its top is within `hangingSlack` (12 pt) of the bar's bottom. Reuse this math unchanged.

**`StripPanel.swift:318-324`**: the conversion to use for F12. It is already tested in `Tests/YeeHawTests/StripTests.swift:181-186`.
```swift
    /// A Quartz global point (top-left origin of the primary display) in AppKit screen
    /// coordinates (bottom-left origin).
    nonisolated static func appKitScreenPoint(_ quartz: CGPoint?, primaryHeight: CGFloat? = nil) -> NSPoint? {
        guard let quartz else { return nil }
        let height = primaryHeight ?? CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: quartz.x, y: height - quartz.y)
    }
```
StripPanel's own monitor (`StripPanel.swift:375`) uses it like this: `let location = Self.appKitScreenPoint(event.cgEvent?.location) ?? NSEvent.mouseLocation`.

**`MenuBarController.swift:358-366`** (`beginReveal`): a leftover reveal of another app is finished with no check that its panel is closed (F2).
```swift
    public func beginReveal(_ id: BundleID, nextTo yeehaw: MenuBarItem) async throws -> MenuBarItem {
        try await gated {
            guard state.hidden.contains(id), state.journal.contains(id) else {
                throw ControllerError.notTracked(id)
            }
            // Switching on an app that isn't running would draw nothing; nothing is written.
            guard await reader.runningBundleIDs().contains(id) else { throw ControllerError.notRunning(id) }
            if state.pendingReveal != nil { try await finishReveal() }
```

**`MenuBarController.swift:400-445`** (`endReveal` / `finishReveal`): the switch-off write is the line `try writeAllow(locations.map { .addLocation(id, $0) } + [.switchOff(id)])`. It comes after the reads (`runningBundleIDs`, `drawnBar`, `runningLocations`).
```swift
    public func endReveal() async throws {
        try await gated { try await finishReveal() }
    }
    ...
    private func finishReveal() async throws {
        guard let pending = state.pendingReveal else { return }
        var writeFailure: Error?
        var waitFailure: Error?
        if state.journal.contains(pending.bundleID) {
            let id = pending.bundleID
            do {
                ...
                let locations = await runningLocations(of: id)
                try writeAllow(locations.map { .addLocation(id, $0) } + [.switchOff(id)])
```
`finishReveal` has two other callers: `beginReveal`'s not-honored path at line 389, and `beginReveal`'s leftover line 365. `show()` (lines 185-213) clears `pendingReveal` itself and doesn't call it.

**`MenuBarController.swift:3-13`**: `ControllerError`. The only `switch` over it is `LayoutModel.message(for:)` (`Sources/YeeHaw/UI/LayoutModel.swift:536-553`), which has a `default:`, so a new case compiles.

**`StatusItemController.swift:80-88`**: the photo and the strip-off-screen hooks. Both stay exactly as they are.
```swift
        reveal.onClosed = { [icons, controller] item in
            await controller.refresh()
            await icons.captureSettled(controller.items.first { $0.id == item.id } ?? item)
        }
        reveal.beforePress = { [strip] in await strip.waitUntilOffScreen() }
```

**`StatusItemController.swift:244-251`** (`RevealProblem`), **`:260-285`** (`notice`) and **`:309-322`** (the switch over `reveal.open`'s result):
```swift
            switch await reveal.open(id, nextTo: yeehaw, secondary: secondary) {
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
```

### Design constraints this plan must preserve (do not regress them)

1. **The strip must be off screen before the press.** Ordering out the key strip hands key focus back to YeeHaw, which closes a `.transient` popover that became key during the fade-out (`StripPanel.swift:190-197`). Keep `if let beforePress { await beforePress() }` before the press in `run`, and keep `StatusItemController.swift:88` unchanged.
2. **A revealed icon is photographed only after the close, once two shots match** (`IconImageProvider.captureSettled`, `IconImageProvider.swift:159-187`). `onClosed` still runs after the close is decided and before the switch-off. The only change is that it's skipped when the close came from an outside click. Do not edit `IconImageProvider.swift`.
3. **A click on the revealed icon itself is activity, not "outside".** It toggles the app's own menu or popover. Keep the `isOnIcon` check ahead of any close signal.
4. **A window hanging from the bar keeps the reveal alive** on an outside click or a timeout. The new policy keeps this for *every* signal (rule 1 below).
5. **Fiddle (a SwiftUI `MenuBarExtra`) needs the synthesized-click fallback**, because AXPress returns success and opens nothing. Keep the AXPress-then-click path; only its grace and checks change.
6. **zWhisper's popover sends no AX notifications**, so the on-screen window poll (`windowPollInterval`, `checkWindows`) is its close signal. Keep the poll.

### Conventions

- Swift 6, SwiftPM, macOS 27.2. Two targets: `YeeHawCore` (pure logic, Foundation only, no AppKit) and `YeeHaw` (the app).
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`):
  - Core tests import with `@testable import YeeHawCore`. Model new pure tests on `Tests/YeeHawCoreTests/LaunchRulesTests.swift`.
  - App tests use `@testable import YeeHaw`, as `Tests/YeeHawTests/StripTests.swift` does.
  - Parameterized tests use `@Test(arguments:)`, as `StripTests.swift:94-103` does.
- Doc comments (`///`) explain *why*, in plain sentences. Match the style already in `RevealCoordinator.swift`.
- All reveal logging goes through the `step` closure in `RevealCoordinator.open`. It writes `Logger(subsystem: "com.zapps.yeehaw", category: "reveal")` at `.notice` as `reveal <bundle id> +<ms> ms: <text>`.
- Repo rules: never commit personal names or the signing certificate's identity name. Never change the bundle ID (`com.zapps.yeehaw`) or the signing team.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build` | exit 0 |
| All tests | `swift test 2>&1 \| tee /tmp/yeehaw-test.log` | exit 0. Baseline at 495d26f: 269 YeeHawCore + 179 YeeHaw tests pass |
| Warnings | `grep -c "warning:" /tmp/yeehaw-test.log` | `0` |
| Failures | `grep -c "✘" /tmp/yeehaw-test.log` | `0` |
| One suite | `swift test --filter RevealClosePolicyTests` | exit 0, only that suite runs |
| Install (live check only) | `scripts/build-app.sh --install && (pkill -x YeeHaw; open ~/Applications/YeeHaw.app)` | exit 0, YeeHaw's hat back in the bar |
| Reveal log | `/usr/bin/log show --last 5m --predicate 'subsystem == "com.zapps.yeehaw" AND category == "reveal"' --info --style compact` | the `reveal …` lines (use the full path: `log` is shadowed in zsh) |

## Suggested executor toolkit

- Use `superpowers:test-driven-development` for Steps 1 and 2: write the tests first, see them fail, then implement.
- Use `swift-expert` if Swift 6 concurrency diagnostics appear around the `@MainActor` closures in Steps 2, 5 and 7.

## Scope

**In scope** (the only files you may modify):
- `Sources/YeeHawCore/RevealClosePolicy.swift` (create)
- `Tests/YeeHawCoreTests/RevealClosePolicyTests.swift` (create)
- `Sources/YeeHawCore/MenuBarController.swift` (`ControllerError`, `beginReveal`, `endReveal`, `finishReveal` only)
- `Tests/YeeHawCoreTests/MenuBarControllerTests.swift` (add tests in the `// MARK: reveal` section)
- `Sources/YeeHaw/System/RevealCoordinator.swift`
- `Tests/YeeHawTests/RevealGeometryTests.swift` (create)
- `Sources/YeeHaw/UI/StatusItemController.swift` (`RevealProblem`, `notice`, the `switch` in `select` only)
- `Tests/YeeHawTests/StripTests.swift` (add to `StripNoticeTests` only)
- `plans/README.md` (status row only)

**Out of scope** (do NOT touch, even though they look related):
- `Sources/YeeHaw/System/IconImageProvider.swift`: plan 003 reworks capture. The settled-photo rule must not change here.
- `Sources/YeeHaw/UI/StripPanel.swift`: only *call* `StripPanel.appKitScreenPoint`. `waitUntilOffScreen` must stay exactly as it is (constraint 1).
- `StatusItemController.swift:80-88` (`onClosed` / `beforePress` wiring): plan 003 changes `onClosed`. Leave it as is.
- The pid lookup `NSRunningApplication.runningApplications(withBundleIdentifier: id).first` (`RevealCoordinator.swift:115`): plan 006 changes it.
- `Sources/YeeHaw/App/DebugCommand.swift`: it discards `open`'s result, so it needs no change.
- Any change to `inactivityTimeout`, `windowPollInterval`, `hangingSlack`, `findTimeout`, `pressTimeout` or `clickSettle`.

## Git workflow

- Branch: `git switch -c advisor/002-reveal-session` (from `build/yeehaw-v1`).
- Commit after each step that ends green. Use conventional commits, matching `git log`, e.g. `fix: keep a revealed icon while its popover hangs from the bar`.
- Every message ends with a blank line and then:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
- Do NOT push or open a PR.

## The design

### The pure policy (`YeeHawCore/RevealClosePolicy.swift`)

The policy is called whenever a close signal arrives, and again every `recheckInterval` while a close is being held. It turns the signal and a snapshot of the world into one of three decisions:

| Rule | Condition | Decision |
|---|---|---|
| 1 | a post-press window hangs from the bar (menu, popover, panel) | `.keepWaiting`: not a close. The reveal goes on, and the inactivity timer restarts |
| 2 | a post-press window is on screen but none hangs from the bar (a window the app opened), and `elapsed < windowCap` (3 s) | hold |
| 3 | a mouse button is down, and `elapsed < clickCap` (2 s) | hold |
| 4 | the signal is `.outsideClick`, another app is opening its menu, and `elapsed < clickCap` (2 s) | hold |
| 5 | otherwise | `.endNow` |

- **Hold** means `.endAfterCappedWait(remaining:)`, where `remaining` is the largest `cap − elapsed` among the rules that apply. The session asks again after `recheckInterval` (0.1 s). Because `elapsed` keeps growing, the reveal ends by then at the latest.
- `skipsPhoto(signal)` is true only for `.outsideClick`.

Write it exactly in this shape (the names are load-bearing, because tests and plan 013 use them):

```swift
import Foundation

/// What ended, or may have ended, a revealed app's menu or popover. Each is only a hint:
/// `RevealClosePolicy` decides whether the reveal really ends, because switching the app off
/// under a panel that's still up leaves the panel stranded and the app's toggle out of step.
public enum RevealCloseSignal: String, CaseIterable, Sendable {
    case menuClosed = "AXMenuClosed"
    case focusMovedAway = "AXFocusedWindowChanged"
    case windowDestroyed = "AXUIElementDestroyed"
    case appDeactivated = "AXApplicationDeactivated"
    case windowsGone = "the app's menu or popover went off screen"
    case outsideClick = "mouse-down outside the app"
    case inactivity = "no activity"
}

/// What the screen and the mouse look like as a close signal is judged.
public struct RevealCloseInputs: Equatable, Sendable {
    /// A window of the app's that appeared after the press is on screen.
    public var postPressWindowsOnScreen: Bool
    /// One of those windows hangs from the menu bar: a menu, popover or panel under the icon.
    public var hangsFromBar: Bool
    /// A mouse button is held down: a click is under way somewhere.
    public var mouseButtonDown: Bool
    /// An outside click landed in the menu bar and no other app's menu or panel has finished
    /// opening from it yet.
    public var otherAppOpening: Bool
    /// Seconds since the close signal arrived.
    public var elapsed: Double

    public init(postPressWindowsOnScreen: Bool = false, hangsFromBar: Bool = false,
                mouseButtonDown: Bool = false, otherAppOpening: Bool = false, elapsed: Double = 0) { ... }
}

public enum RevealCloseDecision: Equatable, Sendable {
    /// Not a close: the reveal goes on.
    case keepWaiting
    /// The app is done with its menu: photograph (unless skipped) and switch it off.
    case endNow
    /// A close, held back: ask again after `RevealClosePolicy.recheckInterval`; it ends within
    /// `remaining` seconds at the latest.
    case endAfterCappedWait(remaining: Double)
}

/// The decisions a reveal makes as its menu or popover may be closing, free of AppKit so they
/// can be tested (spec "Clicking an icon", step 6).
public enum RevealClosePolicy {
    /// How long a window the press opened (not one hanging from the bar) may hold the switch-off.
    public static let windowCap: Double = 3
    /// How long a held mouse button, or another app opening its menu, may hold the switch-off.
    public static let clickCap: Double = 2
    /// How often a held close is judged again.
    public static let recheckInterval: Double = 0.1

    public static func decide(_ signal: RevealCloseSignal, _ inputs: RevealCloseInputs) -> RevealCloseDecision {
        // Switching off under a hanging menu or popover strands it on a neighbour's icon.
        if inputs.hangsFromBar { return .keepWaiting }
        var remaining = 0.0
        if inputs.postPressWindowsOnScreen { remaining = max(remaining, windowCap - inputs.elapsed) }
        if inputs.mouseButtonDown { remaining = max(remaining, clickCap - inputs.elapsed) }
        if signal == .outsideClick, inputs.otherAppOpening { remaining = max(remaining, clickCap - inputs.elapsed) }
        return remaining > 0 ? .endAfterCappedWait(remaining: remaining) : .endNow
    }

    /// An outside click is someone moving on to another menu; a photo burst then would re-lay
    /// out the bar (the screen-recording indicator) while that menu opens.
    public static func skipsPhoto(_ signal: RevealCloseSignal) -> Bool { signal == .outsideClick }
}
```

### The session's phases (`RevealCoordinator.swift`, `RevealSession`)

`reason: String?` becomes a phase:

- **`.watching`**: no close pending.
- **`.closing(signal, since)`**: a hint is being held. A recheck task calls the policy every 0.1 s.
  - New activity (a menu or window opening, a click in the app's windows or on its icon) drops the hint and goes back to `.watching`.
  - A later `.outsideClick` replaces the pending signal and restarts `since`.
  - Any other later signal is ignored.
- **`.ended`**: the policy said end.
  - `menuDepth` is reset to 0.
  - Every listener stays installed, but now it only notices a **re-open**: `AXMenuOpened`, `AXWindowCreated`, or a post-press window hanging from the bar on a poll.
  - `isInUseAgain` reports it. The coordinator passes that to `endReveal(unlessInUse:)`, which asks it immediately before the switch-off write. When it returns true, nothing is written. The coordinator logs, calls `resumeWatching()` and waits for the next close.

**Treating other hints as an outside click.** A close hint counts as `.outsideClick` in either of two cases:
- (a) it arrives while a mouse button is down, with the pointer neither on the app's windows nor on its icon. This catches the other app's click reaching YeeHaw as an AX notification before, or instead of, the global mouse-down;
- (b) an outside click was seen less than `RevealClosePolicy.clickCap` seconds earlier. This catches an outside click that rule 1 dismissed while the menu or popover still hung from the bar, followed a moment later by `windowsGone` or `AXMenuClosed` as that surface closes.

The outside click is remembered in `outsideClickAt` and `otherAppWatch`. Both are cleared on activity and when the close is decided, but *not* on `.keepWaiting`.

**`otherAppOpening`:**
- Set up only when the outside click (or the pointer, for the case above) was in the menu bar. At that moment, snapshot the on-screen window IDs of every process except the revealed app.
- After that, it is true until some *new* window of another process hangs from the bar with bounds identical on two consecutive rechecks, meaning it has finished opening.
- YeeHaw's own strip counts as another app here.

## Steps

### Step 0: Branch, drift check, baseline

1. Run the drift check at the top of this plan.
2. `git switch -c advisor/002-reveal-session`
3. `swift test 2>&1 | tee /tmp/yeehaw-test.log`

**Verify**:
- `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/UI/StatusItemController.swift Sources/YeeHawCore/MenuBarController.swift` prints nothing.
- `swift test` exits 0.
- `grep -c "warning:" /tmp/yeehaw-test.log` prints `0`.
- `grep -c "✘" /tmp/yeehaw-test.log` prints `0`.

### Step 1: Add the pure close policy and its tests

1. Create `Sources/YeeHawCore/RevealClosePolicy.swift` exactly as in "The design". Fill in the memberwise `init`.
2. Create `Tests/YeeHawCoreTests/RevealClosePolicyTests.swift` with the tests listed under "Test plan → RevealClosePolicyTests".

The policy has no callers yet. That's fine.

**Verify**:
- `swift test --filter RevealClosePolicyTests` exits 0, with 14 `@Test` functions passing (parameterized ones count their cases separately).
- `grep -n "import AppKit" Sources/YeeHawCore/RevealClosePolicy.swift` prints nothing.

Commit: `feat: judge a reveal's close signals in a pure, tested policy`.

### Step 2: Let the controller hold a switch-off while the panel is open again

In `Sources/YeeHawCore/MenuBarController.swift`:

1. Add to `ControllerError`:
   ```swift
   /// An earlier reveal of this app is still pending and its menu or panel is open, so YeeHaw
   /// won't switch it off to make room for another reveal.
   case revealInUse(BundleID)
   ```
2. Change `finishReveal()` to `@discardableResult private func finishReveal(stillInUse: (@MainActor () -> Bool)? = nil) async throws -> Bool`:
   - With nothing pending, return `true`.
   - Inside the `if state.journal.contains(pending.bundleID)` branch, right before `try writeAllow(locations.map { .addLocation(id, $0) } + [.switchOff(id)])`, add `if stillInUse?() == true { return false }`. Nothing has been written at that point, so returning leaves `pendingReveal`, the Allow list and the positions untouched.
   - Return `true` at the end.
   - Update the doc comment to say it.
3. Change `endReveal()` to:
   ```swift
   /// `unlessInUse` is asked right before the switch-off is written; when it returns true nothing
   /// is written, the reveal stays pending and this returns false (the app opened its menu again).
   @discardableResult
   public func endReveal(unlessInUse: (@MainActor () -> Bool)? = nil) async throws -> Bool {
       try await gated { try await finishReveal(stillInUse: unlessInUse) }
   }
   ```
4. Change `beginReveal` to `public func beginReveal(_ id: BundleID, nextTo yeehaw: MenuBarItem, leftoverInUse: (@MainActor (BundleID) -> Bool)? = nil) async throws -> MenuBarItem`. Replace line 365 with:
   ```swift
   if let leftover = state.pendingReveal?.bundleID {
       let check = leftoverInUse.map { inUse in { inUse(leftover) } }
       guard try await finishReveal(stillInUse: check) else { throw ControllerError.revealInUse(leftover) }
   }
   ```
   Leave the not-honored call at line 389 as `try await finishReveal()`.
5. Add the five tests listed under "Test plan → MenuBarControllerTests".

**Verify**:
- `swift test --filter MenuBarControllerTests` exits 0, including the five new tests.
- The existing `secondRevealFinishesTheFirst` and `revealUsesSlotLeftOfYeeHawAndRestores` still pass unchanged.
- `swift build` exits 0.

Commit: `feat: let a reveal's switch-off wait while the app's menu is open again`.

### Step 3: Add the new outcomes and their notices

1. In `RevealCoordinator.swift`, change `Outcome` (lines 51-59) to:
   ```swift
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
   ```
   Nothing returns the new cases yet. Step 6 does that.
2. In `StatusItemController.swift`:
   - Add to `RevealProblem`:
     ```swift
     /// The app was drawn but YeeHaw couldn't press its icon.
     case pressFailed(BundleID)
     /// An earlier reveal's app still has its menu or panel open (`open`), so `clicked` wasn't revealed.
     case stillOpen(open: BundleID, clicked: BundleID)
     ```
   - In `notice(...)`, add:
     - `.pressFailed(let id)` → `StripNotice(message: "YeeHaw couldn’t click \(name(id))’s icon.", action: .retry(id))`
     - `.stillOpen(let open, let clicked)` → `StripNotice(message: "\(name(open))’s menu is still open. Close it, then try again.", action: .retry(clicked))`
     - Use the typographic apostrophe `’`, as the existing messages do.
   - In `select`'s switch:
     - change `case .revealed:` to `case .revealed, .nothingOpened:`;
     - add `case .pressFailed: reportProblem(.pressFailed(id))`;
     - add `case .failed(ControllerError.revealInUse(let open)): reportProblem(.stillOpen(open: open, clicked: id))`, placed before the bare `case .failed:`.
3. Add the two `StripNoticeTests` listed in the test plan.

**Verify**:
- `swift build` exits 0.
- `swift test --filter StripNoticeTests` exits 0.

Commit: `feat: give a failed press and a still-open earlier reveal their own notices`.

### Step 4: Read the outside click's location correctly (F12)

1. In `RevealCoordinator.swift`, add an internal (not private) enum at file scope:
   ```swift
   /// Menu bar geometry for a reveal's click checks, kept pure so it can be tested.
   enum RevealGeometry {
       struct Screen: Equatable {
           let frame: NSRect
           /// The bar's height: the screen's top inset, at least the status bar's thickness
           /// (an auto-hidden bar leaves no inset).
           let barHeight: CGFloat
       }
       @MainActor static func screens() -> [Screen]
       /// Whether a point (AppKit screen coordinates) is in a screen's menu bar. The top edge
       /// counts: a click on the screen's top row has `y == frame.maxY`, which `NSRect.contains`
       /// leaves out.
       static func isInMenuBar(_ point: NSPoint, screens: [Screen]) -> Bool
       static func isOnIcon(_ point: NSPoint, icon: ClosedRange<Double>, screens: [Screen]) -> Bool
   }
   ```
   - `screens()` maps `NSScreen.screens` with `barHeight = max(frame.maxY - visibleFrame.maxY, NSStatusBar.system.thickness)`. That's the formula from today's `isOnIcon`.
   - `isInMenuBar` finds the screen whose `minX <= x < maxX` and `minY <= y <= maxY` (inclusive top, which gives the 1 pt tolerance), then returns `y >= frame.maxY - barHeight`.
   - `isOnIcon` returns `icon.contains(point.x) && isInMenuBar(point, screens:)`.
2. Replace `RevealSession.isOnIcon` (lines 532-538) with a call to `RevealGeometry.isOnIcon(point, icon: icon, screens: RevealGeometry.screens())`. Return false when `icon` is nil.
3. In `startWatching` (line 385), replace `let location = event.locationInWindow` with:
   ```swift
   // Where the click happened, not where the pointer is now. `locationInWindow` is relative to
   // the other app's window for a global event, so flip the global Quartz location instead.
   let location = StripPanel.appKitScreenPoint(event.cgEvent?.location) ?? NSEvent.mouseLocation
   ```
4. Create `Tests/YeeHawTests/RevealGeometryTests.swift` with the tests in the test plan.

**Verify**:
- `grep -n "locationInWindow" Sources/YeeHaw/System/RevealCoordinator.swift` prints only the comment line, never code.
- `swift test --filter RevealGeometryTests` exits 0.

Commit: `fix: read a reveal's outside-click location in screen coordinates`.

### Step 5: Route every close signal through the policy and keep watching until the switch-off (F2, F3)

All of this is in `RevealSession` and `RevealCoordinator.run`, in `RevealCoordinator.swift`.

1. **Phase and close types.** Replace `private var reason: String?` and `private var waiter: CheckedContinuation<String, Never>?` with:
   ```swift
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
   ```
   Make `RevealSession`'s access level `fileprivate` if `Close` has to be visible to `RevealCoordinator`. Both types are in the same file.

2. **Window helpers.**
   - Generalize `onScreenWindows(of:)` to `onScreenWindows(owner: (pid_t) -> Bool) -> Set<CGWindowID>`.
   - Add `barHangingWindows(owner: (pid_t) -> Bool, excluding: Set<CGWindowID>) -> [CGWindowID: CGRect]`, built from today's `hangsFromBar()` math (lines 542-561, unchanged).
   - In both helpers, skip windows whose `kCGWindowAlpha` is 0. An app that fades its popover out but leaves it ordered in would otherwise hold the reveal open forever under rule 1.
   - `hangsFromBar()` becomes `!Self.barHangingWindows(owner: { $0 == pid }, excluding: windowsBeforePress).isEmpty`.
   - Add a `static func anyWindowHangsFromBar(of pids: Set<pid_t>) -> Bool` for Step 7.

3. **`surfaceOpened`** becomes `everOpened || !Self.onScreenWindows(owner: { $0 == pid }).subtracting(windowsBeforePress).isEmpty`. Set `everOpened = true` in three places: on `AXMenuOpened`, in `track(_:)`, and whenever a poll or recheck finds post-press windows.

4. **`signal(_ s: RevealCloseSignal)`** replaces `close(_:)`:
   - In `.ended`: return.
   - In `.closing(let pending, _)`: if `s == .outsideClick && pending != .outsideClick`, set `phase = .closing(.outsideClick, since: .now)`. Otherwise return.
   - In `.watching`:
     - if `s != .outsideClick`, treat it as `.outsideClick` in either case from "Treating other hints as an outside click":
       - (a) a mouse button is down (`NSEvent.pressedMouseButtons != 0`) and `NSEvent.mouseLocation` is neither in the app's windows nor on the icon. Record `outsideClickAt = .now`, and set up `otherAppWatch` if that point is in the menu bar (see 6);
       - (b) `outsideClickAt` is less than `RevealClosePolicy.clickCap` seconds ago. Keep the existing `otherAppWatch`;
     - then set `phase = .closing(s, since: .now)`.
   - Then call `evaluate()`.

5. **`evaluate()`**:
   - Requires `.closing(let s, let since)`.
   - Builds `RevealCloseInputs`:
     - `postPressWindowsOnScreen`: the post-press window IDs, also unioned into `windowsSincePress`, so a later poll can report them gone;
     - `hangsFromBar`: `hangsFromBar()`;
     - `mouseButtonDown`: `NSEvent.pressedMouseButtons != 0`;
     - `otherAppOpening`: `otherAppOpening()`;
     - `elapsed`: seconds since `since`.
   - Then switches on `RevealClosePolicy.decide(s, inputs)`:
     - `.keepWaiting`:
       - log `close hint \(s.rawValue) ignored: a window the press opened hangs from the bar`;
       - cancel `recheck` and set `phase = .watching`. Leave `outsideClickAt` and `otherAppWatch` alone: case (b) needs them when the surface closes a moment later;
       - restart the timer if watching has started (`if timer != nil { restartTimer() }`).
     - `.endNow`: `finish(s)`.
     - `.endAfterCappedWait(let remaining)`:
       - if `recheck` is nil, log `close hint \(s.rawValue): holding the switch-off (<reasons>), at most \(ms) ms`. `<reasons>` joins whichever apply: `a window the press opened is still up`, `a mouse button is down`, `another app is opening its menu`. `ms` is `remaining` × 1000, rounded;
       - start `recheck = Task { [weak self] in while !Task.isCancelled { try? await Task.sleep(for: .seconds(RevealClosePolicy.recheckInterval)); guard let self, !Task.isCancelled else { return }; self.evaluate() } }`.

6. **`otherAppOpening()`**:
   - Returns false when `otherAppWatch` is nil.
   - Otherwise:
     - computes `now = Self.barHangingWindows(owner: { $0 != pid }, excluding: watch.before)`;
     - sets `settled = now.contains { watch.lastBounds[$0.key] == $0.value }`;
     - stores `now` as `lastBounds`;
     - returns `!settled`.
   - Set `otherAppWatch = (Self.onScreenWindows(owner: { $0 != pid }), [:])` when an outside click's point `RevealGeometry.isInMenuBar`.

7. **`finish(_ s:)`**:
   - Cancels `recheck`.
   - Sets `phase = .ended`, `menuDepth = 0`, `reopened = false`, `outsideClickAt = nil`, `otherAppWatch = nil`.
   - Sets `decided = Close(signal: s, skipsPhoto: RevealClosePolicy.skipsPhoto(s))`.
   - Resumes and clears `waiter`.

8. **Signal sources.** Rewrite each to call `signal` instead of `close`. Remove every `guard reason == nil`.
   - `handle`:
     - Keep `seen.append` and `onFirstSurface` as they are.
     - In `.ended`, only `AXMenuOpened` and `AXWindowCreated` matter, and they set `reopened = true`.
     - Otherwise:
       - `AXMenuClosed` at depth 0 → `signal(.menuClosed)`;
       - `AXFocusedWindowChanged` to an untracked window while others are tracked → `signal(.focusMovedAway)`;
       - `AXUIElementDestroyed` of a tracked window → `signal(.windowDestroyed)`;
       - `AXApplicationDeactivated` → `signal(.appDeactivated)`.
   - `checkWindows`:
     - in `.ended`, `if hangsFromBar() { reopened = true }`;
     - otherwise as today, but `signal(.windowsGone)`.
   - The timer: replace the `hangsFromBar()` branch with `self.signal(.inactivity)`. Rule 1 now restarts it.
   - `mouseDown(at:)`:
     - in `.ended`, return;
     - if `appWindowsContain(point) || isOnIcon(point)`, call `activity()` (constraint 3);
     - otherwise:
       - set `outsideClickAt = .now`;
       - if `RevealGeometry.isInMenuBar(point, …)`, set up `otherAppWatch`;
       - then `signal(.outsideClick)`.
     - Remove the separate `hangsFromBar()` branch: rule 1 now covers it (constraint 4).
   - `activity()`:
     - always clears `outsideClickAt` and `otherAppWatch`;
     - when in `.closing`, also cancels `recheck`, sets `phase = .watching` and logs `close hint dropped: the app is in use again`.

9. **Public surface.**
   - `waitForClose() async -> Close` returns `decided` at once if set, else stores the continuation.
   - `var isInUseAgain: Bool { reopened || hangsFromBar() }`.
   - `func resumeWatching()` sets `phase = .watching`, `decided = nil`, `reopened = false`, `windowsSincePress = []`, and restarts the timer.
   - `tearDown()` also cancels `recheck`.

10. **`RevealCoordinator.end`** becomes `private func end(_ step: …, unlessInUse: (@MainActor () -> Bool)? = nil) async -> Bool`:
    - Pass `unlessInUse` to both `controller.endReveal(unlessInUse:)` calls.
    - Return `false` only when an `endReveal` call returned `false`. Return `true` in every other case, including after the double-failure fault log.
    - Keep the unstructured `Task` and the retry.
    - Existing callers that ignore the result need `_ = await end(step)`, or mark `end` `@discardableResult`.

11. **`run`**: replace lines 131-141 with:
    ```swift
    if pressed {
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
        return .revealed  // Step 6 refines this
    }
    session.tearDown()
    await end(step)
    return .revealed
    ```
    Set `session.log = step` right after creating the session (line 120).

**Verify**:
- `swift build` exits 0.
- `grep -n 'close("' Sources/YeeHaw/System/RevealCoordinator.swift` prints nothing.
- `grep -n "reason == nil" Sources/YeeHaw/System/RevealCoordinator.swift` prints nothing.
- `grep -c "RevealClosePolicy\.\(decide\|skipsPhoto\)" Sources/YeeHaw/System/RevealCoordinator.swift` prints `2` or more.
- `grep -n "beforePress()" Sources/YeeHaw/System/RevealCoordinator.swift` still prints one line, before the press (constraint 1).
- `grep -n "windowPollInterval" Sources/YeeHaw/System/RevealCoordinator.swift` still prints the poll (constraint 6).
- `swift test 2>&1 | tee /tmp/yeehaw-test.log` exits 0, with 0 warnings.

Commit: `fix: never switch a revealed app off while its menu or panel is up or opening again`.

### Step 6: Press at most once after something opened; report a failed press (F5)

In `RevealCoordinator.swift`:

1. Change `pressGrace` to `0.6`. Update its comment: "After a press, how long to wait for a menu or window before trying another method (the window poll is the signal; zWhisper's popover sends no notification)". Add `static let surfaceCheckInterval: Double = 0.05`.
2. Add `private func waitForSurface(_ session: RevealSession) async -> Bool`. It polls `session.surfaceOpened` every `surfaceCheckInterval` for up to `pressGrace`, and returns as soon as it's true.
3. Extract the find-retry loop (lines 201-207) into `private func performFinding(_ method: PressMethod, item: MenuBarItem, pid: pid_t, right: Bool = false) async -> (PressResult, took: Int64)`. Use it in both `press` and `rightClick`, so the right-click gets the same `findTimeout` retry.
4. Rewrite `press` so that each method:
   - Runs only after this check: `if session.surfaceOpened { step("press: the app opened its menu or window; no \(method.rawValue)"); return true }`.
   - On `.notFound`: log as today, then `return session.surfaceOpened`.
   - On `.done` for `.click`: as today, `return true`.
   - On `.done` for AXPress or AXShowMenu, and on `.failed(code)`:
     - log as today;
     - then `if await waitForSurface(session) { step("press \(method.rawValue): menu or window on screen"); return true }`.
     - For `.done` only (Fiddle, constraint 5):
       - log `press \(method.rawValue): nothing opened within \(Int(Self.pressGrace * 1000)) ms; clicking`;
       - re-check `session.surfaceOpened` once more and return true if set;
       - post the click with `performFinding(.click, …)`;
       - return `true` if it's `.done`, else `session.surfaceOpened`.
     - For `.failed`: log `press \(method.rawValue): nothing opened within \(ms) ms; trying the next method` and continue.
   - After the loop: `step("press: every method failed")`, then `return session.surfaceOpened`.
5. Change `rightClick` to take the session, and use `performFinding(.click, …, right: true)`. On `.done`, return true. Otherwise log, then `return session.surfaceOpened`.
6. In `run`:
   - Make `let pressed = …` use the session-taking `rightClick`.
   - Replace `if pressed {` with `if pressed || session.surfaceOpened {`.
   - Inside it, after `tearDown`, `return session.everOpened ? .revealed : .nothingOpened`. Log `the press opened nothing before the reveal ended` first when it's `.nothingOpened`.
   - In the else path, log `press failed: nothing reached the icon` and `return .pressFailed` after `end`.

**Verify**:
- `grep -n "pressGrace: Double = 0.6" Sources/YeeHaw/System/RevealCoordinator.swift` prints one line.
- `grep -n "performFinding(.click" Sources/YeeHaw/System/RevealCoordinator.swift` prints at least two lines: the fallback click and the right-click.
- `grep -n "return .pressFailed" Sources/YeeHaw/System/RevealCoordinator.swift` prints one line.
- `grep -n "return .nothingOpened\|\.revealed : \.nothingOpened" Sources/YeeHaw/System/RevealCoordinator.swift` prints one line.
- `swift build` exits 0.

Commit: `fix: press a revealed icon at most once after something opened; report a failed press`.

### Step 7: Leave an earlier reveal alone while its panel is open (F2, `beginReveal`)

In `RevealCoordinator.run`:

1. Call `controller.beginReveal(id, nextTo: yeehaw, leftoverInUse: { leftover in RevealSession.anyWindowHangsFromBar(of: Set(NSRunningApplication.runningApplications(withBundleIdentifier: leftover).map(\.processIdentifier))) })`.
2. In the `catch`, before `await end(step)`, add:
   ```swift
   if case ControllerError.revealInUse(let open) = error {
       // Ending it here would switch that app off under its open menu or panel.
       step("beginReveal refused: \(open)'s menu or panel is still open from an earlier reveal")
       return .failed(error)
   }
   ```

**Verify**:
- `grep -n "leftoverInUse:" Sources/YeeHaw/System/RevealCoordinator.swift` prints one line.
- `grep -n "revealInUse" Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/UI/StatusItemController.swift` prints at least one line in each file.
- `swift test 2>&1 | tee /tmp/yeehaw-test.log` exits 0.
- `grep -c "warning:" /tmp/yeehaw-test.log` prints `0`.
- `grep -c "✘" /tmp/yeehaw-test.log` prints `0`.

Commit: `fix: don't switch off an earlier reveal's app while its panel is open`.

### Step 8: Live verification (operator)

Do this only when the operator asks you to install. It needs the owner's Mac, Accessibility and Screen Recording granted to YeeHaw, and DigUp, Fiddle and zWhisper hidden by YeeHaw (they show as tiles in the strip).

The 16:50 spacing incident may have left some apps in a broken state. A hidden process still gets clicks but can't show panels. First, quit and reopen DigUp and Fiddle by hand:

```sh
pkill -x DigUp; pkill -x Fiddle; sleep 2; open -a DigUp; open -a Fiddle
```

Then install:

```sh
scripts/build-app.sh --install && (pkill -x YeeHaw; open ~/Applications/YeeHaw.app)
```

Bundle IDs: zWhisper `app.zwhisper.zWhisper`, Fiddle `edu.umontana.fiddle`, DigUp `com.abdurrahim.DigUp`.

For each scenario:
1. Click YeeHaw's hat.
2. Act as described.
3. Run the reveal-log command right after.

Every line has the form `reveal <bundle id> +<ms> ms: <text>`. "In order" means these texts appear in this order for that bundle ID. Other lines may come between them.

| # | App and action | Expected `reveal` lines, in order | Must NOT appear |
|---|---|---|---|
| A | **zWhisper, left click.** Click its tile. The popover opens. Click the revealed zWhisper icon to close it. | `strip off screen` · `press AXPress: worked in` · `press AXPress: menu or window on screen` · `close: the app's menu or popover went off screen` · `photographed` · `endReveal done` | `clicking` (no fallback click: the popover opened), `not photographing` |
| B | **zWhisper, outside click under a popover.** Open the popover as in A, then click an empty area of the desktop. | `press AXPress: menu or window on screen` · `close hint mouse-down outside the app ignored: a window the press opened hangs from the bar` · `close: mouse-down outside the app` (the popover closing within 2 s of the click counts as that click, case (b)) · `not photographing: the close was a click outside the app` · `endReveal done` | `photographed` for this reveal; the popover visibly staying open after the icon disappears |
| C | **zWhisper, right click.** Right-click (or Control-click) its tile. The menu (Modes, History, Quit) opens. Press Esc. | `strip off screen` · `right-click posted` · `AXMenuOpened (first menu or window on screen)` · `close: AXMenuClosed` (it may be preceded by a `close hint AXMenuClosed ignored` line, then `close: the app's menu or popover went off screen`) · `photographed` · `endReveal done` | `press failed`, `right-click: no extras-bar element` |
| D | **Fiddle (MenuBarExtra).** Click its tile. Its window opens under the icon. Click an empty area of the desktop. | `press AXPress: worked in` · `press AXPress: nothing opened within 600 ms; clicking` · `press synthesized click: click posted` · `close: mouse-down outside the app` · `not photographing: the close was a click outside the app` · `endReveal done` | a second `click posted` for this reveal (`… \| grep edu.umontana.fiddle \| grep -c "click posted"` must print `1`) |
| E | **DigUp (NSMenu).** Click its tile. The menu opens. Press Esc. | `press AXPress: worked in` · `AXMenuOpened (first menu or window on screen)` · `press AXPress: menu or window on screen` · `close: AXMenuClosed` (or `close: the app's menu or popover went off screen` after a `close hint … ignored` line) · `photographed` · `endReveal done` | `clicking` |
| F | **F3: an outside click on another icon.** Reveal zWhisper as in A, so its popover is open. Then click any *visible* menu bar icon of another app (Control Center, or Wi-Fi). Repeat with DigUp's menu open (as in E) instead of zWhisper's popover. | `close: mouse-down outside the app` · `not photographing: the close was a click outside the app` · `endReveal done`. A `close hint … ignored` line and/or a `close hint mouse-down outside the app: holding the switch-off (… another app is opening its menu …)` line may come before the close. | `photographed` for that reveal |
| G | **F2: re-open during the close.** Reveal zWhisper, and click its revealed icon twice quickly (about 0.3–0.5 s apart). | The popover is open and the zWhisper icon is still drawn after the second click. Either `the app's menu or panel opened again before the switch-off; watching again` appears, or no `close:` line appears until you close the popover. Then close it with one click: `close: …` · `photographed` · `endReveal done`. | `endReveal done` while the popover is still visible |

Expected results:
- In F, the other app's menu opens in its normal place and stays open.
- In every scenario, `endReveal done` appears within about 3.5 s of the menu or popover visibly closing (the 3 s window cap plus a 0.25 s poll).
- After each scenario, the revealed icon is gone from the bar and the strip tile is back.

Evidence: take a screenshot in G after the second click, and in F after clicking the other icon:

```sh
screencapture -x -R 0,0,2056,80 /tmp/yeehaw-002-G.png
```

The screenshot must show the popover (G) or the other app's menu (F) open.

**Verify**: every row's expected lines are present, and none of its "must NOT appear" lines are.

## Test plan

### `Tests/YeeHawCoreTests/RevealClosePolicyTests.swift` (new)

`@Suite struct RevealClosePolicyTests`, modelled on `LaunchRulesTests.swift`. Use a helper `static func at(_ elapsed: Double = 0, windows: Bool = false, hangs: Bool = false, button: Bool = false, opening: Bool = false) -> RevealCloseInputs`.

1. `everySignalEndsAtOnceWhenNothingIsLeft`. `@Test(arguments: RevealCloseSignal.allCases)`: `decide(s, at())` == `.endNow`.
2. `aWindowHangingFromTheBarKeepsTheRevealForEverySignal`. Arguments: all cases. With `windows: true, hangs: true`, at elapsed 0 and at 100, and with `button: true, opening: true`, the result is always `.keepWaiting`.
3. `menuClosedWithAnOrdinaryWindowStillUpWaitsAtMostThreeSeconds`. With `.menuClosed, windows: true`:
   - at 0 → `.endAfterCappedWait(remaining: 3)`;
   - at 1 → `(remaining: 2)`;
   - at 3 → `.endNow`;
   - at 4 → `.endNow`.
4. `focusMovingAwayWhileAnotherPostPressWindowIsUpWaits`. `.focusMovedAway, windows: true` at 0 → `.endAfterCappedWait(remaining: 3)`.
5. `oneWindowDestroyedWhileAnotherHangsKeepsTheReveal`. `.windowDestroyed, windows: true, hangs: true` → `.keepWaiting`.
6. `deactivationUnderAnOpenPopoverKeepsTheReveal`. `.appDeactivated, windows: true, hangs: true` → `.keepWaiting`.
7. `inactivityUnderAHangingWindowKeepsTheReveal`. `.inactivity, windows: true, hangs: true` → `.keepWaiting`.
8. `anOutsideClickWaitsForTheMouseButtonToComeUp`. With `.outsideClick, button: true`:
   - at 0 → `(remaining: 2)`;
   - at 1.5 → `(remaining: 0.5)`;
   - at 2 → `.endNow`.
   - With `button: false` at 0 → `.endNow`.
9. `anOutsideClickWaitsForTheOtherAppToFinishOpening`. `.outsideClick`:
   - `opening: true` at 0.5 → `(remaining: 1.5)`;
   - `opening: true` at 2 → `.endNow`;
   - `opening: false` at 0.5 → `.endNow`.
10. `theOtherAppsOpeningCountsOnlyForAnOutsideClick`. `.menuClosed, opening: true` → `.endNow`.
11. `aButtonHeldDuringAnyCloseHoldsTheSwitchOff`. `.menuClosed, button: true` at 0 → `(remaining: 2)`.
12. `theLongestRunningCapWins`. With `.outsideClick, windows: true, button: true`:
    - at 1 → `(remaining: 2)`;
    - at 2.5 → `(remaining: 0.5)`.
13. `onlyAnOutsideClickSkipsThePhoto`. Arguments: all cases. `skipsPhoto(s) == (s == .outsideClick)`.
14. `capsMatchTheSpec`. `windowCap == 3`, `clickCap == 2`, `recheckInterval == 0.1`.

### `Tests/YeeHawCoreTests/MenuBarControllerTests.swift` (add under `// MARK: reveal`)

Use the existing `revealSystem()` and `rig(_:state:)`, as `revealUsesSlotLeftOfYeeHawAndRestores` does.

1. `endRevealLeavesTheAppOnWhileItsMenuIsOpenAgain`:
   - `beginReveal(a)`;
   - record `allowWrites` and `positions`;
   - `let ended = try await c.endReveal(unlessInUse: { true })`;
   - expect `!ended`, `allowSnapshot[a] == true`, `pendingReveal?.bundleID == a`, unchanged `positions` and `allowWrites`.
   - Then `try await c.endReveal()` returns `true`, `allowSnapshot[a] == false`, and the positions equal the originals.
2. `endRevealAsksJustBeforeTheSwitchOff`. The closure records `system.allowWrites` when called and counts calls. Expect one call, made with `allowWrites` equal to the count before `endReveal`, so nothing had been written yet.
3. `endRevealWithNothingPendingNeverAsks`. On a fresh controller, the closure's call count stays 0 and the result is `true`.
4. `aSecondRevealLeavesAnOpenLeftoverAlone`:
   - Set up as in `secondRevealFinishesTheFirst`, then `beginReveal(a)`.
   - Expect `beginReveal(b, nextTo:, leftoverInUse: { $0 == Self.a })` to throw `ControllerError.revealInUse(Self.a)`. Use `await #expect(throws: ControllerError.revealInUse(Self.a)) { … }`.
   - Then expect `allowSnapshot[a] == true`, `allowSnapshot[b] == false`, and `pendingReveal?.bundleID == a`.
5. `aSecondRevealFinishesAClosedLeftover`. The same setup with `leftoverInUse: { _ in false }` behaves like `secondRevealFinishesTheFirst`, and the closure received `Self.a`.

### `Tests/YeeHawTests/RevealGeometryTests.swift` (new)

`@Suite struct RevealGeometryTests`. Use the owner's screen from `StripPlacementTests`: frame `0,0,2056,1329`, bar 39.

1. `theScreensTopRowIsInTheMenuBar`. `isInMenuBar((1538, 1329))` is true. That is the F12 tolerance: `NSRect.contains` would say false. `(1538, 1300)` is true. `(1538, 1289)` is false.
2. `aClickOnTheRevealedIconIsOnIt`. With icon `1521...1559`: `isOnIcon((1538, 1317))` is true, `(1600, 1317)` is false, and `(1538, 1200)` is false.
3. `aSecondDisplaysBarCounts`. Add screen `-1440,0,1440,900` with bar 24: `(-700, 900)` is true and `(-700, 870)` is false.

### `Tests/YeeHawTests/StripTests.swift` (add to `StripNoticeTests`)

1. `aFailedPressOffersToTryAgain`. `notice([], .pressFailed("dig"))` == `StripNotice(message: "YeeHaw couldn’t click DigUp’s icon.", action: .retry("dig"))`.
2. `aStillOpenEarlierRevealNamesItAndRetriesTheClickedApp`. `notice([], .stillOpen(open: "dig", clicked: "x"))` == `StripNotice(message: "DigUp’s menu is still open. Close it, then try again.", action: .retry("x"))`.

**Verification**: `swift test` exits 0. That covers the 448 baseline tests plus these 24 new `@Test` functions, with 0 warnings.

## Done criteria

ALL must hold:

- [ ] `swift build` exits 0.
- [ ] `swift test 2>&1 | tee /tmp/yeehaw-test.log` exits 0.
- [ ] `grep -c "warning:" /tmp/yeehaw-test.log` prints `0`.
- [ ] `grep -c "✘" /tmp/yeehaw-test.log` prints `0`.
- [ ] `test -f Sources/YeeHawCore/RevealClosePolicy.swift && test -f Tests/YeeHawCoreTests/RevealClosePolicyTests.swift && test -f Tests/YeeHawTests/RevealGeometryTests.swift` exits 0.
- [ ] `grep -c "@Test" Tests/YeeHawCoreTests/RevealClosePolicyTests.swift` prints `14`.
- [ ] `grep -n 'close("\|reason == nil\|event.locationInWindow' Sources/YeeHaw/System/RevealCoordinator.swift` prints nothing.
- [ ] `grep -n "unlessInUse" Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHawCore/MenuBarController.swift` prints lines in both files.
- [ ] `git diff --stat 495d26f -- Sources/YeeHaw/System/IconImageProvider.swift Sources/YeeHaw/UI/StripPanel.swift` prints nothing.
- [ ] `git diff 495d26f -- Sources/YeeHaw/UI/StatusItemController.swift | grep -n "beforePress\|onClosed"` prints nothing (the hooks are untouched).
- [ ] `git status --porcelain` lists only in-scope files.
- [ ] `git log --format=%B 495d26f..HEAD | grep -c "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"` equals the number of commits (`git rev-list --count 495d26f..HEAD`).
- [ ] The `plans/README.md` row for 002 reads `DONE`, or `DONE (live check pending)` if the operator didn't run Step 8.

## STOP conditions

Stop and report back (do not improvise) if:

- **Drift.** The drift check shows changes, and the excerpts in "Current state" don't match the live code.
- **Baseline.** At Step 0, `swift test` already fails or prints warnings. Report the baseline; don't fix unrelated code.
- **Old behaviour broke.** After Step 2, an existing `MenuBarControllerTests` reveal test fails. With the closures nil, the controller must behave exactly as before.
- **Concurrency.** Swift 6 strict concurrency rejects passing the `@MainActor` closures into `gated`, or into `end`'s unstructured `Task`, and the only fixes you can find are `@unchecked Sendable`, `nonisolated(unsafe)` or `MainActor.assumeIsolated`. Those are not part of the existing pattern for these paths.
- **Policy needs AppKit.** The policy tests seem to need AppKit or the live system. The policy must stay pure: the inputs are plain values.
- **Out of scope.** A step seems to need changes to `IconImageProvider.swift`, `StripPanel.swift`, the `onClosed` or `beforePress` wiring, or the pid lookup. Those belong to plans 003 and 006, and constraint 1.
- **Live: a reveal never ends.** No `endReveal done` appears within 35 s of the menu or popover visibly closing. That means a lingering window still counts as hanging from the bar. Report the log and the output of `CGWindowListCopyWindowInfo` for the app (layer, alpha, bounds). Don't add a hard cap: a cap re-creates the original bug.
- **Live: Fiddle.** Fiddle shows more than one `click posted` per reveal, or its window opens and closes at once.
- **Live: zWhisper's popover closes by itself** right after opening (a regression of constraint 1), or zWhisper's reveal never logs `close:` after its popover closes (a regression of constraint 6).
- **Live: F3 not fixed.** In scenario F with zWhisper's popover, the other app's menu fails to open, or opens and then jumps or closes. With DigUp's NSMenu open, a click that only dismisses DigUp's menu and opens nothing else may be macOS's own menu tracking. In that case, report it as an observation, not a STOP, provided the log still shows `not photographing`.

## Maintenance notes

- **Later plans.**
  - Plan 003 changes `reveal.onClosed`. It must keep `onClosed` skipped when `Close.skipsPhoto` is true.
  - Plan 006 replaces the `.first` pid. `RevealSession(pid:)` and the leftover check's pid set are where it plugs in.
  - Plan 013 counts `Outcome.nothingOpened` (pressed, nothing appeared) toward "stuck".
- **New delays the owner will notice.**
  - An app that opens an ordinary window from its menu (not one hanging from the bar) now keeps its icon up to 3 s longer (`windowCap`).
  - An outside click in the menu bar that opens nothing (empty bar space) holds the switch-off for up to 2 s (`clickCap`).
  - Both come from `RevealClosePolicy`. Tune them there, and update its tests.
- **For the reviewer.**
  - Check that the reopen loop in `run` always terminates: `end` returns `false` only when `unlessInUse` was true at the write.
  - Check that `menuDepth` is reset in `finish`, so a lost `AXMenuClosed` can't make `isInUseAgain` true forever.
  - Check that rule 1 can't hold a reveal forever because of an invisible window. Alpha-0 windows are skipped in both window helpers.
- **Left out on purpose.**
  - No hard upper limit on a reveal while a window hangs from the bar. A cap re-creates the bug this plan fixes. The inactivity timer still restarts, as before.
  - The press chain is not extracted into a pure type. Its timing depends on AX and is covered by the live scenarios A–F.
