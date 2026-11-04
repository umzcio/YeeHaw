# Plan 013: The strip notices a hidden or stuck menu bar app and offers Unhide or Restart

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/UI/StripView.swift Sources/YeeHaw/UI/StatusItemController.swift Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/System/HiddenMenuBarApps.swift Sources/YeeHawCore/SpacingPlan.swift Tests/YeeHawTests/StripTests.swift`
> Changes here are **expected**: plan 001 creates `HiddenMenuBarApps.swift` and adds to
> `SpacingPlan.swift`; plan 002 rewrites much of `RevealCoordinator.swift` and adds outcomes and
> notices in `StatusItemController.swift` and `StripTests.swift`; plan 004 adds menu items and a
> new quit flow to `StatusItemController.swift`; plan 003 may change its capture code. Don't
> compare whole files. Instead, Step 0 checks the exact anchors this plan needs. STOP only if an
> anchor is missing.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: LOW (adds a notice and two user-triggered actions; never acts on its own)
- **Depends on**: `plans/001-spacing-never-hides-apps.md` (`RunningAppFacts`, `SpacingPlan.shouldUnhide`,
  `HiddenMenuBarApps`), `plans/002-reveal-never-switches-off-under-a-panel.md`
  (`RevealCoordinator.Outcome.nothingOpened`), `plans/004-restore-everything-and-safe-quit.md`
  (owns the "only `HiddenMenuBarApps.swift` calls `unhide()`" rule this plan keeps)
- **Category**: direction
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager: icons it hides live in a "strip" that opens from YeeHaw's
own menu bar icon, and clicking a strip tile briefly reveals and presses the real icon. On
2026-11-02 a spacing change left several menu-bar apps hidden (as Command-H hides an app). A hidden
app still gets its icon's clicks but can't show its panel or popover, so clicking it did nothing,
and the owner only found out by restarting each app by hand. Plan 001 removes that cause, but an
app can still end up hidden (Option-Command-H "Hide Others" hides menu-bar-only apps too) or wedged
for its own reasons. This plan adds a small health check: when the strip opens, its notice row
names a running menu-bar app that is hidden (button: **Unhide**) or whose icon was pressed twice in
a row with nothing opening (button: **Restart**). Nothing happens unless the user clicks the button.

## Design (decided; build exactly this)

- **Two issues, one notice.** The strip shows one notice line (`StripNotice`). Order of priority:
  missing file grant > last click's problem > **health issue** > YeeHaw's own icon missing.
  Within health: a hidden app beats a stuck one (Unhide is the known fix and cheaper).
- **Hidden** = a running app that owns a menu bar item (drawn now, or hidden by YeeHaw), passes
  `SpacingPlan.shouldUnhide(facts, menuBarOwners: [], own:)` from plan 001. Passing **empty**
  owners means only menu-bar-only (accessory, non-regular) apps count. A regular app the user hid
  with Command-H is normal and is never flagged. That function also skips Apple apps, YeeHaw, and
  apps outside `/Applications` and `~/Applications`.
- **Stuck** = plan 002's `Outcome.nothingOpened` (the icon was drawn and pressed but no menu or
  window appeared before the reveal ended) twice in a row for the same app. A reveal that opened
  something (`.revealed`) resets that app's count. `.pressFailed`, `.failed` and `.ignored` don't
  count either way (they have their own notices). Counts live in memory only and reset when YeeHaw
  quits.
- **When it's checked:** each time the strip opens (`currentNotice()`); no timers, no observers.
  After the second miss, nothing pops up. The notice appears the next time the user opens the strip.
- **Unhide:** unhides that app's running copies without activating them, then forgets its count.
- **Restart:** asks every running copy to quit the polite way (`terminate()`, never force), waits
  up to 10 s, then reopens each distinct bundle **shown and in the background**
  (`activates = false`, `hides = false`). On success its count is forgotten; on failure it's logged
  and the notice stays, so the user can try again or quit the app themselves.
- **Pure logic in YeeHawCore** (`MenuBarHealth`), tested there. AppKit calls stay thin wrappers.

## Current state

Anchors at 495d26f. Plans 001/002/004 change some of them; the expected state after them is
given too.

`StripNotice` (the notice row's model), `Sources/YeeHaw/UI/StripView.swift:5-27`:

```swift
/// A one-line problem under the strip's tiles, with the button that deals with it (if any).
struct StripNotice: Equatable {
    enum Action: Equatable {
        /// A missing file grant: Settings can fix it.
        case openSettings
        /// The app didn't appear in time: reveal it again.
        case retry(BundleID)
        /// The app isn't running: open it.
        case openApp(BundleID)
    }

