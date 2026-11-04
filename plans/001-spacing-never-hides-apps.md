# Plan 001: Spacing Apply reopens apps shown, never hidden, and apps it left hidden are shown again

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md` (if that file exists), unless a reviewer dispatched you
> and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/System/SpacingApplier.swift Sources/YeeHaw/System/RunningMenuBarApps.swift Sources/YeeHaw/UI/LayoutWindow.swift Sources/YeeHawCore/SpacingPlan.swift Sources/YeeHaw/App/YeeHawApp.swift Tests/YeeHawTests/SpacingApplierTests.swift Tests/YeeHawCoreTests/SpacingStateTests.swift Tests/YeeHawCoreTests/SpacingPlanTests.swift`
> Expected: no output. If any listed file changed since this plan was written,
> compare the "Current state" excerpts against the live code before
> proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. Its Spacing Apply changes the gap between menu bar
icons, then quits and reopens the apps the user ticked, because apps read the spacing only at
launch. Today it reopens almost every menu-bar-only app **hidden** (as Command-H hides an app) and
then calls `hide()` on it 11 more times. Nothing ever unhides it. A hidden app still receives its
menu bar icon's clicks, but it can't show the panel or popover the click opens. On the owner's Mac,
Fiddle (a SwiftUI `MenuBarExtra(.window)`), zStats (an AppKit popover panel) and SwarmBar stopped
opening their panels after one Apply and stayed broken until restarted by hand. The hidden flag
also feeds back into the next Apply, which reopens the app hidden again. After this plan,
YeeHaw never hides another app's process. A one-time pass at launch also unhides the apps an
earlier Apply left hidden, so users who were already affected recover without doing anything.

## Current state

### How the hiding happens

- `Sources/YeeHaw/System/SpacingApplier.swift` holds the Spacing Apply sequence. `SpacingApplier`
  talks to the Mac only through the injected `SpacingSystem` struct, which tests replace with a fake.
  - `SpacingSystem.open` (lines 20-22) and `SpacingSystem.hide` (lines 25-26):
    ```swift
    /// Opens the app again without bringing it to the front: its new process ID, or nil if it
    /// couldn't be opened.
    var open: (RunningMenuBarApp) async -> Int32?
    /// Whether the reopened app's menu bar item is back.
    var isDrawn: (RunningMenuBarApp) async -> Bool
    /// Hides the app, like Command-H, if it isn't hidden already.
    var hide: (RunningMenuBarApp) -> Void
    /// Whether the app has windows open right now; processes in the set (hidden by YeeHaw after
    /// a restart) count as windowless while they stay hidden.
    var hasOpenWindows: (RunningMenuBarApp, Set<Int32>) async -> Bool
    ```
  - Lines 78-79: `static let settlePolls = 10`, which sets how long `keepHidden` keeps hiding.
  - Lines 85-89: `hiddenAfterRestart: Set<Int32>` and `observers`.
  - Lines 101-103: `isolated deinit` that only removes those observers.
  - Lines 125-134:
    ```swift
    /// The user showed the app, or it quit: its windows count again.
    func forgetHidden(_ pid: Int32) {
        hiddenAfterRestart.remove(pid)
    }

    /// Whether `app` is reopened hidden: it was hidden before, or had no windows open (it comes
    /// back the way a login item does, without a window or the focus).
    static func reopensHidden(_ app: RunningMenuBarApp) -> Bool {
        app.isHidden || !app.hasOpenWindows
    }
    ```
    `!app.hasOpenWindows` is true for nearly every menu-bar-only app, so nearly every app is reopened hidden.
  - Line 234 (in `restart`): `if !app.hasOpenWindows, await system.hasOpenWindows(app, hiddenAfterRestart) {`
  - Lines 245-272 (`reopen` and `keepHidden`):
    ```swift
    guard let pid = await system.open(app) else {
        Self.log.error("Spacing: \(app.bundleID, privacy: .public) quit but didn't reopen")
        return nil
    }
    let drawn = await poll(Self.drawPolls) { await self.system.isDrawn(app) }
    let elapsed = ContinuousClock.now - started
    Self.log.notice("Spacing: restarted \(app.bundleID, privacy: .public); item drawn: \(drawn, privacy: .public) after \(elapsed, privacy: .public)")
    if Self.reopensHidden(app) {
        await keepHidden(app)
        if !app.hasOpenWindows { hiddenAfterRestart.insert(pid) }
    }
    return Restart(app: app, iconReturned: drawn)
    ...
    private func keepHidden(_ app: RunningMenuBarApp) async {
        for _ in 0..<Self.settlePolls {
            system.hide(app)
            await system.sleep(Self.pollInterval)
        }
        system.hide(app)
    }
    ```
  - Lines 289-301: `convenience init(hidden:)` registers `didUnhideApplicationNotification` and
    `didTerminateApplicationNotification` observers. Their only job is to call `forgetHidden`.
  - Lines 341-356 and 363-368 (in `SpacingSystem.live`):
    ```swift
    open: { app in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        // Launched hidden, like a login item, so one that opens its main window at
        // launch (DigUp does) doesn't put it on screen or take the focus.
        configuration.hides = SpacingApplier.reopensHidden(app)
        ...
    hide: { app in
        for instance in RunningMenuBarApps.instances(of: app) where !instance.isHidden && !instance.isTerminated {
            instance.hide()
        }
    },
    hasOpenWindows: { app, exempt in await RunningMenuBarApps.hasOpenWindows(app, exempt: exempt) },
    ```
