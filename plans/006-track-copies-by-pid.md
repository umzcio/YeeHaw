# Plan 006: With two running copies of one app, YeeHaw acts on the copy that owns the icon

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHawCore/ItemMatcher.swift Sources/YeeHawCore/PositionKey.swift Sources/YeeHaw/System/AXMenuBarReader.swift Sources/YeeHaw/System/RevealCoordinator.swift Sources/YeeHaw/System/RunningMenuBarApps.swift Sources/YeeHaw/System/SpacingApplier.swift Tests/YeeHawCoreTests/ItemMatcherTests.swift Tests/YeeHawCoreTests/PositionKeyTests.swift Tests/YeeHawCoreTests/MenuBarControllerTests.swift Tests/YeeHawTests/SpacingApplierTests.swift`
>
> Some changes are expected:
> - Plan 001 changes `SpacingApplier.swift`, `SpacingApplierTests.swift` and possibly `RunningMenuBarApps.swift`.
> - Plan 002 changes `RevealCoordinator.swift`.
> - Plan 003 doesn't touch these files.
>
> For those files, re-locate each excerpt below by its quoted text rather than its line number. For every other listed file, a change since 495d26f means the "Current state" excerpts must be re-checked against the live code. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/001-spacing-never-hides-apps.md`, `plans/002-reveal-never-switches-off-under-a-panel.md`
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. It reveals a hidden app's icon to press it, and it quits and reopens apps to apply a new icon spacing.

Two running copies of one bundle ID are common on a developer's Mac: a debug build run from a project folder beside the installed `/Applications` copy. On the day of this audit, two copies of one menu bar app were running at once. Every place YeeHaw picks "the app" by bundle ID takes `.first`:
- A reveal can press and watch the copy that doesn't own the drawn icon. The press finds no element, or the session watches the wrong process's windows.
- The per-app bar read used while revealing can miss the drawn copy's item entirely.
- Spacing can pick the wrong copy to restart, or treat the other copy's icon as "back".

The fix is to carry the owning process ID (pid) from the Accessibility read on every `MenuBarItem`, and use it wherever YeeHaw acts on one copy.

## Current state

### Background

- `MenuBarAgent` draws every status item. `AXMenuBarReader` reads what it draws (`DrawnItem`s: frames and labels). It then asks each running app for its own status items, the `AXExtrasMenuBar` children (`AppExtra`s), and matches them by exact x and width in `ItemMatcher.match`.
- The full read (`readItems`) already asks **every** running process, including both copies of one bundle ID. It just throws the pid away.
- The per-app read (`readBar(owning:)`, used while revealing and by spacing) asks only the **first** copy.

### Files

- `Sources/YeeHawCore/ItemMatcher.swift`: defines `AppExtra` (lines 14-37), `MenuBarItem` (lines 39-67) and `ItemMatcher.match` (lines 91-127).
- `Sources/YeeHawCore/PositionKey.swift`: `prefixes(bundleID:executableName:notarized:)` (lines 5-13).
- `Sources/YeeHawCore/Ports.swift` (read only): `RunningCopy` (lines 19-36) and the `MenuBarReading` protocol (lines 38-56).
- `Sources/YeeHaw/System/AXMenuBarReader.swift`: the live reader.
- `Sources/YeeHaw/System/RevealCoordinator.swift`: the reveal. It picks the pid to press and watch.
- `Sources/YeeHaw/System/RunningMenuBarApps.swift`: lists the apps that spacing can restart.
- `Sources/YeeHaw/System/SpacingApplier.swift`: restarts apps. Its `SpacingSystem` struct holds the injectable Mac operations.

### Excerpts at 495d26f

