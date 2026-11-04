# Plan 009: The hidden-app record never loses an app or claims one is hidden when it isn't

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHawCore/AllowList.swift Sources/YeeHawCore/HidingState.swift Sources/YeeHawCore/MenuBarController.swift Tests/YeeHawCoreTests/AllowListTests.swift Tests/YeeHawCoreTests/ReconcilerTests.swift Tests/YeeHawCoreTests/MenuBarControllerTests.swift`
> Expected: no output. Plan 008 edits `MenuBarController.swift` (`move`/`place`)
> and adds tests to `MenuBarControllerTests.swift`; if it landed first, that drift
> is expected. For anything else that changed, compare the "Current state"
> excerpts against the live code before proceeding. On a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P3
- **Effort**: S–M
- **Risk**: MED (touches the journal that decides which apps get switched back on)
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. It hides an app's menu bar icon by setting
`isAllowed=false` in the app's entry of Apple's Allow list (the `trackedApplications` blob in
`group.com.apple.controlcenter.plist`). It keeps a record (`HidingState`): `hidden` (the strip's
apps) and `journal` (apps YeeHaw itself switched off, which must be switched back on at quit or
next launch). The journal's rule is: it always includes every app YeeHaw switched off that may
still be off. Four rare holes break that rule or its mirror: (1) a hide whose write failed, whose
undo then can't read the file, leaves the app recorded as hidden while it's visible, and hiding it
again does nothing; (2) a switch-on for an app with no Allow-list entry is silently skipped but the
app still leaves the journal; (3) at launch, a journaled app whose entry is missing is dropped from
the journal with nothing switched on; (4) an app listed twice in the Allow list is read from its
last entry but written to its first. After this plan the journal only forgets an app once its
switch-on really landed, and duplicate entries are read and written consistently.

## Current state

Files:
- `Sources/YeeHawCore/AllowList.swift`: reads/writes Apple's Allow-list blob (pure).
- `Sources/YeeHawCore/HidingState.swift`: `HidingState` and `Reconciler` (pure rules).
- `Sources/YeeHawCore/MenuBarController.swift`: applies the rules through the files.
- Tests: `Tests/YeeHawCoreTests/AllowListTests.swift`, `ReconcilerTests.swift`,
  `MenuBarControllerTests.swift` (its fakes `FakeSystem`, `FakeStore`, `FakeSleeper` are at the top,
  lines 9-223).

**Hole 1: hide's undo.** `hide` journals first, then writes; on any error it calls `rollBack`:

```swift
// MenuBarController.swift:163-180
    public func hide(_ id: BundleID, waits: Bool = true) async throws {
        try await gated {
            let locations = await runningLocations(of: id)
            let allow = try readAllow().snapshot
            guard allow[id] != nil else { throw ControllerError.notTracked(id) }
            let r = Reconciler.hide(id, state, allow: allow, locations: locations)
            guard !r.actions.isEmpty else { return }
            let before = state
            save(r.state)
            do {
                try writeAllow(r.actions)
                if waits { try await waitIfRunning(id, drawn: false) }
            } catch {
                rollBack(id, allowed: true, to: before)
                throw error
            }
        }
    }