- `Sources/YeeHaw/System/RunningMenuBarApps.swift` gathers the apps Apply lists, and passes the
  `exempt` set through:
  - Lines 16-19: `/// ... \`exempt\` holds processes YeeHaw hid after restarting them.` and
    `static func list(drawn: [MenuBarItem], hidden: [BundleID], exempt: Set<Int32>) async -> [RunningMenuBarApp] {`
  - Line 30: `let open = SpacingPlan.hasOpenWindows(facts, exempt: exempt)`
  - Line 34: `isHidden: app.isHidden, launchDate: app.launchDate)`. The hidden flag is recorded, and
    `reopensHidden` turns it into another hidden relaunch next time.
  - Lines 38-45: `static func hasOpenWindows(_ app: RunningMenuBarApp, exempt: Set<Int32>) async -> Bool`
    ending in `SpacingPlan.hasOpenWindows(facts(for: instance, windows: windows), exempt: exempt)`.
- `Sources/YeeHaw/UI/LayoutWindow.swift:125-126`:
  ```swift
  spacing.setApps(await RunningMenuBarApps.list(drawn: controller.items, hidden: controller.state.hidden,
                                               exempt: spacing.applier.hiddenAfterRestart))
  ```
- `Sources/YeeHawCore/SpacingPlan.swift` holds the pure logic (YeeHawCore target):
  - Lines 12-13: `/// Hidden with Command-H; it's reopened hidden too.` / `public var isHidden: Bool`
  - Lines 100-112:
    ```swift
    /// Whether restarting the app would interrupt open windows: whatever Accessibility lists
    /// (hidden and minimized windows too), anything on screen, and for a regular app, any window
    /// the window server knows of (it may be full screen in another Space, which Accessibility
    /// doesn't list; a false positive only leaves the app unticked). An accessory app's off-screen
    /// windows don't count: menu bar apps keep closed windows around. `exempt` holds processes
    /// YeeHaw hid itself after restarting them (some open their main window at launch); they
    /// count as windowless while they stay hidden.
    public static func hasOpenWindows(_ facts: WindowFacts, exempt: Set<Int32> = []) -> Bool {
        if facts.isHidden, exempt.contains(facts.pid) { return false }
        if let ax = facts.axWindows, ax > 0 { return true }
        if facts.onScreenWindows > 0 { return true }
        return facts.isRegular && facts.windowsAnywhere > 0
    }
    ```
  - Lines 53-73: `candidates(_:own:home:)` and `isInApplicationsFolder(_:home:)` (internal). Apply
    restarts only apps whose bundle ID doesn't start with `com.apple.`, that aren't YeeHaw, and
    that live under `/Applications` or `~/Applications`. So those are the only apps Spacing ever hid.
