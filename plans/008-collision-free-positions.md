# Plan 008: Position values never collide, multi-icon apps keep their order, and impossible placements are refused

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHawCore/PositionTable.swift Sources/YeeHawCore/MenuBarController.swift Tests/YeeHawCoreTests/PositionTableTests.swift Tests/YeeHawCoreTests/MenuBarControllerTests.swift`
> Expected: no output. Plan 009 also edits `MenuBarController.swift` and
> `MenuBarControllerTests.swift` (hide/finish/writeAllow, not `move`/`place`);
> if it landed first, that drift is expected. For anything else that changed,
> compare the "Current state" excerpts against the live code before
> proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. It orders icons by writing numbers to
`TrailingItemPreferredPositions` in `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`:
each icon's key gets a value, a larger value sits further left, and the clock (`module:Clock`) is 0.
Three small flaws in the maths make icons land in the wrong place, rarely but confusingly:
(1) a move takes the midpoint between its neighbours even when another key (often a hidden app's)
already has exactly that value, so the two tie and macOS orders them arbitrarily; (2) showing an app
with several icons gives all of them one value, so its icons may come back in any order; (3) a left
neighbour that is really right of the right neighbour, or a clock missing from the table used as a
left neighbour, silently sends the icon somewhere else (the far left, or bumps the clock). After this
plan every value written is unique among the keys around it, an app's icons keep their relative
order, and a placement that can't be honest throws `ControllerError.unresolvedNeighbor`, which the
Layout window already explains to the user.

## Current state

- `Sources/YeeHawCore/PositionTable.swift`: the pure position maths (`placement`, `slotValue`).
- `Sources/YeeHawCore/MenuBarController.swift`: `move` (lines 276-291) and `place` (lines 293-320)
  call `placement`; `neighborKey` (lines 502-516) resolves a neighbour's key.
- `Tests/YeeHawCoreTests/PositionTableTests.swift`, `Tests/YeeHawCoreTests/MenuBarControllerTests.swift`.

`placement` today:

```swift
// PositionTable.swift:9-41
    public static let minimumGap: Double = 1.0

    /// Changed entries only. `leftNeighbor` has the larger value; nil = moving to the far left.
    /// `rightNeighbor` nil = immediately left of module:Clock (value 0).
    /// The moved keys are excluded from every lookup and all receive the same value.
    public func placement(of keys: [String], leftNeighbor: String?, rightNeighbor: String?) -> [String: Double] {
        let moved = Set(keys)
        let others = values.filter { !moved.contains($0.key) }

        let leftValue = leftNeighbor.flatMap { others[$0] }
        let upper = leftValue ?? ((others.values.max() ?? 0) + 20)
        let lower = rightNeighbor.flatMap { others[$0] } ?? 0

        if upper - lower >= 2 * Self.minimumGap {
            let v = (upper + lower) / 2
            return Dictionary(uniqueKeysWithValues: moved.map { ($0, v) })
        }

        let v = lower + Self.minimumGap
        var result = Dictionary(uniqueKeysWithValues: moved.map { ($0, v) })
        guard let leftValue else { return result }

        // Entries tied at one original value (duplicate keys of one item) move as a group.
        let groups = Dictionary(grouping: others.filter { $0.value >= leftValue }, by: { $0.value })
        var previous = v
        for value in groups.keys.sorted() {
            let needed = previous + Self.minimumGap
            guard value < needed else { break }
            for entry in groups[value]! { result[entry.key] = needed }
            previous = needed
        }
        return result
    }
```

Problems in it:
- The midpoint ignores keys strictly between `lower` and `upper` (undrawn apps' keys), so it can
  equal one of them.
- In the tight branch only entries `>= leftValue` are bumped, so `v` can equal an entry between the
  neighbours.
- A left neighbour at or below the right one (`upper <= lower`) still "places", and the cascade then
  bumps the right neighbour too.
- `module:Clock` absent from the table: `others[clock]` is nil, so as a left neighbour it means
  "far left".

Callers:

```swift
// MenuBarController.swift:281-290 (move)
    public func move(_ item: MenuBarItem, leftNeighbor: MenuBarItem?, rightNeighbor: MenuBarItem?) throws {
        guard !item.isPinned, item.bundleID != nil || item.appleIdentifier != nil else { return }
        try guarded {
            let table = PositionTable(try readPositions())
            let keys = item.bundleID != nil
                ? PositionKey.keys(for: item, among: items, table: table) : [try neighborKey(item, table)]
            let left = try leftNeighbor.map { try neighborKey($0, table) }
            let right = try rightNeighbor.map { try neighborKey($0, table) }
            try writePositions(table.placement(of: keys, leftNeighbor: left, rightNeighbor: right))
        }
    }
