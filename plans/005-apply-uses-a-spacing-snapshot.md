# Plan 005: Layout Apply applies the spacing change it showed, and never drops or hides its outcome

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/UI/SpacingModel.swift Sources/YeeHaw/UI/LayoutModel.swift Sources/YeeHaw/UI/LayoutWindow.swift Tests/YeeHawTests/SpacingModelTests.swift Tests/YeeHawTests/LayoutModelEditTests.swift`
> Expected: only `LayoutWindow.swift` (and possibly `SpacingModelTests.swift` /
> `LayoutModelEditTests.swift`) changed, by plan 001. Plan 001 removes the
> `exempt:` argument at `LayoutWindow.swift:125-126`; that change is expected.
> For any other change, compare the "Current state" excerpts below against the
> live code before proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: `plans/001-spacing-never-hides-apps.md` (both touch spacing; 001 edits `LayoutWindow.swift:125-126`)
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. Its Layout window holds a draft: icon moves and hides,
plus a spacing change (a new gap between icons, applied by quitting and reopening the apps ticked
in a list). One Apply button writes the layout edits first, waits up to 5 s for macOS to show them,
and only then runs the spacing part. During that wait the spacing section is still "live": the
window's background re-read can move the slider value and auto-tick newly listed apps, and closing
the window resets the spacing draft. So Apply can restart apps the footer never named, or silently
drop the spacing change the user asked for. The close sheet's Apply also closes the window as soon
as the layout part succeeded, hiding a spacing warning such as "quit but didn't reopen", and a
failed save throws away the user's ticks. After this plan, Apply applies exactly the spacing value
and app list that were on screen when it was clicked, and its outcome stays visible.

## Current state

Files involved:

- `Sources/YeeHaw/UI/SpacingModel.swift`: the spacing section's state (`SpacingModel`), its draft
  (`value`, `candidates`, `userTicks`) and `apply()`.
- `Sources/YeeHaw/UI/LayoutModel.swift`: the Layout window's state; `apply()` runs the layout edits,
  then the spacing part.
- `Sources/YeeHaw/UI/LayoutWindow.swift`: the window controller; its refresh task re-reads the
  running apps, and its close sheet offers Apply / Don't Apply / Cancel.
- `Tests/YeeHawTests/SpacingModelTests.swift`, `Tests/YeeHawTests/LayoutModelEditTests.swift`: tests.

`SpacingModel.swift` today (495d26f):

```swift
// SpacingModel.swift:113
    @ObservationIgnored private var userTicks: [BundleID: Bool] = [:]
// :124-128
    var isApplying: Bool { progress != nil }
    /// Whether Apply stores something: a new value, or tidy keys for the current one. Otherwise it
    /// only restarts apps still drawing an older spacing.
    var isWriting: Bool { value != current || needsCleanup }
    var canApply: Bool { !isApplying && (isWriting || tickedCount > 0) }