- `Sources/YeeHaw/App/YeeHawApp.swift:56-58`, in `applicationDidFinishLaunching`, after the launch
  checks pass:
  ```swift
  Self.log.notice("YeeHaw started")
  quitOnTerminationSignal()
  watchForThaw()
  ```
- DigUp (`/Applications/DigUp.app`, one of the affected apps) has `LSUIElement = true`, so it is an
  accessory app (`activationPolicy == .accessory`). All five affected apps are menu-bar-only apps.

### Tests that pin the old behaviour

- `Tests/YeeHawTests/SpacingApplierTests.swift` defines `FakeSpacingMac` (lines 8-97). Its `system`
  property builds a `SpacingSystem` from closures that append to `events` and `sleeps`. This
  injected struct is how SpacingApplier is tested. Relevant lines:
  - 72-79: `open: { [self] app in events.append("open \(app.name)") ... return nextPID }`
  - 86-88: `hide: { [self] app in if events.last != "hide \(app.name)" { events.append("hide \(app.name)") } },`
  - 89: `hasOpenWindows: { [self] app, _ in windowsNow.contains(app.bundleID) },`
  - Tests that expect `"hide …"` events or the settle wait: line 140, line 228, lines 244-245,
    line 357 (`+ SpacingApplier.pollInterval * SpacingApplier.settlePolls`), and the three tests
    at lines 363-398 (`windowlessAppIsKeptHiddenWhileItSettlesAndIsExempt`,
    `appWithWindowsIsNotHidden`, `hiddenAppWithWindowsComesBackHidden`).
- `Tests/YeeHawCoreTests/SpacingStateTests.swift:169-176`:
  `appYeeHawHidDuringItsRestartIsWindowlessWhileStillHidden` tests the `exempt` parameter.
- `Tests/YeeHawCoreTests/SpacingPlanTests.swift` (75 lines) is the pattern for new pure tests: a
  `@Suite struct SpacingPlanTests` with `static let home = "/Users/x"` and an `app(_:path:...)` helper.
- `Tests/YeeHawTests/SpacingModelTests.swift` and `LayoutModelEditTests.swift` also use
  `FakeSpacingMac`, but assert no `hide` events or sleeps. They need no edits.

### Conventions

- Swift 6, SwiftPM, two targets: `YeeHawCore` (pure logic) and `YeeHaw` (the app). Tests use Swift
  Testing (`import Testing`, `@Test`, `#expect`).
- Doc comments (`///`) explain **why**, in plain sentences. Match
  `Sources/YeeHaw/System/RevealCoordinator.swift` (e.g. its lines 10-20). Text shown to the user
  uses curly apostrophes (’); log strings use a plain `'`.
- Logging: `Logger(subsystem: Log.subsystem, category: "spacing")`, `privacy: .public` on interpolations.
- Never put personal names or the signing identity name in code, comments or commits. Never change
  the bundle ID `com.zapps.yeehaw` or signing team.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| One suite | `swift test --filter SpacingApplierTests 2>&1 \| tail -n 3` | last lines say the run **passed** |
| All tests | `swift test 2>&1 \| tail -n 3` | `Test run with <N> tests … passed`; N given per step |
| Warnings | `swift test 2>&1 \| grep -c "warning:"` | `0` |
| Logs (manual check only) | `/usr/bin/log show --last 5m --predicate 'subsystem == "com.zapps.yeehaw"' --info --style compact` | lines from category `spacing` |

Before you change anything, `swift test` passes 448 tests (269 YeeHawCore + 179 YeeHaw), 0 warnings.

## Scope

**In scope** (the only files you should modify or create):
- `Sources/YeeHaw/System/SpacingApplier.swift`
- `Sources/YeeHaw/System/RunningMenuBarApps.swift`
- `Sources/YeeHaw/UI/LayoutWindow.swift` (lines 125-126 only)
- `Sources/YeeHawCore/SpacingPlan.swift`
- `Sources/YeeHaw/System/HiddenMenuBarApps.swift` (create)
- `Sources/YeeHaw/App/YeeHawApp.swift` (add one launch line only)
- `Tests/YeeHawTests/SpacingApplierTests.swift`
- `Tests/YeeHawCoreTests/SpacingStateTests.swift` (delete one test only)
- `Tests/YeeHawCoreTests/SpacingPlanTests.swift`
- `plans/README.md` (status row only, if it exists)