    var message: String
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .openSettings: "Fix…"
        case .retry: "Try Again"
        case .openApp: "Open"
        case nil: nil
        }
    }
}
```

`NoticeRow` (`StripView.swift:264-286`) shows `message` on one line (`lineLimit(1)`) and a small
button titled `actionTitle` that calls `onNoticeAction(action)`. Keep messages short.

`StatusItemController` (`Sources/YeeHaw/UI/StatusItemController.swift`):

```swift
// :253-256
    private func currentNotice() -> StripNotice? {
        Self.notice(needsGrant: controller.state.needsGrant, problem: revealProblem, ownIconMissing: ownIconMissing,
                    name: AppIdentity.name(of:))
    }
// :258-280 (plan 002 adds .pressFailed and .stillOpen cases to the switch)
    static func notice(needsGrant: Set<GrantedFile>, problem: RevealProblem?, ownIconMissing: Bool,
                       name: (BundleID) -> String) -> StripNotice? {
        if !needsGrant.isEmpty { ... return StripNotice(..., action: .openSettings) }
        switch problem {
        case .didNotAppear(let id): ...
        case .notRunning(let id): ...
        case .failed(let id): ...
        case nil:
            break
        }
        if ownIconMissing { return StripNotice(message: "YeeHaw can’t find its own menu bar icon.") }
        return nil
    }
// :282-295
    private func noticeAction(_ action: StripNotice.Action) {
        strip.dismiss()
        switch action {
        case .openSettings:
            openSettings()
        case .retry(let id):
            select(id)
        case .openApp(let id):
            ...
        }
    }