`ItemMatcher.swift:14-26` (AppExtra) and `39-54` (MenuBarItem):
```swift
public struct AppExtra: Equatable, Sendable {
    public var bundleID: BundleID
    public var indexInApp: Int
    public var x, width: Double
    public var identifier, title, description: String
    /// The owning app's executable name, a second key prefix for apps that aren't notarized.
    public var executableName: String
    /// Whether the owning copy is notarized: if not, its executable name is its first prefix.
    public var notarized: Bool

    public init(bundleID: BundleID, indexInApp: Int, x: Double, width: Double,
                identifier: String = "", title: String = "", description: String = "",
                executableName: String = "", notarized: Bool = true) {
...
public struct MenuBarItem: Equatable, Identifiable, Sendable {
    public var id: String            // "<bundleID>#<indexInApp>", appleIdentifier, or "unknown@<x>"
    public var bundleID: BundleID?   // nil for Apple items and items with unknown owner
    ...
    /// Another app, no more likely to be off, reports this frame too: the owner is a guess.
    public var contested: Bool

    public init(id: String, bundleID: BundleID?, appleIdentifier: String?, indexInApp: Int,
                label: String, keyNames: [String], keyPrefixes: [String],
                x: Double, width: Double, isPinned: Bool, contested: Bool = false) {
```

`ItemMatcher.swift:112-118`, the only construction from an `AppExtra`:
```swift
                items.append(MenuBarItem(
                    id: "\(e.bundleID)#\(e.indexInApp)", bundleID: e.bundleID, appleIdentifier: nil,
                    indexInApp: e.indexInApp, label: d.label,
                    keyNames: [e.identifier, e.title, e.description].filter { !$0.isEmpty },
                    keyPrefixes: PositionKey.prefixes(bundleID: e.bundleID, executableName: e.executableName,
                                                      notarized: e.notarized),
                    x: d.x, width: d.width, isPinned: false, contested: !rivals.isEmpty))
```

`AXMenuBarReader.swift:30-34`, `47-57` and `114-118`:
```swift
    func keyPrefixes(of id: BundleID) async -> [String] {
        let copy = await Self.copies(of: id).first
        return PositionKey.prefixes(bundleID: id, executableName: copy?.executableURL.lastPathComponent,
                                    notarized: copy?.notarized ?? true)
    }
...
    @concurrent
    private static func readBar(owning id: BundleID) async -> [MenuBarItem] {
        let apps = NSWorkspace.shared.runningApplications
        guard let agent = apps.first(where: { $0.bundleIdentifier == agentBundleID }),
              let owner = apps.first(where: { $0.bundleIdentifier == id }) else { return [] }
        let drawn = drawnItems(agentPID: agent.processIdentifier)
        let extras = appExtras(pid: owner.processIdentifier, bundleID: id,
                               executableName: owner.executableURL?.lastPathComponent ?? "",
                               notarized: Notarization.isNotarized(owner))
        return ItemMatcher.match(drawn: drawn, extras: extras)
    }
...
    private static func appExtras(pid: pid_t, bundleID: BundleID, executableName: String,
                                  notarized: @autoclosure () -> Bool) -> [AppExtra] {
        let app = AXUIElementCreateApplication(pid)
```
`appExtras` builds each `AppExtra(bundleID:indexInApp:x:width:identifier:title:description:executableName:notarized:)` at lines 125-130.

`RevealCoordinator.swift:115-120` at 495d26f. Plan 002 may have moved these lines; find them by text.
```swift
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.processIdentifier else {
            step("app is not running")
            await end(step)
            return .revealed
        }
        let session = RevealSession(pid: pid)
```
`item` here is the `MenuBarItem` returned by `controller.beginReveal(...)` (line 105). It comes from the per-app read, so once `readBar` carries pids, `item.pid` is the drawn copy's pid.

**After plan 002**, `RevealCoordinator.run` has a second lookup, the leftover-reveal check passed to `beginReveal`:
```swift
leftoverInUse: { leftover in RevealSession.anyWindowHangsFromBar(of: Set(NSRunningApplication.runningApplications(withBundleIdentifier: leftover).map(\.processIdentifier))) }
```
That one already takes **every** copy's pid, which is right: any copy's open panel counts. **Leave it unchanged.** Only the `.first?.processIdentifier` lookup that feeds `RevealSession(pid:)` and the press changes.

`RunningMenuBarApps.swift:24-27`:
```swift
        return SpacingPlan.appOrder(drawn: drawn.map(\.bundleID), hidden: hidden).compactMap { id in
            guard let app = running.first(where: { $0.bundleIdentifier == id && !$0.isTerminated
                      && $0.bundleURL?.pathExtension == "app" }),
                  let url = app.bundleURL else { return nil }
```
`instances(of:)` (lines 48-53) already narrows to the chosen copy's bundle path. Terminate, hide and window checks therefore act on the right copy once `list` picks it.