**Out of scope** (do NOT touch):
- `WindowFacts.pid` in `Sources/YeeHawCore/SpacingState.swift`. It becomes unused by
  `hasOpenWindows` but stays. Removing it ripples into many tests for no behaviour change.
- `RunningMenuBarApp.isHidden` itself. Keep the field and only update its doc comment. Tests and
  logs still use it.
- Any "restore" menu item, `--restore` flag or signal handling. That is plan 004, which reuses the
  helper you add here.
- Any health check UI for stuck apps (a later direction item).
- `Sources/YeeHaw/UI/SpacingModel.swift`, `SpacingSection.swift`: the UI wording doesn't change.

## Git workflow

- Branch from `build/yeehaw-v1`: `git switch -c advisor/001-spacing-never-hides-apps`
- Two commits, conventional-commit style as in `git log` (e.g. `fix: keep a revealed icon while its
  popover hangs from the bar`). Every message ends with a blank line and then
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Do NOT commit the `plans/` folder unless the operator says so. Do NOT push or open a PR.

## Steps

### Step 1: Stop Spacing Apply hiding apps, and remove the "YeeHaw hid it" bookkeeping

**1a. `Sources/YeeHaw/System/SpacingApplier.swift`, the `SpacingSystem` struct (lines 5-31).**
- Delete `hide` (lines 25-26).
- Change `open` to take the options:
  ```swift
  /// Opens the app again with `options`: its new process ID, or nil if it couldn't be opened.
  var open: (RunningMenuBarApp, RelaunchOptions) async -> Int32?
  ```
- Change `hasOpenWindows` to drop the set:
  ```swift
  /// Whether the app has windows open right now.
  var hasOpenWindows: (RunningMenuBarApp) async -> Bool
  ```
- Directly below the `SpacingSystem` struct (above the `SpacingApplier` doc comment), add a
  top-level type. Keep it top-level, not nested in the `@MainActor` class, so it stays nonisolated:
  ```swift
  /// How Spacing Apply opens an app it restarted. Never hidden: a hidden app still gets its menu
  /// bar item's clicks but can't show the panel or popover they open (SwiftUI `MenuBarExtra` apps
  /// and AppKit popover panels both stop working), and nothing would ever show it again. Never
  /// brought to the front either. An app that opens a window at launch (DigUp does) may show it;
  /// that window is the app's own, and the user closes it like any other.
  struct RelaunchOptions: Equatable, Sendable {
      var activates: Bool
      var hides: Bool
      var addsToRecentItems: Bool

      static let standard = RelaunchOptions(activates: false, hides: false, addsToRecentItems: false)
  }
  ```

**1b. Same file, the `SpacingApplier` class.**
- Class doc comment (lines 33-35): append the sentence `It never hides an app it reopens
  (\`RelaunchOptions\`).` after "…skipped and left alone."
- Delete `settlePolls` and its comment (lines 78-79).
- Delete `hiddenAfterRestart` with its comment (lines 85-88) and `observers` (line 89).
- Delete the `isolated deinit { … }` block (lines 101-103).
- Delete `forgetHidden` (lines 125-128) and `reopensHidden` (lines 130-134), with their comments.
- In `restart` (line 234) change the call to `await system.hasOpenWindows(app)`.
- In `reopen` (lines 245-260): replace `guard let pid = await system.open(app) else {` with
  `guard await system.open(app, .standard) != nil else {`, and delete the whole
  `if Self.reopensHidden(app) { … }` block (lines 255-258). The function ends with the log line
  and `return Restart(app: app, iconReturned: drawn)`.
- Delete `keepHidden` with its doc comment (lines 262-272).
- In `convenience init(hidden:)` (lines 289-301) delete the `let center = …` line and the whole
  `for name in [...] { observers.append(...) }` loop. Keep the `self.init(system:)` call and the two
  `Self.live` lines.