// :309-322, select's switch on the reveal outcome, at 495d26f:
            switch await reveal.open(id, nextTo: yeehaw, secondary: secondary) {
            case .revealed:
                revealProblem = nil
            case .ignored:
                break
            ...
```

After plan 002, `RevealCoordinator.Outcome` has `revealed`, `nothingOpened`, `pressFailed`,
`ignored`, `failed(Error)`, and `select`'s switch starts with `case .revealed, .nothingOpened:`
followed by `revealProblem = nil`.

After plan 001, `Sources/YeeHawCore/SpacingPlan.swift` has:

```swift
public struct RunningAppFacts: Equatable, Sendable {
    public var bundleID: BundleID
    public var bundlePath: String
    public var isHidden: Bool
    public var isRegular: Bool
    public init(bundleID: BundleID, bundlePath: String, isHidden: Bool, isRegular: Bool)
}
// in extension SpacingPlan:
public static func shouldUnhide(_ app: RunningAppFacts, menuBarOwners: Set<BundleID>, own: BundleID,
                                home: String = NSHomeDirectory()) -> Bool
```

and `Sources/YeeHaw/System/HiddenMenuBarApps.swift` has `@MainActor enum HiddenMenuBarApps` with
`unhideAll(menuBarOwners:own:)`. Plan 004's done criteria require that
`grep -rn "func unhideAll\|unhide()" Sources | grep -v HiddenMenuBarApps.swift` prints nothing,
so any new `unhide()` call goes in `HiddenMenuBarApps.swift`.

Plan 004 computes menu bar owners as
`Set(controller.items.compactMap(\.bundleID)).union(controller.state.hidden)`; use the same set.

Conventions:
- Doc comments (`///`) explain why, in plain sentences. Exemplar:
  `Sources/YeeHaw/System/RevealCoordinator.swift`. User-facing strings use the typographic
  apostrophe `’` like the existing notices.
- Logging: `Logger(subsystem: Log.subsystem, category: "…")` (see `StatusItemController.swift:15`).
- Tests: Swift Testing. Pure tests in `Tests/YeeHawCoreTests` (model on
  `Tests/YeeHawCoreTests/SpacingPlanTests.swift`); notice tests in `StripNoticeTests`
  (`Tests/YeeHawTests/StripTests.swift:208`), whose helper calls `StatusItemController.notice(...)`
  with `name: { $0 == "dig" ? "DigUp" : $0 }`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Core tests | `swift test --filter MenuBarHealthTests 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| Notice tests | `swift test --filter StripNoticeTests 2>&1 \| tail -n 3` | passed |
| All tests | `swift test 2>&1 \| tail -n 3` | passed, no failures |
| Install and run (operator only, when asked) | `scripts/build-app.sh --install`, then `pkill -x YeeHaw; open ~/Applications/YeeHaw.app` | app relaunches |
| Logs (operator only) | `/usr/bin/log show --last 5m --predicate 'subsystem == "com.zapps.yeehaw"' --info --style compact` | lines from category `health` |

## Scope

**In scope** (the only files you should modify or create):
- `Sources/YeeHawCore/MenuBarHealth.swift` (create)
- `Tests/YeeHawCoreTests/MenuBarHealthTests.swift` (create)
- `Sources/YeeHaw/System/AppRestarter.swift` (create)
- `Sources/YeeHaw/System/HiddenMenuBarApps.swift` (add `unhide(_:)` and `runningFacts(of:)`)
- `Sources/YeeHaw/UI/StripView.swift` (`StripNotice` only)
- `Sources/YeeHaw/UI/StatusItemController.swift` (health state, `currentNotice`, `notice`, `noticeAction`, `select`'s outcome switch)
- `Tests/YeeHawTests/StripTests.swift` (`StripNoticeTests` only)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/YeeHaw/System/RevealCoordinator.swift`: plan 002 already reports `.nothingOpened`.
- `Sources/YeeHaw/System/SpacingApplier.swift`: its restart is for spacing; don't reuse or change it.
- `SpacingPlan.shouldUnhide` and `HiddenMenuBarApps.unhideAll`: use them as they are.
- Settings: the owner allowed "strip or Settings"; this plan does the strip only.

## Git workflow

- Start from the branch with plans 001, 002 and 004 merged (normally `build/yeehaw-v1`):
  `git checkout -b advisor/013-menu-bar-health-check`
- One commit per step, conventional commits, e.g.
  `feat: offer Unhide or Restart for a hidden or stuck menu bar app in the strip`.
  End each message with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No personal names. Never change the bundle ID (`com.zapps.yeehaw`) or signing settings.
  Do NOT push or open a PR.

## Steps

### Step 0: Confirm the dependencies are in place

Run each; all must match:

- `grep -E "^\| 00(1|2|4) " plans/README.md` → three rows, each with status `DONE`
- `grep -n "public struct RunningAppFacts" Sources/YeeHawCore/SpacingPlan.swift` → one line
- `grep -n "public static func shouldUnhide(_ app: RunningAppFacts, menuBarOwners: Set<BundleID>, own: BundleID" Sources/YeeHawCore/SpacingPlan.swift` → one line
- `grep -n "enum HiddenMenuBarApps" Sources/YeeHaw/System/HiddenMenuBarApps.swift` → one line
- `grep -n "case nothingOpened" Sources/YeeHaw/System/RevealCoordinator.swift` → one line
- `grep -n "case .revealed, .nothingOpened:" Sources/YeeHaw/UI/StatusItemController.swift` → one line
- `grep -n "static func notice(needsGrant:" Sources/YeeHaw/UI/StatusItemController.swift` → one line
- `grep -n "private func noticeAction" Sources/YeeHaw/UI/StatusItemController.swift` → one line
- `swift test 2>&1 | tail -n 3` → passed (baseline; note the test count)

### Step 1: The pure health model

Create `Sources/YeeHawCore/MenuBarHealth.swift`:

```swift
import Foundation

/// A running menu bar app whose icon may open nothing, and what would fix it.
public enum HealthIssue: Equatable, Sendable {
    /// Hidden, like Command-H. A hidden app still gets its icon's clicks but can't show the panel
    /// or popover they open. Unhiding fixes it.
    case hidden(BundleID)
    /// Its icon was pressed `MenuBarHealth.stuckAfter` times in a row and nothing opened.
    /// Restarting it usually fixes it.
    case stuck(BundleID)

    public var id: BundleID {
        switch self {
        case .hidden(let id), .stuck(let id): id
        }
    }
}

/// Notices running menu bar apps that can't show what their icon opens, so the strip can offer
/// the fix. Only remembers how many reveals in a row opened nothing; whether an app is hidden is
/// read fresh each time (`issue(among:own:home:)`).
public struct MenuBarHealth: Equatable, Sendable {
    /// Reveals in a row that opened nothing before an app counts as stuck. One could be a click
    /// on an icon that opens nothing by design; two in a row is worth a word.
    public static let stuckAfter = 2

    private var misses: [BundleID: Int] = [:]

    public init() {}

    /// Call when a reveal of `id` pressed its icon: `opened` is whether a menu or window appeared.
    public mutating func recordReveal(_ id: BundleID, opened: Bool) {
        if opened { misses[id] = nil } else { misses[id, default: 0] += 1 }
    }

    /// Call once the app was unhidden or restarted: it starts afresh.
    public mutating func forget(_ id: BundleID) {
        misses[id] = nil
    }

    public func isStuck(_ id: BundleID) -> Bool {
        misses[id, default: 0] >= Self.stuckAfter
    }

    /// The issue to show, if any, among the running copies of apps that own a menu bar item
    /// (`apps`, in the order to name them): a hidden menu-bar-only app first, else a stuck app.
    /// Hidden uses `SpacingPlan.shouldUnhide` with no owners, so a regular app someone hid with
    /// Command-H never counts.
    public func issue(among apps: [RunningAppFacts], own: BundleID,
                      home: String = NSHomeDirectory()) -> HealthIssue? {
        if let hidden = apps.first(where: { SpacingPlan.shouldUnhide($0, menuBarOwners: [], own: own, home: home) }) {
            return .hidden(hidden.bundleID)
        }
        if let stuck = apps.first(where: { $0.bundleID != own && isStuck($0.bundleID) }) {
            return .stuck(stuck.bundleID)
        }
        return nil
    }
}
```

Create `Tests/YeeHawCoreTests/MenuBarHealthTests.swift` with tests 1-6 from the Test plan.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter MenuBarHealthTests 2>&1 | tail -n 3` → passed, 6 tests

### Step 2: The notice's two new actions and texts

In `Sources/YeeHaw/UI/StripView.swift`, add to `StripNotice.Action`:

```swift
        /// A menu-bar-only app is hidden, so its icon may open nothing: unhide it.
        case unhide(BundleID)
        /// The app's icon opened nothing twice in a row: quit and reopen it.
        case restart(BundleID)
```

and to `actionTitle`: `case .unhide: "Unhide"` and `case .restart: "Restart"`.

In `StatusItemController.notice(...)`, add a parameter `health: HealthIssue? = nil` just before
`name:` (the default keeps existing callers compiling), and insert this block after the
reveal-problem `switch` and before the `ownIconMissing` line:

```swift
        switch health {
        case .hidden(let id)?:
            return StripNotice(message: "\(name(id)) is hidden, so its icon may open nothing.", action: .unhide(id))
        case .stuck(let id)?:
            return StripNotice(message: "\(name(id)) opened nothing the last two times.", action: .restart(id))
        case nil:
            break
        }
```

Update `notice`'s doc comment ("most pressing first: a missing grant…, then why the last click
failed, then a hidden or stuck app, each with the button that helps").

Add `StripNoticeTests` 7-9 from the Test plan.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output (if the compiler reports the
  `noticeAction` switch as non-exhaustive, that's Step 4; add `case .unhide, .restart: break`
  there temporarily and replace it in Step 4)
- `swift test --filter StripNoticeTests 2>&1 | tail -n 3` → passed

### Step 3: Unhide one app, read the running apps' facts, restart one app

In `Sources/YeeHaw/System/HiddenMenuBarApps.swift`, inside `enum HiddenMenuBarApps`, add:

```swift
    /// Unhides every running copy of `id` without activating it (the strip's Unhide). True when
    /// none is left hidden.
    @discardableResult
    static func unhide(_ id: BundleID) -> Bool {
        var allShown = true
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id)
        where app.isHidden && !app.isTerminated {
            if !app.unhide() {
                allShown = false
                log.error("Couldn't unhide \(id, privacy: .public)")
            }
        }
        return allShown
    }

    /// The running copies of `ids` (apps that own a menu bar item), as the health check reads
    /// them, in `ids` order. Copies that aren't app bundles are left out.
    static func runningFacts(of ids: [BundleID]) -> [RunningAppFacts] {
        var seen: Set<BundleID> = []
        return ids.filter { seen.insert($0).inserted }.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap { app in
                guard !app.isTerminated, let url = app.bundleURL, url.pathExtension == "app" else { return nil }
                return RunningAppFacts(bundleID: id, bundlePath: url.path, isHidden: app.isHidden,
                                       isRegular: app.activationPolicy == .regular)
            }
        }
    }