`SpacingApplier.swift:23-24` (protocol field), `252` (use) and `357-362` (live). Plan 001 may have edited the surrounding code; find these by text.
```swift
    /// Whether the reopened app's menu bar item is back.
    var isDrawn: (RunningMenuBarApp) async -> Bool
...
        let drawn = await poll(Self.drawPolls) { await self.system.isDrawn(app) }
...
            isDrawn: { app in
                if hidden().contains(app.bundleID) {
                    return RunningMenuBarApps.instances(of: app).contains { $0.isFinishedLaunching }
                }
                return await AXMenuBarReader().drawnBar(owning: app.bundleID).contains { $0.bundleID == app.bundleID }
            },
```
At 495d26f, `reopen` has the new pid at hand: `guard let pid = await system.open(app) else {` (line 248).

**After plan 001**, `SpacingApplier` looks like this:
- `SpacingSystem.open` is `var open: (RunningMenuBarApp, RelaunchOptions) async -> Int32?`.
- `reopen` no longer keeps the pid; its first line is `guard await system.open(app, .standard) != nil else {`.
- `hide`, `keepHidden`, `reopensHidden` and `hiddenAfterRestart` are gone.
- The live `open` closure starts `open: { app, options in` and sets `configuration.activates/hides/addsToRecentItems` from `options`.
- The fake's `open` is `open: { [self] app, options in ... }`.
- `isDrawn` is unchanged by 001.

The live `open` calls `NSWorkspace.shared.openApplication(at: URL(filePath: app.bundlePath), configuration:)`. When another copy with the same bundle ID is still running from a different folder, LaunchServices may hand back that running copy instead of starting this bundle.

`Tests/YeeHawTests/SpacingApplierTests.swift:80-85`, the fake:
```swift
            isDrawn: { [self] app in
                guard let left = drawing[app.bundleID] else { return false }
                if left <= 0 { return true }
                drawing[app.bundleID] = left - 1
                return false
            },
```
`open` in the fake hands out pids from 1001 up (`nextPID`, lines 33-34 and 72-78).

### Every `MenuBarItem(` construction (checked at 495d26f)

These need **no change**, because the new `pid` parameter defaults to `nil`. Re-run the grep in Step 1 to confirm that no new ones appeared.
- `Sources/YeeHawCore/ItemMatcher.swift`: lines 100, 112 and 120. Only 112 (from an `AppExtra`) gets `pid:`.
- `Sources/YeeHaw/UI/LayoutModel.swift:308`: a placeholder for an app that isn't drawn, so no pid.
- Tests: `IconImageProviderTests.swift:93,130`, `LayoutModelEditTests.swift:115`, `LayoutModelTests.swift:7`, `LayoutRulesTests.swift:11,16,21`, `LaunchRulesTests.swift:145`, `LayoutDraftTests.swift:6,13`, `MenuBarControllerTests.swift:50,56,450,660,703`, `PositionKeyTests.swift:82`, `GlyphProofTests.swift:7`, `ItemMatcherTests.swift:168`.

`AppExtra(` is constructed in `AXMenuBarReader.swift:125` (gets `pid:`) and in tests `GlyphProofTests.swift`, `RevealOwnershipTests.swift` and `ItemMatcherTests.swift` (no change).

### Conventions

- YeeHawCore is pure Swift with no AppKit: use `Int32`, not `pid_t`, there. In the YeeHaw target `pid_t` is `Int32`.
- New stored properties go last, and new init parameters go last with a default, so existing call sites compile unchanged.
- Tests use Swift Testing (`@Test`, `#expect`, `#require`). Pure helpers are `nonisolated static func` so tests can call them without the Mac. Examples: `RunningMenuBarApps.instances`, `StatusItemController.clickAction`.
- Doc comments (`///`) explain *why*, in plain sentences. The exemplar is `Sources/YeeHaw/System/RevealCoordinator.swift` (lines 10-27). Match it.
- Never put personal names or a signing identity in code, comments or commits. Never change the bundle ID or signing team.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build app and tests | `swift build --build-tests 2>&1 \| tail -3` | ends with `Build complete!` |
| Warnings (clean) | `swift package clean && swift build --build-tests 2>&1 \| grep -c "warning:"` | `0` |
| One suite | `swift test --filter <SuiteName> 2>&1 \| tail -3` | `Test run with N tests ... passed` |
| All tests | `swift test 2>&1 \| grep -E "Test run with\|failed"` | one `... passed` line, no `failed` |