**1c. Same file, `SpacingSystem.live`.**
- `open:` becomes:
  ```swift
  open: { app, options in
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = options.activates
      configuration.hides = options.hides
      configuration.addsToRecentItems = options.addsToRecentItems
      do {
          let running = try await NSWorkspace.shared.openApplication(at: URL(filePath: app.bundlePath),
                                                                     configuration: configuration)
          return running.processIdentifier
      } catch {
          SpacingApplier.log.error("Couldn't open \(app.bundlePath, privacy: .public): \(error, privacy: .public)")
          return nil
      }
  },
  ```
  The old "Launched hidden, like a login item…" comment goes away.
- Delete the `hide:` closure (lines 363-367).
- `hasOpenWindows:` becomes `hasOpenWindows: { app in await RunningMenuBarApps.hasOpenWindows(app) },`

**1d. `Sources/YeeHaw/System/RunningMenuBarApps.swift`.**
- Lines 16-19: remove the sentence `` `exempt` holds processes YeeHaw hid after restarting them.``
  and the `exempt: Set<Int32>` parameter, giving
  `static func list(drawn: [MenuBarItem], hidden: [BundleID]) async -> [RunningMenuBarApp] {`.
- Line 30: `let open = SpacingPlan.hasOpenWindows(facts)`.
- Lines 39-44: `static func hasOpenWindows(_ app: RunningMenuBarApp) async -> Bool`, calling
  `SpacingPlan.hasOpenWindows(facts(for: instance, windows: windows))`.

**1e. `Sources/YeeHaw/UI/LayoutWindow.swift:125-126`** becomes one call without `exempt:`:
```swift
spacing.setApps(await RunningMenuBarApps.list(drawn: controller.items, hidden: controller.state.hidden))
```

**1f. `Sources/YeeHawCore/SpacingPlan.swift`.**
- Line 12 doc comment becomes:
  `/// Hidden (Command-H) when the list was read. Apply never reopens an app hidden.`
- `hasOpenWindows` (lines 100-112): delete the last sentence of the doc comment (from
  `` `exempt` holds processes`` to `while they stay hidden.`), so it ends at `menu bar apps keep
  closed windows around.`. Change the signature to
  `public static func hasOpenWindows(_ facts: WindowFacts) -> Bool {` and delete line 108
  (`if facts.isHidden, exempt.contains(facts.pid) { return false }`).

**1g. Tests.**
- `Tests/YeeHawCoreTests/SpacingStateTests.swift`: delete the test
  `appYeeHawHidDuringItsRestartIsWindowlessWhileStillHidden` (lines 169-176, plus the blank line after it).
- `Tests/YeeHawTests/SpacingApplierTests.swift`, `FakeSpacingMac`:
  - Add a property under `sleeps`:
    ```swift
    /// The options each reopen asked for, in order.
    var openOptions: [RelaunchOptions] = []
    ```
  - `open:` becomes `open: { [self] app, options in` and appends `openOptions.append(options)`
    right after `events.append("open \(app.name)")`. The rest stays.
  - Delete the `hide:` closure (lines 86-88).
  - `hasOpenWindows:` becomes `hasOpenWindows: { [self] app in windowsNow.contains(app.bundleID) },`
- Same file, update existing expectations:
  - Line 140: `#expect(mac.events.dropFirst(2) == ["terminate DigUp", "open DigUp"])`
  - Line 228: same change, `["terminate DigUp", "open DigUp"]`.
  - Lines 244-245: `== ["terminate DigUp", "open DigUp", "terminate Other", "open Other"])`
  - Line 356 comment becomes `// Ten seconds for DigUp's item; Other needs no wait.` Line 357 becomes
    `#expect(mac.sleeps.reduce(.zero, +) == .seconds(10))`.
  - `appWithWindowsIsNotHidden` (lines 377-384): delete the line
    `#expect(applier.hiddenAfterRestart.isEmpty)`.
  - Delete `windowlessAppIsKeptHiddenWhileItSettlesAndIsExempt` (lines 363-375) and
    `hiddenAppWithWindowsComesBackHidden` (lines 386-398). Add the new tests listed in the Test plan
    (Step 1 group) in the `// MARK: After the restart` section.