// MenuBarController.swift:315-318 (end of place)
            let left = try leftNeighbor.map(key)
            let right = try rightNeighbor.map(key)
            let keys = Self.revealKeys(prefixes: prefixes, table)
            try writePositions(table.placement(of: keys, leftNeighbor: left, rightNeighbor: right))
// MenuBarController.swift:447-453
    /// Every existing key of the app under any of its prefixes (hiding is per app, so the whole
    /// app appears), else `Item-0` under the first prefix. ...
    private static func revealKeys(prefixes: [String], _ table: PositionTable) -> [String] {
        let existing = PositionKey.existingKeys(prefixes: prefixes, table: table)
        return existing.isEmpty ? prefixes.prefix(1).map { "status:\($0)::Item-0" } : existing
    }
// MenuBarController.swift:511-515 (neighborKey)
        // The clock is 0 by definition; any other key must exist or the placement would be a guess.
        guard let key, key == PositionKey.clock || table.values[key] != nil else {
            throw ControllerError.unresolvedNeighbor
        }
        return key
```

In `move`, the keys are all the names of **one** icon (aliases), so they must share one value. In
`place`, the keys are every key of an **app**: several icons, plus aliases of each. Aliases of one
icon already share a value in the table (see test `aHiddenAppIsPlacedBetweenItsNeighboursBeforeItsDrawn`,
where `Item-0` and `Clock` are both 400), so grouping keys by their current value separates icons
while keeping aliases together.

`ControllerError.unresolvedNeighbor` (`MenuBarController.swift:9-10`) is shown by the Layout
window as "macOS hasn’t saved a position for an icon there yet, so YeeHaw can’t place it."
(`Sources/YeeHaw/UI/LayoutModel.swift:544-545`). `PositionKey.clock` is `"module:Clock"`
(`Sources/YeeHawCore/PositionKey.swift:3`), in the same module as `PositionTable`.

Out of reach of this plan: `beginReveal` (`MenuBarController.swift:375-382`) also writes one value
to all of an app's keys, but a reveal is temporary and its original values are restored.

Conventions:
- Doc comments (`///`) explain why, in plain sentences; match this file and
  `Sources/YeeHaw/System/RevealCoordinator.swift`.
- Tests: Swift Testing. `#expect(throws: ControllerError.unresolvedNeighbor) { try ... }` as in
  `MenuBarControllerTests.unresolvableNeighborThrows` (lines 619-632). Controller tests build a
  `FakeSystem` with `positions:` and read `rig.system.positions` (see `moveWritesAllKeysOfItem`,
  lines 581-601).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter "PositionTableTests\|MenuBarControllerTests" 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| Layout tests | `swift test --filter "LayoutModelEditTests\|LayoutModelTests" 2>&1 \| tail -n 3` | passed |
| All tests | `swift test 2>&1 \| tail -n 3` | passed, no failures |

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHawCore/PositionTable.swift`
- `Sources/YeeHawCore/MenuBarController.swift` (`move`, `place`, the comment in `neighborKey` only)
- `Tests/YeeHawCoreTests/PositionTableTests.swift`
- `Tests/YeeHawCoreTests/MenuBarControllerTests.swift` (new tests in `// MARK: move`)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `slotValue(leftOf:)`, `placeOwnIcon`, `beginReveal`, `finishReveal`: reveal slots are temporary
  and restored; YeeHaw's own icon has its own rules.
- `Sources/YeeHaw/UI/LayoutModel.swift`: its message for `.unresolvedNeighbor` stays as is.
- `PositionKey.swift`: key resolution is right.