```

(`log` is the enum's existing `private static let log`. If plan 001 named it differently, use that.)

Create `Sources/YeeHaw/System/AppRestarter.swift`:

```swift
import AppKit
import os
import YeeHawCore

/// Quits an app the polite way and opens it again, for the strip's Restart: an app whose icon
/// stopped opening anything usually works again after a restart. Never force-quits. Reopens shown
/// and in the background, never hidden: apps reopened hidden are what broke icons on 2026-11-02.
@MainActor
enum AppRestarter {
    /// How long an app gets to quit before the restart gives up and leaves it running.
    static let quitTimeout: Duration = .seconds(10)
    static let pollInterval: Duration = .milliseconds(250)
    private static let log = Logger(subsystem: Log.subsystem, category: "health")

    /// True once every copy quit and every bundle opened again.
    static func restart(_ id: BundleID) async -> Bool {
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            !$0.isTerminated && $0.bundleURL?.pathExtension == "app"
        }
        let bundles = Array(Set(copies.compactMap(\.bundleURL)))
        guard !bundles.isEmpty else { return false }
        for copy in copies {
            guard copy.terminate() else {
                log.error("\(id, privacy: .public) refused to quit; not restarting it")
                return false
            }
        }
        let deadline = ContinuousClock.now + quitTimeout
        while copies.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else {
                log.error("\(id, privacy: .public) hadn't quit after 10 s; not reopening it")
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        var reopened = true
        for bundle in bundles {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
            } catch {
                reopened = false
                log.error("Couldn't reopen \(bundle.path, privacy: .public): \(error, privacy: .public)")
            }
        }
        if reopened { log.notice("Restarted \(id, privacy: .public)") }
        return reopened
    }
}
```

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -rn "unhide()" Sources | grep -v HiddenMenuBarApps.swift` → no output
- `grep -n "hides = true" Sources/YeeHaw/System/AppRestarter.swift` → no output