`grep -c` prints `0` and exits 1 when nothing matches. That is the expected result. Don't build the app bundle or launch YeeHaw unless the operator asks.

## Scope

**In scope**:
- `Sources/YeeHawCore/ItemMatcher.swift`
- `Sources/YeeHawCore/PositionKey.swift`
- `Sources/YeeHaw/System/AXMenuBarReader.swift`
- `Sources/YeeHaw/System/RevealCoordinator.swift` (only the pid choice, plus one new static helper)
- `Sources/YeeHaw/System/RunningMenuBarApps.swift`
- `Sources/YeeHaw/System/SpacingApplier.swift` (only `isDrawn`, its call in `reopen`, and the live `open` closure's instance choice)
- `Tests/YeeHawCoreTests/ItemMatcherTests.swift`
- `Tests/YeeHawCoreTests/PositionKeyTests.swift`
- `Tests/YeeHawCoreTests/MenuBarControllerTests.swift` (one new test)
- `Tests/YeeHawTests/SpacingApplierTests.swift`
- `Tests/YeeHawTests/CopyTrackingTests.swift` (create)
- `plans/README.md` (this plan's row)

**Out of scope** (do NOT touch):
- **Item ids.** Two copies that both draw get the same id (`<bundleID>#0`), and `LayoutRules.deduplicated` shows one tile for them. Changing the id format would invalidate saved photos, layout drafts and position-key matching.
- **Hiding one copy only.** Allow-list switching is per bundle ID: `MenuBarController.runningLocations` already lists every copy's location, so both copies switch together. That is intended.
- **`RevealSession`'s close logic.** Plan 002 owns it; this plan only changes which pid is passed in.
- **`ItemMatcher`'s `rivals` / `contested` rule for two copies reporting one frame.** It needs a live repro first.
- **`MenuBarController.swift`.** It already receives pids through the items; no change is needed.
- **`SpacingApplier`'s hide/unhide behaviour.** Plan 001 owns it.

## Git workflow

- Check that 001 and 002 are `DONE`: `grep -E '^\| 00[12] ' plans/README.md` shows two rows with `DONE`. If not, STOP.
- `git switch -c advisor/006-track-copies-by-pid` from the commit that has both.
- Record `BASE=$(git rev-parse --short HEAD)`.
- One commit per step from Step 1 to Step 6. Use conventional commits, for example:
  - `feat: carry each menu bar item's owning process`
  - `fix: reveal presses the copy that draws the icon`
  - `fix: spacing restarts the copy that draws the icon`
- Every message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- Do NOT push or open a PR.

## Steps

### Step 0: Baseline

Run `swift test 2>&1 | grep -E "Test run with|failed"` and note the total N.

**Verify**: there is one `passed` line and no `failed`. If tests already fail, STOP.

### Step 1: `pid` on `AppExtra` and `MenuBarItem`; `match` carries it

In `ItemMatcher.swift`:
- `AppExtra`: add the property last, `/// The process that reported this item: with two copies of one app running, the one that draws it.` `public var pid: Int32?`. Add the init parameter `pid: Int32? = nil` last, and assign it.
- `MenuBarItem`: add the property last, `/// The process that owns the item, from the read that matched it; nil for Apple items, unknown owners and placeholders.` `public var pid: Int32?`. Add the init parameter `pid: Int32? = nil` last (after `contested`), and assign it.
- In `match`, the construction at lines 112-118 gets `, pid: e.pid` after `contested: !rivals.isEmpty`. The Apple (line 100) and unknown (line 120) constructions stay as they are.

Tests in `ItemMatcherTests.swift`, inside `ItemMatcherTests`, modelled on `matchesByXAndWidth` (lines 5-17):
1. `theOwningProcessIsCarried`: one extra with `pid: 501` matched gives `items[0].pid == 501`. An Apple drawn item (`DrawnItem(..., appleIdentifier: "com.apple.menuextra.wifi")`) gives `pid == nil`.
2. `twoCopiesOfOneAppKeepTheirOwnProcess`:
   - drawn: `[DrawnItem(x: 100, width: 20, label: "A"), DrawnItem(x: 130, width: 20, label: "B")]`;
   - extras: `AppExtra(bundleID: "com.example.swarm", indexInApp: 0, x: 100, width: 20, pid: 11)` and the same at `x: 130` with `pid: 22`;
   - expect `items.map(\.pid) == [11, 22]` and `items.map(\.id) == ["com.example.swarm#0", "com.example.swarm#0"]`. The second check documents that ids collide, which is out of scope.

**Verify**:
- `grep -rn "MenuBarItem(" Sources | wc -l` gives 4: the 3 in `ItemMatcher.swift` plus `LayoutModel.swift:308`. If there are more, inspect the new ones (see STOP conditions).
- `grep -rn "MenuBarItem(" Tests | wc -l` gave 18 at 495d26f. Plans 001-005 may have added test fixtures; those need no change.
- `swift test --filter ItemMatcherTests 2>&1 | tail -3` passes.
- Full suite gives N + 2.
- Commit.

### Step 2: Key prefixes from every running copy

`AXMenuBarReader.keyPrefixes(of:)` uses only the first copy's executable name. A reveal of an app whose drawn copy is the other one may then miss that copy's position keys.

In `PositionKey.swift`, add after `prefixes(bundleID:executableName:notarized:)`:
```swift
/// Every running copy's prefixes, first copy first, without repeats: two copies of one app (a
/// debug build beside the installed one) may file its items under different prefixes. Just the
/// bundle ID when no copy runs.
public static func prefixes(bundleID: BundleID, copies: [RunningCopy]) -> [String] {
    var result: [String] = []
    for copy in copies {
        for prefix in prefixes(bundleID: bundleID, executableName: copy.executableURL.lastPathComponent,
                               notarized: copy.notarized) where !result.contains(prefix) {
            result.append(prefix)
        }
    }
    return result.isEmpty ? [bundleID] : result
}
```
`PositionKey.swift` has no imports at 495d26f. Add `import Foundation` as its first line, because the helper reads `URL.lastPathComponent`. Add `import Foundation` to `Tests/YeeHawCoreTests/PositionKeyTests.swift` too, because the tests build `URL`s.

In `AXMenuBarReader.keyPrefixes(of:)`, replace the body with `PositionKey.prefixes(bundleID: id, copies: await Self.copies(of: id))`.

Tests in `PositionKeyTests.swift`, next to the existing `prefixes` test around lines 60-73:
3. `everyRunningCopysPrefixesAreKept`: copies are `RunningCopy(bundleID: "com.example.a", executableURL: URL(fileURLWithPath: "/Applications/A.app/Contents/MacOS/A"), notarized: true)` and `RunningCopy(bundleID: "com.example.a", executableURL: URL(fileURLWithPath: "/dev/A.app/Contents/MacOS/ADebug"), notarized: false)`. Expect `["com.example.a", "A", "ADebug"]`.
4. `noRunningCopyMeansTheBundleID`: `copies: []` gives `["com.example.a"]`.
5. `oneCopyMatchesTheSingleCopyRule`: for the notarized copy alone, the result equals `PositionKey.prefixes(bundleID: "com.example.a", executableName: "A", notarized: true)`.

**Verify**: `swift test --filter PositionKeyTests` passes, and the full suite gives N + 5. Commit.

### Step 3: The live reader records pids and reads every copy

In `AXMenuBarReader.swift`:
- `appExtras` already takes `pid`. Pass it on: `AppExtra(..., executableName: executableName, notarized: notarized, pid: pid)`.
- Rewrite `readBar(owning:)` so it asks every running copy of `id`:
  ```swift
  let owners = apps.filter { $0.bundleIdentifier == id && !$0.isTerminated }
  guard let agent = ..., !owners.isEmpty else { return [] }
  let drawn = drawnItems(agentPID: agent.processIdentifier)
  let extras = owners.flatMap { owner in
      appExtras(pid: owner.processIdentifier, bundleID: id,
                executableName: owner.executableURL?.lastPathComponent ?? "",
                notarized: Notarization.isNotarized(owner))
  }
  return ItemMatcher.match(drawn: drawn, extras: extras)
  ```
  Update its doc comment (lines 45-46): it reads "that app's extras, every running copy of it".
- `readItems` needs no change: it already reads every process.

This file talks to the live Mac and has no unit tests. Steps 1, 4, 5 and 6 test the pieces.

**Verify**:
- `swift build --build-tests 2>&1 | tail -3` → `Build complete!`.
- `grep -n "first(where: { \$0.bundleIdentifier == id })" Sources/YeeHaw/System/AXMenuBarReader.swift` → no output.
- `grep -c "pid: pid" Sources/YeeHaw/System/AXMenuBarReader.swift` → at least `1`.
- Commit.

### Step 4: The reveal presses and watches the copy that draws the icon

In `RevealCoordinator.swift`, add a helper to `RevealCoordinator`, near `perform` (in the `// MARK: Pressing` section):
```swift
/// The process to press and watch: the copy that owns the revealed item while it still runs,
/// since two copies of one app can run at once (a debug build beside the installed one) and
/// only the drawing copy's extras hold the item. Otherwise the first running copy, as before.
nonisolated static func pressTarget(for item: MenuBarItem, running: [pid_t]) -> pid_t? {
    if let pid = item.pid, running.contains(pid) { return pid }
    return running.first
}
```
Replace the pid lookup. Run `grep -n "runningApplications(withBundleIdentifier" Sources/YeeHaw/System/RevealCoordinator.swift`. After plan 002 it prints two lines:
- the one ending `.first?.processIdentifier else {`, which is the one to replace;
- the `leftoverInUse:` check, which you leave alone.

Replace the first with:
```swift
guard let pid = Self.pressTarget(for: item, running: NSRunningApplication.runningApplications(withBundleIdentifier: id).map(\.processIdentifier)) else {
```
Wrap the line the way the file wraps long lines. Leave the `else` body as it is.

Create `Tests/YeeHawTests/CopyTrackingTests.swift`:
```swift
import Testing
import YeeHawCore
@testable import YeeHaw

/// Two running copies of one app: YeeHaw acts on the one that draws the icon.
@Suite struct CopyTrackingTests {
    static func item(pid: Int32?) -> MenuBarItem {
        MenuBarItem(id: "com.example.swarm#0", bundleID: "com.example.swarm", appleIdentifier: nil, indexInApp: 0,
                    label: "", keyNames: [], keyPrefixes: [], x: 100, width: 20, isPinned: false, pid: pid)
    }
    ...
}
```
Tests:
6. `theRevealPressesTheCopyThatDrawsTheIcon`: `pressTarget(for: item(pid: 22), running: [11, 22]) == 22`.
7. `aCopyThatQuitFallsBackToTheFirstRunning`: `pressTarget(for: item(pid: 33), running: [11, 22]) == 11`.
8. `noPidFallsBackToTheFirstRunning`: `pressTarget(for: item(pid: nil), running: [11]) == 11`, and with `running: []` it is `nil`.

**Verify**: `swift test --filter CopyTrackingTests` → 3 tests pass, and the full suite gives N + 8. Commit.

### Step 5: Spacing lists the copy that draws the icon

In `RunningMenuBarApps.swift`:
- Add:
  ```swift
  /// The process that draws `id`'s first item in `drawn`, so with two copies running the one
  /// whose icon the user sees is the one restarted.
  nonisolated static func ownerPID(of id: BundleID, in drawn: [MenuBarItem]) -> Int32? {
      drawn.first { $0.bundleID == id && $0.pid != nil }?.pid
  }
  ```
- In `list`, replace the `running.first(where:)` choice with:
  ```swift
  let candidates = running.filter { $0.bundleIdentifier == id && !$0.isTerminated && $0.bundleURL?.pathExtension == "app" }
  let owner = ownerPID(of: id, in: drawn)
  guard let app = candidates.first(where: { $0.processIdentifier == owner }) ?? candidates.first,
        let url = app.bundleURL else { return nil }
  ```
  If plan 001 changed the rest of the closure (for example `isHidden`), keep its changes.

Tests in `CopyTrackingTests.swift`:
9. `spacingRestartsTheCopyThatDrawsTheIcon`: `ownerPID(of: "com.example.swarm", in: [item(pid: 22)]) == 22`.
10. `anAppThatDrawsNothingHasNoOwner`: `ownerPID(of: "com.example.other", in: [item(pid: 22)]) == nil`, and `ownerPID(of: "com.example.swarm", in: [item(pid: nil)]) == nil`.

**Verify**: `swift test --filter CopyTrackingTests` → 5 pass, and the full suite gives N + 10. Commit.

### Step 6: Spacing waits for the reopened copy's icon, and opens that copy

In `SpacingApplier.swift`:
1. Change the `SpacingSystem` field to:
   ```swift
   /// Whether the reopened process's menu bar item is back. The process ID matters when another
   /// copy of the app runs: its icon is drawn all along.
   var isDrawn: (RunningMenuBarApp, Int32) async -> Bool
   ```
2. In `reopen`, keep the reopened pid and pass it on:
   - plan 001 left `guard await system.open(app, .standard) != nil else {`; change it to `guard let pid = await system.open(app, .standard) else {`;
   - change the poll to `await self.system.isDrawn(app, pid)`.
3. In the live `isDrawn`:
   ```swift
   isDrawn: { app, pid in
       if hidden().contains(app.bundleID) {
           return RunningMenuBarApps.instances(of: app).contains { $0.processIdentifier == pid && $0.isFinishedLaunching }
       }
       return await AXMenuBarReader().drawnBar(owning: app.bundleID).contains { $0.bundleID == app.bundleID && $0.pid == pid }
   },
   ```
4. In the live `open`, before `openApplication`, start a new instance when another copy of the bundle ID runs from a different folder. Otherwise LaunchServices can hand back that copy instead of starting this one. Add a pure helper to `SpacingApplier`:
   ```swift
   /// Whether opening `bundlePath` needs a new instance: another copy of the app is running from a
   /// different folder, and LaunchServices would otherwise hand back that copy.
   nonisolated static func needsNewInstance(bundlePath: String, runningPaths: [String]) -> Bool {
       let path = (bundlePath as NSString).standardizingPath
       return runningPaths.contains { ($0 as NSString).standardizingPath != path }
   }
   ```
   In the live `open` closure (`open: { app, options in` after plan 001), next to the other `configuration.` lines:
   ```swift
   let others = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
       .filter { !$0.isTerminated }.compactMap { $0.bundleURL?.path }
   configuration.createsNewApplicationInstance = SpacingApplier.needsNewInstance(bundlePath: app.bundlePath, runningPaths: others)
   ```
   Keep every other line plan 001 left in `open`.

In `SpacingApplierTests.swift`:
- The fake: change to `isDrawn: { [self] app, pid in drawnChecks.append(pid); ... }`, keeping the existing body. Add `var drawnChecks: [Int32] = []` to `FakeSpacingMac`, with a `///` comment.
- 11. `drawnIsAskedAboutTheReopenedProcess`, modelled on `waitsUntilTheItemIsDrawnAgain` (lines 345-350): `mac.drawnAfterPolls = [Self.digUp.bundleID: 2]`, apply with `[Self.windowed]`, then `#expect(!mac.drawnChecks.isEmpty)` and `#expect(Set(mac.drawnChecks) == [1001])`.

In `CopyTrackingTests.swift`:
- 12. `anotherCopyElsewhereNeedsANewInstance`: `needsNewInstance(bundlePath: "/Applications/A.app", runningPaths: ["/Users/x/dev/A.app"])` is true; with `runningPaths: ["/Applications/A.app"]` or `[]` it is false.

**Verify**: `swift test --filter "SpacingApplierTests|CopyTrackingTests"` passes, and the full suite gives N + 12. Commit.

### Step 7: The reveal returns the drawn copy's pid (Core regression test)

In `MenuBarControllerTests.swift`, next to `revealUsesSlotLeftOfYeeHawAndRestores` (line 723), add:

13. `revealReturnsTheDrawnCopysProcess`:
    - Build a `FakeSystem` like `revealSystem()` (lines 262-272): same `allow` and `positions`.
    - Add `drawn: [Self.a: [copy]]`, where `var copy = FakeSystem.item(Self.a); copy.pid = 4242`.
    - `let drawn = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))`.
    - Expect `#expect(drawn.pid == 4242)`, then `try await c.endReveal()`.

This test needs no production change. It protects the path from the reader to `RevealCoordinator`.

**Verify**: `swift test --filter MenuBarControllerTests` passes, and the full suite gives N + 13. Commit: `test: a reveal hands back the drawn copy's process`.

### Step 8: Final checks

- `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` → `0`
- `swift test 2>&1 | grep -E "Test run with|failed"` → N + 13, passed.
- `git diff --stat $BASE..HEAD` → only in-scope files.
- `grep -rn "withBundleIdentifier: id).first" Sources` → no output.

Set row 006 in `plans/README.md` to `DONE`.

## Test plan

- `ItemMatcherTests`: 2 new (pid carried; two copies keep their pids).
- `PositionKeyTests`: 3 new (union, none running, single copy unchanged).
- `CopyTrackingTests` (new file): 6 tests: 3 for `pressTarget`, 2 for `ownerPID`, 1 for `needsNewInstance`.
- `SpacingApplierTests`: 1 new, plus the fake's new closure signature.
- `MenuBarControllerTests`: 1 new.
- Patterns:
  - `ItemMatcherTests.matchesByXAndWidth` for pure matching.
  - `SpacingApplierTests.waitsUntilTheItemIsDrawnAgain` for the fake Mac.
  - `revealUsesSlotLeftOfYeeHawAndRestores` for the controller.
- Verification: `swift test` → baseline + 13, all pass.

## Done criteria

- [ ] `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` prints `0`
- [ ] `swift test` passes with the Step 0 baseline + 13 tests
- [ ] `grep -n "public var pid: Int32?" Sources/YeeHawCore/ItemMatcher.swift` → 2 matches
- [ ] `grep -n "pressTarget" Sources/YeeHaw/System/RevealCoordinator.swift` → at least 2 matches (definition and use)
- [ ] `grep -n "ownerPID" Sources/YeeHaw/System/RunningMenuBarApps.swift` → at least 2 matches
- [ ] `grep -n "var isDrawn: (RunningMenuBarApp, Int32)" Sources/YeeHaw/System/SpacingApplier.swift` → 1 match
- [ ] `grep -rn "withBundleIdentifier: id).first" Sources` → no output
- [ ] `git diff --stat $BASE..HEAD` lists only in-scope files
- [ ] `plans/README.md` row 006 is `DONE`

## STOP conditions

Stop and report back (do not improvise) if:

- 001 or 002 is not `DONE`.
- `RevealCoordinator.swift`'s `runningApplications(withBundleIdentifier:` lookups are anything other than the two described in Step 4: the `.first?.processIdentifier` pid and the `leftoverInUse:` set. Likewise if the pid passed to `RevealSession(pid:)` no longer comes from the `.first` lookup. In either case the right place for `pressTarget` needs a human decision.
- Plan 001 removed or renamed `SpacingSystem.isDrawn` or `reopen`.
- `MenuBarItem` or `AppExtra` already has a `pid` property, or an init parameter named `pid`.
- Adding `pid` to `MenuBarItem` makes an existing test fail. Synthesized `Equatable` now includes `pid`, so this would mean a test compares items from two reads where a pid differs. Report the test; don't drop `pid` from equality without approval.
- `grep -rn "MenuBarItem(" Sources Tests` lists a site under `Sources/` that isn't in the "Every `MenuBarItem(` construction" list and builds an item from a live read. It may need a pid too. New test fixtures from plans 001-005 are fine.
- Any step needs a change to `MenuBarController.swift`, `LayoutRules.swift` or the item id format.

## Maintenance notes

- `pid` is part of `MenuBarItem`'s synthesized `Equatable`. Code comparing whole items across reads will see an app restart as a change. Today all bar comparisons go by `id` (`LayoutDraft.isDirty` compares `map(\.id)`).
- Item ids still collide when two copies both draw. Plan 010 adds a per-copy slot (`id`, `x`, `y`) for photos; that does not fix the Layout window showing one tile for both copies. Revisit only if both copies need separate tiles.
- `createsNewApplicationInstance` is set only when another copy runs from a different folder. Reviewers should confirm that a normal single-copy restart still sets it to `false`.
- A reveal still switches every copy of the bundle ID on and off together. That is how the Allow list works, and it is intended.
- Plan 013 (health check) can use `MenuBarItem.pid` to tell which copy is stuck.