**Verify**:
- `grep -rnE "hiddenAfterRestart|forgetHidden|reopensHidden|keepHidden|settlePolls|exempt|\.hide\(\)|var hide:|system\.hide|hide: \{ \[self\] app" Sources Tests` → no output
- `grep -rn "configuration.hides" Sources` → exactly one line: `configuration.hides = options.hides`
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter "SpacingApplierTests|SpacingStateTests|SpacingModelTests|LayoutModelEditTests" 2>&1 | tail -n 3` → passed
- `swift test 2>&1 | tail -n 3` → passed, `Test run with 448 tests` (−1 Core test, −2 + 3 YeeHaw tests = 448)

Commit: `fix: reopen apps Spacing Apply restarts shown, never hidden`

### Step 2: Unhide, once, the apps an earlier Apply left hidden

**2a. `Sources/YeeHawCore/SpacingPlan.swift`.** Add after the `RelaunchCandidate` struct (after line 37):
```swift
/// What the unhide pass needs to know about one running app.
public struct RunningAppFacts: Equatable, Sendable {
    public var bundleID: BundleID
    /// The app bundle's path, e.g. `/Applications/DigUp.app`.
    public var bundlePath: String
    /// Hidden, like Command-H.
    public var isHidden: Bool
    /// A regular app, with a Dock icon (not a menu-bar-only accessory app).
    public var isRegular: Bool

    public init(bundleID: BundleID, bundlePath: String, isHidden: Bool, isRegular: Bool) {
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.isHidden = isHidden
        self.isRegular = isRegular
    }
}
```
and, inside the second `extension SpacingPlan` (after `appOrder`, before its closing brace):
```swift
/// Whether a hidden app should be shown again because YeeHaw may be why it's hidden: earlier
/// versions reopened the apps Spacing Apply restarted hidden and never showed them, and a hidden
/// app can't open the panel or popover its menu bar item shows. Only apps Apply could have
/// restarted count (not Apple's, not YeeHaw, inside an Applications folder). A menu-bar-only app
/// counts whenever it's hidden, since people don't hide those themselves; a regular app only
/// when it owns a menu bar item (`menuBarOwners`), so an ordinary app someone hid stays hidden.
public static func shouldUnhide(_ app: RunningAppFacts, menuBarOwners: Set<BundleID>, own: BundleID,
                                home: String = NSHomeDirectory()) -> Bool {
    guard app.isHidden, !app.bundleID.hasPrefix("com.apple."), app.bundleID != own,
          isInApplicationsFolder(app.bundlePath, home: home) else { return false }
    return !app.isRegular || menuBarOwners.contains(app.bundleID)
}
```

**2b. Create `Sources/YeeHaw/System/HiddenMenuBarApps.swift`.** Plan 004 reuses `unhideAll`, so
keep its name and signature exactly:
```swift
import AppKit
import os
import YeeHawCore

/// Shows menu bar apps that may be hidden because of YeeHaw. Earlier versions of Spacing Apply
/// reopened the apps they restarted hidden and never showed them again; such an app still gets its
/// menu bar item's clicks but can't open the panel or popover they show. Unhiding also brings back
/// any window the app opened while hidden, which is the app's own.
@MainActor
enum HiddenMenuBarApps {
    private static let log = Logger(subsystem: Log.subsystem, category: "spacing")
    /// Set once the launch pass has run, so an app someone hides on purpose later stays hidden.
    static let unhidOnceKey = "UnhidAppsLeftHiddenBySpacing"

    /// Unhides every running app `SpacingPlan.shouldUnhide` picks, without activating it.
    /// `menuBarOwners` are the apps known to own a menu bar item. Returns the names of the apps
    /// it unhid.
    @discardableResult
    static func unhideAll(menuBarOwners: Set<BundleID>, own: BundleID = OwnIconLocator.bundleID) -> [String] {
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.isHidden && !app.isTerminated {
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { continue }
            let facts = RunningAppFacts(bundleID: id, bundlePath: url.path, isHidden: true,
                                        isRegular: app.activationPolicy == .regular)
            guard SpacingPlan.shouldUnhide(facts, menuBarOwners: menuBarOwners, own: own) else { continue }
            if app.unhide() {
                names.append(app.localizedName ?? id)
            } else {
                log.error("Couldn't unhide \(id, privacy: .public)")
            }
        }
        if !names.isEmpty {
            log.notice("Unhid \(names.joined(separator: ", "), privacy: .public)")
        }
        return names
    }