## Git workflow

- From `build/yeehaw-v1`: `git checkout -b advisor/008-collision-free-positions`
- Conventional commits, one per step, e.g.
  `fix: never give a moved icon a position another icon already has`.
  End each message with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No personal names. Do NOT push or open a PR.

## Steps

### Step 1: Rewrite `placement` as a throwing, collision-free `placement(ofGroups:)`

In `Sources/YeeHawCore/PositionTable.swift`, replace `placement(of:leftNeighbor:rightNeighbor:)`
(lines 11-41) with the two methods below and add `groupedByValue`. Keep `minimumGap` and
`slotValue` as they are.

```swift
    /// Changed entries only, for icons placed side by side between two neighbours. Each group is
    /// one icon's keys (its aliases), which share a value; groups get distinct values, the first
    /// furthest left. `leftNeighbor` nil = the far left; `rightNeighbor` nil = immediately left of
    /// the clock. The clock counts as 0 even when the table has no key for it.
    ///
    /// The values go in the widest free stretch between the neighbours, so none lands on a key
    /// that's already there (often a hidden app's). With no room, the groups take the values just
    /// left of the right neighbour and every key in the way moves left, keeping its order. Throws
    /// `.unresolvedNeighbor` when the left neighbour isn't left of the right one: the table and the
    /// caller disagree, so any value would be a guess.
    public func placement(ofGroups groups: [[String]], leftNeighbor: String?,
                          rightNeighbor: String?) throws -> [String: Double] {
        let groups = groups.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return [:] }
        let moved = Set(groups.joined())
        let others = values.filter { !moved.contains($0.key) }
        func value(of key: String) -> Double? { others[key] ?? (key == PositionKey.clock ? 0 : nil) }

        let leftValue = leftNeighbor.flatMap(value(of:))
        let upper = leftValue ?? ((others.values.max() ?? 0) + 20)
        let lower = rightNeighbor.flatMap(value(of:)) ?? 0
        if leftValue != nil, upper <= lower { throw ControllerError.unresolvedNeighbor }
        let count = Double(groups.count)

        // The widest stretch between neighbouring values; on a tie, the one nearest the left neighbour.
        let edges = [lower] + Set(others.values.filter { $0 > lower && $0 < upper }).sorted() + [upper]
        var gap = (low: lower, high: lower)
        for (low, high) in zip(edges, edges.dropFirst()) where high - low >= gap.high - gap.low {
            gap = (low, high)
        }

        var result: [String: Double] = [:]
        if gap.high - gap.low >= (count + 1) * Self.minimumGap {
            let step = (gap.high - gap.low) / (count + 1)
            for (index, group) in groups.enumerated() {
                for key in group { result[key] = gap.high - step * Double(index + 1) }
            }
            return result
        }

        for (index, group) in groups.enumerated() {
            for key in group { result[key] = lower + Self.minimumGap * (count - Double(index)) }
        }
        // Entries tied at one original value (aliases of one icon) move as a group.
        let inTheWay = Dictionary(grouping: others.filter { $0.value > lower }, by: { $0.value })
        var previous = lower + Self.minimumGap * count
        for value in inTheWay.keys.sorted() {
            let needed = previous + Self.minimumGap
            guard value < needed else { break }
            for entry in inTheWay[value]! { result[entry.key] = needed }
            previous = needed
        }
        return result
    }

    /// `placement(ofGroups:)` for one icon: all of `keys` name it, so they share one value.
    public func placement(of keys: [String], leftNeighbor: String?, rightNeighbor: String?) throws -> [String: Double] {
        try placement(ofGroups: [keys], leftNeighbor: leftNeighbor, rightNeighbor: rightNeighbor)
    }

    /// `keys` split into one group per icon, furthest left first: keys with the same value are
    /// aliases of one icon. Keys the table doesn't have form a last group.
    public func groupedByValue(_ keys: [String]) -> [[String]] {
        let unique = Array(Set(keys)).sorted()
        let byValue = Dictionary(grouping: unique.filter { values[$0] != nil }, by: { values[$0]! })
        var groups = byValue.keys.sorted(by: >).map { byValue[$0]! }
        let missing = unique.filter { values[$0] == nil }
        if !missing.isEmpty { groups.append(missing) }
        return groups
    }
```