### Step 4: Wire it into the strip

In `Sources/YeeHaw/UI/StatusItemController.swift`:

4a. Add a stored property next to `revealProblem`:

```swift
    /// Which hidden apps' reveals opened nothing lately, for the strip's health notice.
    private var health = MenuBarHealth()
```

4b. In `select`'s outcome switch, replace `case .revealed, .nothingOpened:` and its body with:

```swift
            case .revealed:
                revealProblem = nil
                health.recordReveal(id, opened: true)
            case .nothingOpened:
                revealProblem = nil
                health.recordReveal(id, opened: false)
```

Keep every other case as plan 002 left it.

4c. In `currentNotice()`, pass the health issue:

```swift
    private func currentNotice() -> StripNotice? {
        let owners = controller.items.compactMap(\.bundleID) + controller.state.hidden
        let issue = health.issue(among: HiddenMenuBarApps.runningFacts(of: owners), own: OwnIconLocator.bundleID)
        return Self.notice(needsGrant: controller.state.needsGrant, problem: revealProblem, ownIconMissing: ownIconMissing,
                           health: issue, name: AppIdentity.name(of:))
    }
```

If plan 002 or 004 added other arguments to this call, keep them; only add `health:`.

4d. In `noticeAction(_:)`, add (replacing any temporary `break` from Step 2):