    /// The launch pass, run once per Mac user: apps an earlier Spacing Apply left hidden are shown,
    /// so nobody has to find and restart them by hand.
    static func unhideOnce(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: unhidOnceKey) else { return }
        let owners = Set(await AXMenuBarReader().items().compactMap(\.bundleID))
        unhideAll(menuBarOwners: owners)
        defaults.set(true, forKey: unhidOnceKey)
    }
}
```
(`AXMenuBarReader().items()` is in `Sources/YeeHaw/System/AXMenuBarReader.swift:14`. It returns
`[MenuBarItem]`, and `MenuBarItem.bundleID` is `BundleID?`. Without Accessibility it returns an
empty list, so only menu-bar-only apps are unhidden. That's fine.)

**2c. `Sources/YeeHaw/App/YeeHawApp.swift`.** After `watchForThaw()` (line 58) add:
```swift
        // Earlier Spacing Applies left the apps they restarted hidden; show them again, once.
        Task { await HiddenMenuBarApps.unhideOnce() }
```
Don't put it anywhere earlier. It must stay after the launch checks, so a refused launch or a
debug command never runs it.

**2d. Tests.** Add the Step 2 tests from the Test plan to `Tests/YeeHawCoreTests/SpacingPlanTests.swift`.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter SpacingPlanTests 2>&1 | tail -n 3` → passed
- `swift test 2>&1 | tail -n 3` → passed, `Test run with 452 tests`
- `grep -n "unhideOnce" Sources/YeeHaw/App/YeeHawApp.swift` → exactly one line, after the `watchForThaw()` line

Commit: `fix: show menu bar apps an earlier Spacing Apply left hidden, once`

## Test plan

Pattern: the existing tests in `Tests/YeeHawTests/SpacingApplierTests.swift` (e.g.
`restartsOneAtATimeInOrder`, lines 240-247) and `Tests/YeeHawCoreTests/SpacingPlanTests.swift`
(e.g. `excludesSelf`).

**Step 1, in `SpacingApplierTests` (`// MARK: After the restart`), through `FakeSpacingMac`:**
1. `everyReopenIsShownAndLeftInTheBackground`: apply `8` to
   `[Self.windowed (made hidden), Self.other (made hidden)]` (build hidden copies with
   `var x = Self.windowed; x.isHidden = true`). Expect
   `mac.openOptions == [.standard, .standard]` and
   `RelaunchOptions.standard == RelaunchOptions(activates: false, hides: false, addsToRecentItems: false)`.
2. `noAppIsHiddenAfterItsRestart`: same two hidden apps. Expect
   `mac.events.dropFirst(2) == ["terminate DigUp", "open DigUp", "terminate Other", "open Other"]`,
   `!mac.events.contains { $0.hasPrefix("hide") }`, and `mac.sleeps.isEmpty` (no settle wait; the
   fake draws items at once).
3. `windowlessAppNeedsNoSettleWait`: apply `8` to `[Self.digUp]`. Expect `mac.events.last == "open DigUp"`
   and `mac.sleeps.isEmpty`.

`SpacingSystem` no longer has a `hide` member, so a hide call can't be written without changing the
struct. Test 2 pins that the call sequence is exactly quit then open.

**Step 2, in `SpacingPlanTests`** (use `RunningAppFacts(bundleID:bundlePath:isHidden:isRegular:)`,
`own: "com.zapps.yeehaw"`, `home: Self.home`):
1. `hiddenMenuBarOnlyAppIsUnhidden`: accessory (`isRegular: false`), hidden, `/Applications/DigUp.app`
   → `true` with `menuBarOwners: []`. The same app with `isHidden: false` → `false`.
2. `hiddenRegularAppIsUnhiddenOnlyWithAMenuBarItem`: regular, hidden, `/Applications/Outlook.app`,
   id `com.microsoft.Outlook` → `false` with `[]`, `true` with `["com.microsoft.Outlook"]`.