Note the one behaviour change on the cascade: it now moves every key in the way above `lower`
(not only those at or left of the left neighbour), which is what keeps the values unique.

Update the type's doc comment (line 1) only if it no longer reads true; it should still say
"a larger value sits further left, `module:Clock` is 0".

**Verify**: `swift build 2>&1 | grep -E "error:"` → errors only at the `placement(of:` call sites in
`MenuBarController.swift` (missing `try`) and in `PositionTableTests.swift`. Fixed in Steps 2-3.

### Step 2: Callers

In `Sources/YeeHawCore/MenuBarController.swift`:

- `move`, line 289: `try writePositions(try table.placement(of: keys, leftNeighbor: left, rightNeighbor: right))`
- `place`, lines 317-318:

```swift
            // One value per icon, in the app's own order, so a multi-icon app comes back as it was.
            let groups = table.groupedByValue(Self.revealKeys(prefixes: prefixes, table))
            try writePositions(try table.placement(ofGroups: groups, leftNeighbor: left, rightNeighbor: right))
```

- `neighborKey`, line 511 comment becomes:
  `// The clock is 0 by definition, key or not (PositionTable counts a missing one as 0); any other key must exist or the placement would be a guess.`
  Don't change the code below it.
- Update `place`'s doc comment (lines 293-296): "every existing key of the app ... gets the slot"
  becomes "the app's icons get distinct values in the slot, in their existing order".

**Verify**: `swift build 2>&1 | grep -E "warning:|error:"` → no output.

### Step 3: Existing PositionTable tests compile again

In `Tests/YeeHawCoreTests/PositionTableTests.swift`, every test that calls `placement(of:...)`
gains `throws` in its signature and `try` before the call (e.g.
`@Test func placesBetweenNeighbors() throws {` and `let result = try Self.real.placement(...)`).
Where the call sits inside `#expect` (line 34), write `#expect(try table.placement(...) == ...)`.
Change nothing else in them; every expected value stays.

**Verify**: `swift test --filter PositionTableTests 2>&1 | tail -n 3` → passed (all 11 existing tests).

### Step 4: New tests

Add the tests in the Test plan.

**Verify**:
- `swift test --filter "PositionTableTests|MenuBarControllerTests" 2>&1 | tail -n 3` → passed
- `swift test --filter "LayoutModelEditTests|LayoutModelTests" 2>&1 | tail -n 3` → passed
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output
- `swift test 2>&1 | tail -n 3` → passed

## Test plan

In `Tests/YeeHawCoreTests/PositionTableTests.swift` (model on `tightGapCascades`, lines 37-41):