```swift
        case .unhide(let id):
            if HiddenMenuBarApps.unhide(id) { health.forget(id) }
        case .restart(let id):
            Task {
                if await AppRestarter.restart(id) { health.forget(id) }
            }
```

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -n "health.recordReveal" Sources/YeeHaw/UI/StatusItemController.swift | wc -l` → `2`
- `grep -n "health: issue" Sources/YeeHaw/UI/StatusItemController.swift` → one line
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output
- `swift test 2>&1 | tail -n 3` → passed, 9 more tests than the Step 0 baseline

### Step 5 (operator only, when asked): Live check

Skip unless the operator asks you to run the app. Then:
`scripts/build-app.sh --install`, `pkill -x YeeHaw; open ~/Applications/YeeHaw.app`.
Pick a menu-bar-only app that YeeHaw shows in the bar (one in `/Applications`). Hide it with
`osascript -e 'tell application "System Events" to set visible of process "<Name>" to false'`,
open the strip (click YeeHaw's icon), and confirm the notice reads "<Name> is hidden, so its icon
may open nothing." with an **Unhide** button. Click it, reopen the strip: no notice. Never do this
to an app with unsaved work, and don't try Restart on one.

## Test plan

`Tests/YeeHawCoreTests/MenuBarHealthTests.swift` (new, `@testable import YeeHawCore`, model on
`SpacingPlanTests.swift`). Helper:
`static func app(_ id: String, hidden: Bool = false, regular: Bool = false, path: String? = nil) -> RunningAppFacts`
returning `RunningAppFacts(bundleID: id, bundlePath: path ?? "/Applications/\(id).app", isHidden: hidden, isRegular: regular)`.
Use `own: "com.zapps.yeehaw"` and `home: "/Users/test"`.

1. `stuckOnlyAfterTwoMissesInARow`: `recordReveal("a", opened: false)` → `!isStuck("a")`; again →
   `isStuck("a")`; `recordReveal("a", opened: true)` → `!isStuck("a")`.
2. `anOpenedRevealBetweenMissesResets`: false, true, false → `!isStuck("a")`.
3. `forgettingStartsAfresh`: two misses, `forget("a")` → `!isStuck("a")`; one more miss → still not stuck.
4. `aHiddenMenuBarOnlyAppIsReported`: `issue(among: [app("a"), app("b", hidden: true)], …)` → `.hidden("b")`.
5. `aHiddenRegularAppAppleAppYeeHawOrStrayCopyIsNot`:
   `issue(among: [app("o", hidden: true, regular: true), app("com.apple.x", hidden: true), app("com.zapps.yeehaw", hidden: true), app("d", hidden: true, path: "/Users/test/dev/D.app")], …)` → `nil`.
6. `hiddenBeatsStuckAndStuckNeedsToBeRunning`: two misses for `"s"`;
   `issue(among: [app("s"), app("h", hidden: true)], …)` → `.hidden("h")`;
   `issue(among: [app("s")], …)` → `.stuck("s")`; `issue(among: [], …)` → `nil` (a stuck app that quit isn't named).

`Tests/YeeHawTests/StripTests.swift`, inside `StripNoticeTests`: extend the `notice` helper with a
`health: HealthIssue? = nil` parameter passed through to `StatusItemController.notice(...)`.

7. `aHiddenAppOffersUnhide`: `notice(health: .hidden("dig"))` ==
   `StripNotice(message: "DigUp is hidden, so its icon may open nothing.", action: .unhide("dig"))`,
   and `actionTitle == "Unhide"`.
8. `aStuckAppOffersRestart`: `notice(health: .stuck("dig"))` ==
   `StripNotice(message: "DigUp opened nothing the last two times.", action: .restart("dig"))`,
   and `actionTitle == "Restart"`.
9. `grantsAndClickProblemsComeBeforeHealthAndHealthBeforeTheOwnIcon`:
   `notice([.allowList], health: .hidden("dig"))?.action == .openSettings`;
   `notice([], .didNotAppear("dig"), health: .stuck("x"))?.action == .retry("dig")`;
   `notice(ownIconMissing: true, health: .stuck("dig"))?.action == .restart("dig")`.

Verification: `swift test 2>&1 | tail -n 3` → passed, 9 more tests than the baseline.

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, with 9 more tests than the Step 0 baseline
- [ ] `grep -rn "func unhideAll\|unhide()" Sources | grep -v HiddenMenuBarApps.swift` prints nothing
- [ ] `grep -rn "hides = true" Sources` prints nothing
- [ ] `grep -n "case unhide(BundleID)\|case restart(BundleID)" Sources/YeeHaw/UI/StripView.swift` prints two lines
- [ ] `git diff --stat build/yeehaw-v1 -- Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/System/SpacingApplier.swift` prints nothing
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 013 updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any Step 0 check fails: a dependency isn't DONE, or `RunningAppFacts`, `shouldUnhide`,
  `HiddenMenuBarApps`, `Outcome.nothingOpened` or `case .revealed, .nothingOpened:` isn't there.
  Don't recreate what another plan owns.
- `shouldUnhide`'s signature differs from the one quoted above, or it treats a regular app with
  empty `menuBarOwners` as unhideable.
- Counting `.nothingOpened` would need a change in `RevealCoordinator.swift`.
- `StatusItemController.notice(...)` has become something other than a pure static function, or
  `noticeAction` no longer switches on `StripNotice.Action`.
- An existing `StripNoticeTests` test needs a changed expectation.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Plan 006 (two copies of one bundle ID tracked by pid) may make "stuck" per copy. Until then,
  Restart quits every copy and reopens each distinct bundle, which also clears a stuck debug copy.
- If people want the check in Settings too, `MenuBarHealth.issue(among:own:)` is the single
  source; render the same `HealthIssue` there.
- The stuck threshold (`stuckAfter = 2`) is a guess. If an app whose icon is meant to open
  nothing (a toggle) gets flagged, consider counting only plain clicks, not right-clicks, or
  raising the threshold.
- Reviewers: confirm nothing calls `AppRestarter.restart` without a user click, and that
  `AppRestarter` never force-quits (`forceTerminate` must not appear:
  `grep -rn forceTerminate Sources` prints nothing).