3. `appsApplyNeverRestartsStayAsTheyAre`: hidden accessory apps at
   `/System/Library/CoreServices/Spotlight.app` (`com.apple.Spotlight`),
   `/Users/x/Downloads/D.app` (`com.example.dl`) and `/Users/x/Applications/YeeHaw.app`
   (`com.zapps.yeehaw`) → all `false`.
4. `userApplicationsFolderCounts`: hidden accessory app at `/Users/x/Applications/C.app` → `true`.

Final: `swift test` → `Test run with 452 tests … passed`, 0 warnings.

## Done criteria

- [ ] `swift build 2>&1 | grep -E "warning:|error:"` prints nothing
- [ ] `swift test 2>&1 | tail -n 3` shows the run passed with 452 tests; `swift test 2>&1 | grep -c "warning:"` prints `0`
- [ ] `grep -rnE "hiddenAfterRestart|forgetHidden|reopensHidden|keepHidden|settlePolls|exempt|\.hide\(\)|var hide:|system\.hide|hide: \{ \[self\] app" Sources Tests` prints nothing
- [ ] `grep -rn "configuration.hides" Sources` prints only `configuration.hides = options.hides`
- [ ] `grep -n "static func unhideAll(menuBarOwners: Set<BundleID>" Sources/YeeHaw/System/HiddenMenuBarApps.swift` prints one line (plan 004 depends on it)
- [ ] `git status --short` lists only files from the Scope section (and the untracked `plans/` folder)
- [ ] `git log --oneline build/yeehaw-v1..HEAD` shows the two commits, each message ending with the `Co-Authored-By` line
- [ ] `plans/README.md` status row updated (if the file exists)

Optional, only if the operator asks for a live check: `scripts/build-app.sh --install`, then
`pkill -x YeeHaw; open ~/Applications/YeeHaw.app`. Run a Spacing Apply that restarts a
menu-bar-only app, then `osascript -e 'tell application "System Events" to get visible of process "DigUp"'`
→ `true`, and its icon's panel opens on click.

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift).
- Anything besides the files above reads `hiddenAfterRestart`, `forgetHidden`, `reopensHidden`,
  `SpacingSystem.hide` or the `exempt:` argument (check with the grep in Step 1's Verify **before**
  editing). The plan assumes the only users are the ones listed.
- The compiler rejects `RelaunchOptions` or the `open` closure for actor isolation or Sendable
  reasons, and the fix would need `@preconcurrency`, `nonisolated(unsafe)` or `@unchecked Sendable`.
- Removing the `isolated deinit` leaves a warning or error you can't clear by deleting only the
  observer code listed in 1b.
- Any test outside the ones named here fails after Step 1 (e.g. a `SpacingModelTests` test).
  That means another test depended on the hide or settle behaviour. Report which one.
- A verification fails twice after a reasonable fix attempt.
- The work appears to need changes in an out-of-scope file.

## Maintenance notes

- Behaviour change on purpose (owner's direction: "Don't hide other apps' processes at all"). An
  app that opens its main window at launch (DigUp) now shows that window after a Spacing Apply.
  It isn't activated by YeeHaw, but it may take focus itself. A regular app the user had hidden
  with Command-H also comes back visible after its restart. Such apps start unticked anyway,
  because they have windows open.
- Because nothing is exempt any more, an app whose launch window is still open counts as "has
  windows open" at the next Apply and starts unticked. That's the conservative side.
- `unhideOnce` runs once per UserDefaults domain. An unbundled debug build has its own domain, so
  it runs the pass once too. Reviewers: check that it can't run before the launch checks, and
  that `unhideAll` never touches Apple apps or YeeHaw.
- Plan 004 ("Restore everything") calls `HiddenMenuBarApps.unhideAll(menuBarOwners:)` again on
  demand. Keep the signature stable.
- Deferred: an ongoing health check that notices hidden or stuck menu bar apps and offers Unhide or
  Restart (direction item D3). `WindowFacts.pid` is now unused by `hasOpenWindows`; remove it in a
  tidy-up if nothing else needs it.