```

Every draft mutator returns early while `isApplying` is true, e.g.:

```swift
// SpacingModel.swift:161-164
    /// Takes a fresh list of running apps that own an item. Ignored while Apply runs: apps quit
    /// and reopen then, and the list stays as it was when Apply began.
    func setApps(_ apps: [RunningMenuBarApp]) {
        guard !isApplying else { return }
// :182-183  reloadCurrent()  guard !isApplying else { return }
// :198-199  revert()         guard !isApplying else { return }
// :205-211
    /// Call when the window closes: an unapplied value, the ticks and the last report are let go.
    /// An Apply under way carries on.
    func windowClosed() {
        guard !isApplying else { return }
        revert()
        report = nil
    }
```

`apply()` reads the live draft when it starts, and clears the user's ticks even when the save failed:

```swift
// SpacingModel.swift:213-242
    /// Writes the slider's value if it's new and restarts the ticked apps one at a time.
    func apply() async {
        guard canApply else { return }
        let value = value
        let apps = candidates.filter(\.ticked).map(\.app)
        report = nil
        progress = (apps.first?.name ?? "", 0, apps.count)
        onApplyingChange?(true)
        applier.onProgress = { [weak self] app, index, count in self?.progress = (app.name, index, count) }
        let result = await applier.apply(value, relaunch: apps)
        applier.onProgress = nil
        let stored = applier.storedState()
        current = stored.value
        needsCleanup = !stored.isCanonical(for: stored.value)
        // The draft is applied: every tick follows the defaults again, and the restarted apps have
        // the stored spacing now.
        userTicks = [:]
        for restart in result.restarted {
            ...
        }
        progress = nil
        onApplyingChange?(false)
        retick()
        let report = SpacingReport(value: value, result: result)
        withAnimation(LayoutModel.rowAnimation) { self.report = report }
        onApplied?()
        AccessibilityNotification.Announcement("\(report.headline) \(report.detail.joined(separator: " "))").post()
    }
```

`SpacingReport.isWarning` (`SpacingModel.swift:25-28`) is true when the save failed, an app was
skipped, or a restarted app's icon didn't return. `result.saved` (`SpacingReport.saved`, line 20)
is false when the preferences couldn't be written; then no app is restarted.

`LayoutModel.apply()` keeps a reference to the spacing model and calls `apply()` on it only after
the layout part, so `apply()` reads whatever the draft holds by then:

```swift
// LayoutModel.swift:362-376
    @discardableResult
    func apply() -> Task<[Failure], Never>? {
        guard isDirty, !editsLocked else { return nil }
        let changes = draft.changes(anchors: canAnchor)
        let neighbours = Dictionary(changes.moves.map { ($0.item.id, draft.neighbours(of: $0.item)) }) { first, _ in first }
        let order = draft.hidden
        let hiddenBefore = draft.realHidden
        let spacing = spacing?.isPending == true ? spacing : nil
        applying = true
        message = nil
        return Task {
            let failures = await applyLayout(changes, neighbours: neighbours, hiddenOrder: order,
                                             hiddenBefore: hiddenBefore)
            // The spacing section reports (and announces) its own outcome.
            if let spacing { await spacing.apply() }
```

Meanwhile the window's refresh task keeps feeding the spacing model (it runs on every window
focus and every app launch/quit, `LayoutWindow.swift:132-135, 207-210`):

```swift
// LayoutWindow.swift:115-127 (plan 001 removes the `exempt:` argument on 125-126)
    private func refresh(after delay: Duration = .zero) {
        refreshTask?.cancel()
        refreshTask = Task { [model, spacing] in
            ...
            await model.refresh()
            spacing.reloadCurrent()
            let controller = model.controller
            spacing.setApps(await RunningMenuBarApps.list(drawn: controller.items, hidden: controller.state.hidden,
                                                         exempt: spacing.applier.hiddenAfterRestart))
        }
    }
```

`windowShouldClose` lets the window close while edits are locked (`LayoutWindow.swift:201-205`),
and `windowWillClose` calls `spacing.windowClosed()` (line 219), which reverts the spacing draft
because `isApplying` is still false during the layout part.

The close sheet's Apply closes the window when the layout part had no failures, whatever the
spacing part reported:

```swift
// LayoutWindow.swift:175-180
                switch response {
                case .alertFirstButtonReturn:
                    guard let applying = self.model.apply() else { return }
                    Task {
                        if await applying.value.isEmpty { self.window.close() }
                    }
```

Conventions:
- Doc comments (`///`) explain why, in plain sentences; match
  `Sources/YeeHaw/System/RevealCoordinator.swift`.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`) and the fake Mac
  `FakeSpacingMac` (`Tests/YeeHawTests/SpacingApplierTests.swift:9`). Its `events` log holds lines
  like `"terminate DigUp"`, and `writeFails = true` makes the save fail.
  `SpacingModelTests.app("DigUp")` builds a `RunningMenuBarApp`.
- `RunningMenuBarApp` is `Equatable` (`Sources/YeeHawCore/SpacingPlan.swift:4`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter "SpacingModelTests\|LayoutModelEditTests" 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| All tests | `swift test 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed`, no failures |

Do not run `scripts/build-app.sh` or install the app; this plan is verified by tests.

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHaw/UI/SpacingModel.swift`
- `Sources/YeeHaw/UI/LayoutModel.swift` (`apply()` only)
- `Sources/YeeHaw/UI/LayoutWindow.swift` (`askToApplyBeforeClosing()` only)
- `Tests/YeeHawTests/SpacingModelTests.swift`
- `Tests/YeeHawTests/LayoutModelEditTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/YeeHaw/System/SpacingApplier.swift`: plan 001 owns it; this plan only changes what
  the model hands it.
- `Sources/YeeHaw/UI/SpacingSection.swift`, `LayoutFooter.swift`, `LayoutView.swift`: the views
  already disable the slider and ticks while `model.applying` or `spacing.isApplying`.
- `LayoutWindow.swift`'s `refresh` and `windowShouldClose`: closing mid-Apply stays allowed; the
  snapshot makes it safe.

## Git workflow

- Start from the branch that has plan 001's commits (normally `build/yeehaw-v1`). Branch:
  `git checkout -b advisor/005-apply-uses-a-spacing-snapshot`
- One commit per step, conventional commits, e.g.
  `fix: apply the spacing change Layout showed when Apply was clicked`.
  Every message ends with a blank line and then
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Never put personal names in commits or code. Do NOT push or open a PR.

## Steps

### Step 1: Give SpacingModel a snapshot that Apply applies

In `Sources/YeeHaw/UI/SpacingModel.swift`:

1a. Above `final class SpacingModel` (after `enum SpacingPreview`), add:

```swift
/// The spacing change Apply makes, taken when Apply is clicked: the value and the apps ticked then.
/// The Layout window applies its spacing part only after the layout edits, and the section's list
/// can change meanwhile (the window re-reads running apps), so Apply works from this copy.
struct SpacingSnapshot: Equatable {
    let value: Int
    let apps: [RunningMenuBarApp]
}
```

1b. Inside `SpacingModel`, next to `userTicks`, add an observed (not `@ObservationIgnored`) property:

```swift
    /// The change Apply has taken and not finished yet. While it's set the section counts as
    /// applying, so re-reads, ticks, Revert and closing the window leave the draft alone.
    private var reserved: SpacingSnapshot?
```

1c. Change `isApplying` (line 124) to:

```swift
    var isApplying: Bool { progress != nil || reserved != nil }
```

Leave `canApply` as it is (it is false while applying, which is what stops a second Apply).

1d. Replace `apply()` (lines 213-242) with two methods. Keep the body's order of effects; only
the marked lines change:

```swift
    /// Takes the change Apply would make now and holds the draft still until `apply(_:)` has run.
    /// Nil when there's nothing to apply.
    func snapshotForApply() -> SpacingSnapshot? {
        guard canApply else { return nil }
        let snapshot = SpacingSnapshot(value: value, apps: candidates.filter(\.ticked).map(\.app))
        reserved = snapshot
        return snapshot
    }

    /// Writes the slider's value if it's new and restarts the ticked apps one at a time.
    func apply() async {
        guard let snapshot = snapshotForApply() else { return }
        await apply(snapshot)
    }

    /// Writes `snapshot.value` if it's new and restarts `snapshot.apps` one at a time, whatever the
    /// section shows by now.
    func apply(_ snapshot: SpacingSnapshot) async {
        reserved = snapshot
        let value = snapshot.value
        let apps = snapshot.apps
        report = nil
        progress = (apps.first?.name ?? "", 0, apps.count)
        onApplyingChange?(true)
        applier.onProgress = { [weak self] app, index, count in self?.progress = (app.name, index, count) }
        let result = await applier.apply(value, relaunch: apps)
        applier.onProgress = nil
        let stored = applier.storedState()
        current = stored.value
        needsCleanup = !stored.isCanonical(for: stored.value)
        // A saved draft is applied: every tick follows the defaults again. When the save failed
        // nothing changed, so the user's ticks stay for another try.
        if result.saved { userTicks = [:] }
        for restart in result.restarted {
            if let index = candidates.firstIndex(where: { $0.id == restart.app.bundleID }) {
                candidates[index].spacingAtLaunch = current
            }
        }
        progress = nil
        reserved = nil
        onApplyingChange?(false)
        retick()
        let report = SpacingReport(value: value, result: result)
        withAnimation(LayoutModel.rowAnimation) { self.report = report }
        onApplied?()
        AccessibilityNotification.Announcement("\(report.headline) \(report.detail.joined(separator: " "))").post()
    }
```

Check `SpacingApplier.Result` really has `saved` (it is used by `SpacingReport.saved` at line 20).

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter SpacingModelTests 2>&1 | tail -n 3` → passed (the existing tests still pass)
- `grep -n "reserved" Sources/YeeHaw/UI/SpacingModel.swift | wc -l` → at least `5`

### Step 2: LayoutModel takes the snapshot when Apply is clicked

In `Sources/YeeHaw/UI/LayoutModel.swift`, `apply()` (lines 362-396):

- Replace line 369, `let spacing = spacing?.isPending == true ? spacing : nil`, with:

```swift
        // The spacing change as the footer names it now: the window keeps re-reading running apps
        // during the layout part, and that mustn't add apps to restart or move the value.
        let spacing = self.spacing
        let spacingChange = spacing?.isPending == true ? spacing?.snapshotForApply() : nil
```

- Replace line 376, `if let spacing { await spacing.apply() }`, with:

```swift
            if let spacing, let spacingChange { await spacing.apply(spacingChange) }
```

Keep the comment on line 375. Nothing else in the method changes.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter LayoutModelEditTests 2>&1 | tail -n 3` → passed
- `grep -n "spacing.apply()" Sources/YeeHaw/UI/LayoutModel.swift` → no output

### Step 3: The close sheet's Apply keeps the window open when spacing warned

In `Sources/YeeHaw/UI/LayoutWindow.swift`, `askToApplyBeforeClosing()`, replace the
`.alertFirstButtonReturn` case (lines 176-180) with:

```swift
                case .alertFirstButtonReturn:
                    let appliesSpacing = self.spacing.isPending
                    guard let applying = self.model.apply() else { return }
                    Task {
                        let failures = await applying.value
                        // A spacing warning (an app quit but didn't reopen) stays on screen to be read.
                        let spacingWarned = appliesSpacing && self.spacing.report?.isWarning == true
                        if failures.isEmpty, !spacingWarned { self.window.close() }
                    }
```

`appliesSpacing` is read before `apply()` so a warning left over from an earlier Apply never keeps
the window open. Also update the method's doc comment (lines 159-161) so it says Apply closes
"once everything applied and the spacing change reported no problem".

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -n "spacingWarned" Sources/YeeHaw/UI/LayoutWindow.swift | wc -l` → `2`

### Step 4: Tests

Add the tests in the Test plan below, then run everything.

**Verify**:
- `swift test --filter "SpacingModelTests|LayoutModelEditTests" 2>&1 | tail -n 3` → passed
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output
- `swift test 2>&1 | tail -n 3` → passed, with 4 more tests than before this plan

## Test plan

Model new tests on `appsAreNotReReadWhileApplying` and `failedSaveIsReported` in
`Tests/YeeHawTests/SpacingModelTests.swift`, and on `applyWritesShowsHidesMovesThenSpacing` in
`Tests/YeeHawTests/LayoutModelEditTests.swift:174-202`.

In `SpacingModelTests` (`// MARK: Apply` section):

1. `aSnapshotIgnoresLaterReReadsAndClosing` (async):
   `mac = FakeSpacingMac()`, `model = Self.model(mac)`, `model.setApps([Self.app("DigUp")])`,
   `model.value = 8`, `let snapshot = try #require(model.snapshotForApply())`. Then
   `model.setApps([Self.app("DigUp"), Self.app("Flame")])` and `model.windowClosed()`.
   Expect `model.isApplying`, `model.value == 8`, `model.candidates.map(\.app.name) == ["DigUp"]`.
   `await model.apply(snapshot)`. Expect
   `mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"]`, `model.current == 8`,
   `!model.isApplying`.
2. `aFailedSaveKeepsTheUsersTicks` (async):
   `mac.writeFails = true`, `model.setApps([Self.app("DigUp"), Self.app("Flame")])`,
   `model.value = 8`, `model.setTicked(false, for: "com.example.flame")`, `await model.apply()`.
   Expect `model.report?.saved == false` and `model.candidates.map(\.ticked) == [true, false]`.
   (Before this plan the ticks reset, so Flame came back ticked: `[true, true]`.)
3. `nothingToApplyGivesNoSnapshot`: a fresh `Self.model()` → `model.snapshotForApply() == nil`
   and `!model.isApplying`.

In `LayoutModelEditTests`:

4. `spacingAppliesWhatTheFooterShowedWhenApplyWasClicked` (async throws):
   `bar = try StubBar(apps: [Self.a, Self.b])`, `(model, directory) = try await Self.model(bar)`,
   `defer` removing `directory`, `mac = FakeSpacingMac()`,
   `spacing = SpacingModel(applier: SpacingApplier(system: mac.system))`, `model.spacing = spacing`,
   `spacing.setApps([SpacingModelTests.app("DigUp")])`, `spacing.value = 8`,
   `let applying = try #require(model.apply())`. Before awaiting anything (the Task can't start
   yet), simulate the window: `spacing.setApps([SpacingModelTests.app("DigUp"), SpacingModelTests.app("Flame")])`
   and `spacing.windowClosed()`. Then `_ = await applying.value`. Expect
   `mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"]`,
   `spacing.current == 8`, `spacing.value == 8`, `!model.applying`.

Verification: `swift test 2>&1 | tail -n 3` → passed, including the 4 new tests.

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, with the 4 new tests above
- [ ] `grep -n "if result.saved { userTicks = \[:\] }" Sources/YeeHaw/UI/SpacingModel.swift` prints one line
- [ ] `grep -n "snapshotForApply" Sources/YeeHaw/UI/LayoutModel.swift` prints one line
- [ ] `grep -n "spacingWarned" Sources/YeeHaw/UI/LayoutWindow.swift` prints two lines
- [ ] `git diff --stat build/yeehaw-v1 -- Sources/YeeHaw/System/SpacingApplier.swift` prints nothing
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 005 updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 001's row in `plans/README.md` isn't DONE.
- `SpacingModel.apply()`, `isApplying`, `windowClosed()` or `LayoutModel.apply()` don't match
  the excerpts (apart from plan 001's change at `LayoutWindow.swift:125-126`).
- `SpacingApplier.Result` has no `saved` property, or the fix seems to need a change in
  `SpacingApplier.swift`.
- An existing test fails after Step 1 or 2 and the fix would change what it asserts (for example
  `closingTheWindowWhileApplyingChangesNothing` or `applyingIsAnnouncedToTheWindow`).
- Something other than `LayoutModel.apply()` and the tests calls `SpacingModel.apply()`
  (`grep -rn "\.apply()" Sources/YeeHaw/UI` shows another caller on a `SpacingModel`).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `reserved` makes the section read as applying from the click until the spacing part ends, so
  any new draft mutator must also `guard !isApplying`.
- If the window is closed during the layout part, the spacing report survives the close (as it
  already did when closed during the spacing part) and is shown the next time the window opens.
- Reviewers: check that `reserved` is cleared on every path through `apply(_:)` (there's no early
  return after it's set), and that `LayoutModel.apply()` calls `apply(_:)` whenever it got a
  snapshot; a snapshot taken and never applied would lock the section until relaunch.
- Deferred: the footer's Apply button never closes the window, so it needs no warning check.