// MenuBarController.swift:465-469
    private func rollBack(_ id: BundleID, allowed: Bool?, to before: HidingState) {
        switch allowed {
        case true?:
            guard (try? writeAllow([.switchOn(id)])) != nil else { return }
            save(before)
```

If `writeAllow(r.actions)` threw, nothing was written (its only throwing calls come before
`allowFile.write`, which is its last throwing call), so the app is still on. But `rollBack` re-reads
the file; if that read fails too, it returns without `save(before)`, leaving `hidden` and `journal`
holding an app that's visible. `Reconciler.hide` then refuses to hide it again:

```swift
// HidingState.swift:90
        guard allow[id] == true, !s.hidden.contains(id) else { return ([], s) }
```

**Hole 2: skipped switch-ons leave the journal.** `writeAllow` skips actions for apps with no entry:

```swift
// MenuBarController.swift:594-617
    private func writeAllow(_ actions: [AllowAction]) throws {
        var list = try readAllow()
        let before = list.snapshot
        var written: AllowSnapshot = [:]
        var listed = false
        for action in actions {
            let (id, allowed): (BundleID, Bool)
            switch action {
            case .switchOn(let target): (id, allowed) = (target, true)
            case .switchOff(let target): (id, allowed) = (target, false)
            case .addLocation(let target, let location):
                if list.addLocation(location, for: target) { listed = true }
                continue
            }
            guard let current = before[id] else { continue }
            written[id] = allowed
            if current != allowed { list.setAllowed(allowed, for: id) }
        }
        if listed || written.contains(where: { before[$0.key] != $0.value }) {
            try allowFile.write(Self.allowKey, try list.encoded())
            writeCount += 1
        }
        lastSnapshot.merge(written) { _, new in new }
    }
```

but `finish` (used by `launch` and `quit`) sets the journal to the target as soon as the write
didn't throw:

```swift
// MenuBarController.swift:112-121
    private func finish(allow actions: [AllowAction], journal: Set<BundleID>,
                        restoring positions: [String: Double?]) throws {
        var next = state
        var failure: Error?
        do {
            if !actions.isEmpty { try writeAllow(actions) }
            next.journal = journal
        } catch {
            failure = error
        }
```

**Hole 3: launch drops journaled apps with no entry.**

```swift
// HidingState.swift:65-69 (Reconciler.onLaunch)
        state.hidden = s.hidden.filter { allow[$0] == true || (allow[$0] == false && s.journal.contains($0)) }
        let hiddenSet = Set(state.hidden)
        let offs = state.hidden.filter { allow[$0] == true }
        let ons = s.journal.filter { allow[$0] != nil && !hiddenSet.contains($0) }.sorted()
        state.journal = s.journal.filter { hiddenSet.contains($0) }.union(offs)
```

An app in the journal whose entry is missing (`allow[$0] == nil`) gets no switch-on and leaves the
journal. If macOS later brings its entry back still switched off, nothing ever switches it on.
The test `launchDropsUntrackedFromHiddenAndJournal` (`ReconcilerTests.swift:41-47`) asserts this
behaviour and must change.

**Hole 4: duplicate entries.** `snapshot` keeps the last entry's value; `setAllowed` changes only
the first; `locations`/`addLocation` use `entryIndex`, the first:

```swift
// AllowList.swift:54-79
    public var snapshot: AllowSnapshot {
        var result: AllowSnapshot = [:]
        for index in stride(from: 0, to: items.count, by: 2) {
            guard let id = Self.bundleID(of: items[index]),
                  let value = items[index + 1] as? [String: Any],
                  let allowed = value["isAllowed"] as? Bool
            else { continue }
            result[id] = allowed
        }
        return result
    }

    /// Returns false when `id` is not a tracked bundle entry.
    @discardableResult
    public mutating func setAllowed(_ allowed: Bool, for id: BundleID) -> Bool {
        for index in stride(from: 0, to: items.count, by: 2) {
            guard Self.bundleID(of: items[index]) == id,
                  var value = items[index + 1] as? [String: Any],
                  value["isAllowed"] is Bool
            else { continue }
            value["isAllowed"] = allowed
            items[index + 1] = value
            return true
        }
        return false
    }
// AllowList.swift:81-104: locations(for:) and addLocation(_:for:) both start with
//   guard let index = entryIndex(of: id) ...
    private func entryIndex(of id: BundleID) -> Int? {
        stride(from: 0, to: items.count, by: 2).first { Self.bundleID(of: items[$0]) == id }
    }
```

`setAllowed`'s return value is ignored by every caller in `Sources` (check:
`grep -rn "setAllowed(" Sources Tests`); `AllowListTests.setAllowedFlipsOnlyThatEntry` expects
`true` for a real flip and `setAllowedOnUntrackedReturnsFalse` expects `false` for an unknown app.

Conventions:
- Doc comments (`///`) explain why, in plain sentences; match the existing comments in
  `MenuBarController.swift` (e.g. its journal invariant, lines 17-19) and
  `Sources/YeeHaw/System/RevealCoordinator.swift`.
- Tests: Swift Testing. Controller tests use `Self.rig(_:state:)` and `rig.controller()`
  (`MenuBarControllerTests.swift:232-247`); `FakeSystem(allow: [(id, Bool)])` builds an Allow list;
  `rig.system.failWrites(.allowList)` makes writes throw `WriteFailed`; `rig.system.fail(.allowList)`
  makes reads and writes throw a grant error; `FakeSystem.blob(_:)` and `setAllowBlob(_:)` replace
  the list. Model new tests on `aHideWhoseWriteFailsIsUndone` (lines 479-487) and
  `quitSwitchesJournalOnInOneWrite` (lines 1021-1034).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter "AllowListTests\|ReconcilerTests\|MenuBarControllerTests" 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| All tests | `swift test 2>&1 \| tail -n 3` | passed, no failures |

Never run YeeHaw against the real Allow list for this plan; the tests cover it.

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHawCore/AllowList.swift`
- `Sources/YeeHawCore/HidingState.swift` (`Reconciler.onLaunch` only)
- `Sources/YeeHawCore/MenuBarController.swift` (`hide`, `finish`, `writeAllow` only)
- `Tests/YeeHawCoreTests/AllowListTests.swift`
- `Tests/YeeHawCoreTests/ReconcilerTests.swift`
- `Tests/YeeHawCoreTests/MenuBarControllerTests.swift` (one new knob on `FakeSystem`, new tests)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `show`, `rollBack`, `finishReveal`, `beginReveal`: they have their own undo paths; changing them
  is a separate review.
- `Reconciler.onQuit`, `hide`, `show`, `externalChange`: their rules stay.
- Anything in `Sources/YeeHaw` (the app target).

## Git workflow

- From `build/yeehaw-v1`: `git checkout -b advisor/009-hidden-record-holes`
- One commit per step, conventional commits, e.g.
  `fix: keep an app journaled until its switch-on really lands`.
  End each message with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No personal names. Do NOT push or open a PR.

## Steps

### Step 1: Duplicate Allow-list entries are read and written together

In `Sources/YeeHawCore/AllowList.swift`:

- `snapshot`: replace `result[id] = allowed` with
  `result[id] = (result[id] ?? true) && allowed`, and add a doc comment above `snapshot`:
  `/// An app listed more than once counts as allowed only when every entry says so: which entry MenuBarAgent honours isn't known, so YeeHaw never takes an app for shown while one entry hides it.`
- `setAllowed`: set `isAllowed` on **every** matching entry, and return whether any entry
  changed. Shape (the doc comment replaces the old one):

```swift
    /// Sets every entry of `id`. Returns true when an entry changed; false when all already said
    /// so or `id` isn't tracked.
    @discardableResult
    public mutating func setAllowed(_ allowed: Bool, for id: BundleID) -> Bool {
        var changed = false
        for index in entryIndices(of: id) {
            guard var value = items[index + 1] as? [String: Any], let current = value["isAllowed"] as? Bool,
                  current != allowed else { continue }
            value["isAllowed"] = allowed
            items[index + 1] = value
            changed = true
        }
        return changed
    }
```

- `locations(for:)`: the union of every matching entry's locations, in order, without repeats.
- `addLocation(_:for:)`: append to every matching entry that doesn't list it; return true if any
  entry changed. Keep "starting the list if it has none".
- Replace `entryIndex(of:)` with:

```swift
    private func entryIndices(of id: BundleID) -> [Int] {
        stride(from: 0, to: items.count, by: 2).filter { Self.bundleID(of: items[$0]) == id }
    }
```

Add AllowList tests 1-3 from the Test plan.

**Verify**:
- `swift test --filter AllowListTests 2>&1 | tail -n 3` → passed (old and new)
- `grep -n "entryIndex(of" Sources/YeeHawCore/AllowList.swift` → no output

### Step 2: `writeAllow` writes what changed and returns the apps it switched

In `MenuBarController.writeAllow` (lines 590-617):

- Make it `@discardableResult private func writeAllow(_ actions: [AllowAction]) throws -> Set<BundleID>`.
- Track a `var switched = false`. Replace
  `if current != allowed { list.setAllowed(allowed, for: id) }` with
  `if list.setAllowed(allowed, for: id) { switched = true }`, and change
  `guard let current = before[id] else { continue }` to `guard before[id] != nil else { continue }`
  (`current` would otherwise be unused, which is a compiler warning).
- Write when `listed || switched` (instead of comparing `written` to `before`). For apps with one
  entry this is the same test; with duplicates it also catches an entry that disagreed.
- `return Set(written.keys)` at the end: the apps whose entries now hold the asked-for switch.
- Update its doc comment: "... Returns the apps whose entries hold the asked-for switch; an app
  with no entry isn't among them."

In `finish` (lines 112-121) replace the `do` block with:

```swift
        do {
            let switched: Set<BundleID> = actions.isEmpty ? [] : try writeAllow(actions)
            // A switch-on for an app with no entry wasn't written; it stays journaled until it can be.
            next.journal = journal.union(Self.switchedOn(actions).filter { !switched.contains($0) })
        } catch {
            failure = error
        }
```

Add controller tests 6 and 7 from the Test plan.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter MenuBarControllerTests 2>&1 | tail -n 3` → passed

### Step 3: Launch keeps journaled apps whose entry is missing

In `Reconciler.onLaunch` (`HidingState.swift:69`) change the journal line to:

```swift
        // An app whose entry is missing can't be switched on now; it stays journaled, so it's
        // switched on once macOS lists it again.
        state.journal = s.journal.filter { hiddenSet.contains($0) || allow[$0] == nil }.union(offs)
```

Leave `hidden` as it is (an app with no entry isn't drawn, so it leaves the strip). Update the doc
comment above `onLaunch` if it says otherwise.

In `ReconcilerTests.swift`, rename `launchDropsUntrackedFromHiddenAndJournal` to
`launchDropsUntrackedFromHiddenButKeepsThemJournaled` and change only its journal expectation to
`#expect(r.state.journal == ["A", "G", "H"])`. Its other expectations stay.

Add Reconciler test 4 and controller test 8 from the Test plan.

**Verify**:
- `swift test --filter "ReconcilerTests|MenuBarControllerTests" 2>&1 | tail -n 3` → passed

### Step 4: A hide whose write never landed just goes back

Add a knob to `FakeSystem` in `MenuBarControllerTests.swift` (next to `failWrites`, line ~103):

```swift
    /// The next write to `file` throws `WriteFailed`, and from then on reading or writing it fails
    /// as if the grant were lost (a write refused, then the file gone unreadable).
    func breakOnNextWrite(_ file: GrantedFile) { locked { _ = $0._breakOnWrite.insert(file) } }
```

with a stored `private var _breakOnWrite: Set<GrantedFile> = []` beside `_failingWrites`, and at
the start of `write(_:_:_:)`'s locked closure (after the `_failing` check):

```swift
            if $0._breakOnWrite.remove(file) != nil {
                $0._failing.insert(file)
                throw WriteFailed()
            }
```

In `MenuBarController.hide`, replace the `do`/`catch` (lines 172-178) with:

```swift
            var switchedOff = false
            do {
                try writeAllow(r.actions)
                switchedOff = true
                if waits { try await waitIfRunning(id, drawn: false) }
            } catch {
                // A write that never landed left the app on, so the record just goes back. Once it
                // landed, the app is switched back on first (`rollBack`).
                if switchedOff { rollBack(id, allowed: true, to: before) } else { save(before) }
                throw error
            }
```

Update `hide`'s doc comment (lines 159-162) to say a failed write puts the record back at once
and a hide macOS didn't honour is switched back on.

Add controller test 5 from the Test plan.

**Verify**:
- `swift test --filter MenuBarControllerTests 2>&1 | tail -n 3` → passed
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output
- `swift test 2>&1 | tail -n 3` → passed

## Test plan

In `Tests/YeeHawCoreTests/AllowListTests.swift` (helpers `bundleKey`, `bundleValue`, `decode`,
`fiddle` exist at lines 6-37 and 76):

1. `anAppListedTwiceIsAllowedOnlyWhenEveryEntryIs`: blob
   `[bundleKey("A"), bundleValue("A", allowed: true), bundleKey("A"), bundleValue("A", allowed: false)]`
   → `snapshot == ["A": false]`. Swap the order of the two values → still `["A": false]`.
2. `settingAnAppListedTwiceSetsBothEntries`: same blob; `list.setAllowed(true, for: "A")` returns
   `true`; re-read (`AllowList(data: list.encoded())`) → `snapshot == ["A": true]` and both decoded
   values have `isAllowed == true`. A second `setAllowed(true, for: "A")` returns `false`.
3. `locationsOfAnAppListedTwiceAreMerged`: blob
   `[bundleKey(fiddle), ["isAllowed": true], bundleKey(fiddle), ["isAllowed": true, "menuItemLocations": [AllowLocation.bundle(fiddle).plist]]]`;
   `locations(for: fiddle) == [.bundle(fiddle)]`; `addLocation(.bundle(fiddle), for: fiddle)` returns
   `true`; afterwards both decoded entries list `.bundle(fiddle)` once.

In `Tests/YeeHawCoreTests/ReconcilerTests.swift`:

4. `quitAndLaunchTogetherNeverLoseAnAppWithNoEntry`:
   `Reconciler.onLaunch(Self.state(journal: ["Z"]), allow: [:])` → `r.actions.isEmpty`,
   `r.state.journal == ["Z"]`; then `Reconciler.onLaunch(r.state, allow: ["Z": false])` →
   `actions == [.switchOn("Z")]`.

In `Tests/YeeHawCoreTests/MenuBarControllerTests.swift`:

5. `aHideWhoseWriteFailsIsUndoneEvenWhenTheFileThenWontRead` (async throws):
   `rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))`, `rig.system.breakOnNextWrite(.allowList)`,
   `await #expect(throws: WriteFailed.self) { try await c.hide(Self.a) }`; expect
   `c.state.hidden.isEmpty`, `c.state.journal.isEmpty`, `rig.store.load().journal.isEmpty`.
   (Before the fix: hidden and journal both `[A]`.)
6. `quitKeepsAJournaledAppWhoseEntryIsMissing` (async throws):
   `rig = Self.rig(try FakeSystem(allow: [(Self.b, true)]), state: HidingState(journal: [Self.a]))`,
   `try c.quit()` → `c.state.journal == [Self.a]`, `rig.store.load().journal == [Self.a]`.
   Then the entry comes back off:
   `rig.system.setAllowBlob(try FakeSystem.blob([(Self.a, false), (Self.b, true)]))`, `try c.quit()` →
   `rig.system.allowSnapshot[Self.a] == true`, `c.state.journal.isEmpty`.
7. `aSwitchOnReachesEveryEntryOfAnAppListedTwice` (async throws):
   `rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]), state: HidingState(journal: [Self.a]))`,
   `rig.system.setAllowBlob(try FakeSystem.blob([(Self.a, true), (Self.a, false)]))`, `try c.quit()` →
   `rig.system.allowSnapshot == [Self.a: true]` and `rig.system.allowWrites == 1`.
   (Before: the snapshot read the last entry as `false`, `setAllowed` flipped only the first,
   which was already `true`, so the second stayed off.)
8. `launchKeepsAJournaledAppWhoseEntryIsMissing` (async throws):
   `rig = Self.rig(try FakeSystem(allow: [(Self.b, true)]), state: HidingState(hidden: [Self.a], journal: [Self.a]))`,
   `try await c.launch()` → `c.state.hidden.isEmpty`, `c.state.journal == [Self.a]`.

Verification: `swift test 2>&1 | tail -n 3` → passed, 8 more tests than before this plan (one
existing test renamed, not added).

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, including the 8 new tests
- [ ] `grep -n "launchDropsUntrackedFromHiddenAndJournal" Tests/YeeHawCoreTests/ReconcilerTests.swift` prints nothing
- [ ] `grep -n "switchedOff = true" Sources/YeeHawCore/MenuBarController.swift` prints one line
- [ ] `grep -n "throws -> Set<BundleID>" Sources/YeeHawCore/MenuBarController.swift` prints one line
- [ ] `git diff --stat build/yeehaw-v1 -- Sources/YeeHaw` prints nothing
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 009 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `hide`, `finish`, `writeAllow`, `rollBack`, `Reconciler.onLaunch` or the `AllowList` methods
  don't match the excerpts.
- `writeAllow` turns out to have a throwing call **after** `allowFile.write(...)` (then "it threw"
  no longer means "nothing was written", and Step 4's reasoning fails).
- Any existing test other than `launchDropsUntrackedFromHiddenAndJournal` needs a changed
  expectation. In particular `hideNotHonoredThrowsWithoutRetry` must still see exactly 2 Allow
  writes, and `unchangedWritesAreSkipped` / `missingAllowKeyIsNeverCreated` must still pass.
- Some caller in `Sources` uses `setAllowed`'s return value (the meaning changes from "found" to
  "changed").
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- An uninstalled app now stays in the journal for good (its switch-on can't be written). That's
  harmless: the switch-on is skipped each time, and it clears itself if the app's entry comes back.
  If the journal ever grows noticeably, prune ids whose app isn't installed.
- `show`'s failure path still re-reads the file to undo; the same "did the write land" tracking
  could apply there. Deferred: no observed failure, and the undo direction (switching off again)
  errs on the safe side.
- Reviewers: check the journal invariant comment at `MenuBarController.swift:17-19` still reads
  true, and that `finish` keeps only switch-ons (not switch-offs) that weren't written.