1. `neverLandsOnAnotherKey`: `PositionTable(["left": 400, "hidden": 300, "right": 200, "moved": 50])`,
   `placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")` → `["moved": 350]`
   (the old midpoint was 300, the hidden key's value).
2. `aTightCascadeNeverCollides`: `PositionTable(["right": 10, "h": 11, "left": 11.5, "m": 40])`,
   `placement(of: ["m"], leftNeighbor: "left", rightNeighbor: "right")` →
   `["m": 11, "h": 12, "left": 13]` (before: `m` and `h` both 11).
3. `aLeftNeighbourRightOfTheRightOneThrows`: `PositionTable(["left": 100, "right": 200])`;
   `#expect(throws: ControllerError.unresolvedNeighbor) { try table.placement(of: ["m"], leftNeighbor: "left", rightNeighbor: "right") }`;
   same with `["left": 100, "right": 100]` (a tie).
4. `aMissingClockCountsAsZero`: `PositionTable(["a": 50])`:
   `placement(of: ["m"], leftNeighbor: "a", rightNeighbor: PositionKey.clock)` → `["m": 25]`, and
   `placement(of: ["m"], leftNeighbor: PositionKey.clock, rightNeighbor: nil)` throws
   `.unresolvedNeighbor` (nothing can sit right of the clock). Before the fix the second call
   returned `["m": 35]`, left of `a`: the opposite end of the bar.
5. `iconsGetDistinctValuesInOrder`: `PositionTable(["left": 400, "right": 100])`,
   `placement(ofGroups: [["x0"], ["x1a", "x1b"]], leftNeighbor: "left", rightNeighbor: "right")` →
   `["x0": 300, "x1a": 200, "x1b": 200]`.
6. `groupingByValueSeparatesIconsAndKeepsAliases`:
   `PositionTable(["a::Item-0": 500, "a::Name": 500, "a::Item-1": 490])`
   `.groupedByValue(["a::Item-1", "a::Name", "a::Item-0", "a::New"])` →
   `[["a::Item-0", "a::Name"], ["a::Item-1"], ["a::New"]]`.

In `Tests/YeeHawCoreTests/MenuBarControllerTests.swift`, `// MARK: move` (model on
`aHiddenAppIsPlacedBetweenItsNeighboursBeforeItsDrawn`, lines 431-441):

7. `aMultiIconAppIsPlacedWithDistinctValuesInItsOwnOrder` (async throws): positions
   `"status:\(Self.a)::Item-0": 500, "status:\(Self.a)::Item-1": 490, "status:\(Self.b)::Item-0": 300, "status:\(Self.yeehaw)::Item-0": 100, PositionKey.clock: 0`,
   allow `[(Self.a, false), (Self.b, true), (Self.yeehaw, true)]`;
   `try await c.place(Self.a, leftNeighbor: FakeSystem.item(Self.b), rightNeighbor: FakeSystem.item(Self.yeehaw))`.
   With `let p = rig.system.positions`, `let first = try #require(p["status:\(Self.a)::Item-0"])`,
   `let second = try #require(p["status:\(Self.a)::Item-1"])`: expect
   `300 > first`, `first > second`, `second > 100`.
8. `nothingIsPlacedRightOfTheClock` (throws): positions `"status:\(Self.a)::Item-0": 200, PositionKey.clock: 0`;
   `#expect(throws: ControllerError.unresolvedNeighbor) { try c.move(FakeSystem.item(Self.a), leftNeighbor: FakeSystem.appleItem("com.apple.menuextra.clock"), rightNeighbor: nil) }`
   and `rig.system.positionWrites == 0`. Repeat with a table that has no clock key (expect the same).

Verification: `swift test 2>&1 | tail -n 3` → passed, 8 more tests than before this plan.

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, including the 8 new tests
- [ ] `grep -n "throws -> \[String: Double\]" Sources/YeeHawCore/PositionTable.swift` prints two lines
- [ ] `grep -n "groupedByValue" Sources/YeeHawCore/MenuBarController.swift` prints one line
- [ ] `git diff build/yeehaw-v1 -- Tests/YeeHawCoreTests/PositionTableTests.swift | grep "^-[^-]" | grep -v "placement(\|@Test func"` prints nothing (the only removed lines are signatures gaining `throws` and calls gaining `try`; no expected value changed)
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 008 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `placement`, `move`, `place` or `neighborKey` don't match the excerpts.
- Any existing `PositionTableTests` expectation would need a different value after Step 1. All 11
  are meant to pass unchanged; a change means the new maths differs from the old where it
  shouldn't.
- An existing `MenuBarControllerTests`, `LayoutModelEditTests` or `LayoutModelTests` test fails
  after Step 2 (for example one that expects all of an app's keys at one value).
- `placement(of:` has callers outside `MenuBarController.swift` and the tests
  (`grep -rn "placement(of" Sources`).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `.unresolvedNeighbor` now also means "the neighbours are the wrong way round". The Layout
  window's message ("macOS hasn’t saved a position for an icon there yet") is close enough for a
  rare case; give it its own error if it shows up in practice.
- Keys that were already tied by the old code (two icons of one app at one value) still group
  together, since a tie looks like aliases. They separate the next time macOS saves them apart.
- `beginReveal` still writes one value to all of an app's keys for the duration of a reveal; its
  originals are restored afterwards, so no lasting tie.
- Reviewers: check the tie-break (nearest the left neighbour) and that the cascade never moves
  `module:Clock` (it only moves values above `lower`, and `lower` is at least 0).
