# Plan 007: The Layout draft shows untouched icons in the bar's real order, and is dirty only when Apply has work

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHawCore/LayoutDraft.swift Tests/YeeHawCoreTests/LayoutDraftTests.swift`
> Expected: no output. If either file changed since this plan was written,
> compare the "Current state" excerpts against the live code before
> proceeding. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. Its Layout window edits a draft of the menu bar
(`LayoutDraft`, pure logic in the YeeHawCore target) and Apply writes the difference. When the real
bar changes while a draft is open (the user Command-drags icons, an app relaunches), the window
re-reads the bar and calls `LayoutDraft.reconcile`. Today reconcile keeps the draft's old order for
icons the user never touched, but `changes()` assumes those icons are already in real order and
never moves them. So the window shows one arrangement, Apply writes another, and the post-Apply
check (which looks only at moved icons' neighbours) reports success. The same mismatch can leave
`isDirty` true with no changes at all, which gives an empty footer summary and a close sheet whose
text is just ".". After this plan the draft always shows untouched icons where they really are,
and `isDirty` means exactly "Apply has something to write".

## Current state

- `Sources/YeeHawCore/LayoutDraft.swift`: `LayoutChanges` (what Apply writes) and `LayoutDraft`
  (the draft, its edits, `reconcile`, `changes`). No UI imports; fully unit-tested.
- `Tests/YeeHawCoreTests/LayoutDraftTests.swift`: its tests (Swift Testing).
- Callers (do not change them): `Sources/YeeHaw/UI/LayoutModel.swift:150-154` reconciles a dirty
  draft and replaces a clean one; `LayoutModel.swift:125` uses `draft.isDirty`.

The draft's state and `isDirty` today:

```swift
// LayoutDraft.swift:59-77
public struct LayoutDraft: Equatable, Sendable {
    /// The bar (left to right, hidden apps' items left out) and the strip order, as they really are.
    public private(set) var realBar: [MenuBarItem]
    public private(set) var realHidden: [BundleID]
    public private(set) var bar: [MenuBarItem]
    public private(set) var hidden: [BundleID]
    /// Items the user moved (or put back by showing their app), whose place may need writing.
    private var touched: Set<String> = []
    ...
    /// Whether the draft differs from the real rows. Moving an icon and moving it back, or hiding
    /// an app and showing it in its old place, leaves it clean.
    public var isDirty: Bool { bar.map(\.id) != realBar.map(\.id) || hidden != realHidden }
```

`reconcile` keeps the draft's order for every item still drawn (line 128-131) and inserts newly
drawn items after their nearest real left neighbour (lines 137-142):

```swift
// LayoutDraft.swift:124-148
    public mutating func reconcile(bar newBar: [MenuBarItem], hidden newHidden: [BundleID]) {
        let fresh = Dictionary(newBar.map { ($0.id, $0) }) { first, _ in first }
        let wasHidden = realHidden
        // Placeholders stay while their app is still really hidden; real items while still drawn.
        var draftBar = bar.compactMap { item -> MenuBarItem? in
            if isPlaceholder(item) { return newHidden.contains(item.bundleID ?? "") ? item : nil }
            return fresh[item.id]
        }
        var draftHidden = hidden.filter { newHidden.contains($0) || !wasHidden.contains($0) }
        for id in newHidden where !wasHidden.contains(id) && !draftHidden.contains(id) {
            draftHidden.append(id)
            draftBar.removeAll { $0.bundleID == id }
        }
        for (index, item) in newBar.enumerated() where !draftBar.contains(where: { $0.id == item.id }) {
            guard !(item.bundleID.map(draftHidden.contains) ?? false) else { continue }
            let before = newBar[..<index].last { earlier in draftBar.contains { $0.id == earlier.id } }
            let slot = before.flatMap { earlier in draftBar.firstIndex { $0.id == earlier.id } }.map { $0 + 1 } ?? 0
            draftBar.insert(item, at: slot)
        }
        realBar = newBar
        realHidden = newHidden
        bar = draftBar
        hidden = draftHidden
        touched.formIntersection(draftBar.map(\.id))
    }
```

`changes()` treats untouched items as staying put, on the assumption stated in its comment:

```swift
// LayoutDraft.swift:159-163
        // Items moved relative to the rest. Moving an item never reorders the others, so the
        // untouched ones keep their real order; a touched one that still fits that order (moved
        // back, or passed by another) needs no move of its own.
        let realIndex = Dictionary(realBar.enumerated().map { ($1.id, $0) }) { first, _ in first }
        var staying = Set(bar.filter { !touched.contains($0.id) && realIndex[$0.id] != nil }.map(\.id))
```

That assumption holds after edits, but not after `reconcile`, which is the bug.

Placeholders (tiles of a hidden app being shown) are never in `newBar` (they aren't drawn) and are
always in `touched` (`show` adds them, line 105).

Conventions:
- Doc comments (`///`) explain why, in plain sentences; this file's own comments are the exemplar
  (and `Sources/YeeHaw/System/RevealCoordinator.swift` for the house style).
- Tests: Swift Testing. Helpers in `LayoutDraftTests`: `Self.item("E")`, `Self.placeholder("H")`,
  `Self.a ... Self.d`, `Self.draft(_:hidden:)` (lines 5-22). Model new tests on
  `reconcilingDropsAVanishedIconAndKeepsTheOtherEdits` (lines 154-166).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter LayoutDraftTests 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| Layout model tests | `swift test --filter "LayoutModelTests\|LayoutModelEditTests" 2>&1 \| tail -n 3` | passed |
| All tests | `swift test 2>&1 \| tail -n 3` | passed, no failures |

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHawCore/LayoutDraft.swift`
- `Tests/YeeHawCoreTests/LayoutDraftTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `Sources/YeeHaw/UI/LayoutModel.swift` and `LayoutWindow.swift`: they call `reconcile` and
  `isDirty` correctly; with the draft fixed, their post-Apply neighbour check is adequate.
- `changes()`, `neighbours(of:)`, `summary`: their logic is right once the draft holds untouched
  items in real order. Don't "fix" them.

## Git workflow

- From `build/yeehaw-v1`: `git checkout -b advisor/007-draft-reconcile-keeps-real-order`
- Conventional commits, one per step, e.g.
  `fix: show untouched icons in their real order after the bar changes under a Layout draft`.
  End every message with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No personal names. Do NOT push or open a PR.

## Steps

### Step 1: Write the failing tests first

Add to `Tests/YeeHawCoreTests/LayoutDraftTests.swift`, in the `// MARK: The bar changing underneath`
section, the tests 1-3 from the Test plan.

**Verify**: `swift test --filter LayoutDraftTests 2>&1 | grep -E "✘|failed" | head` → shows that
`reconcilingPutsUntouchedIconsInTheBarsNewOrder` and `aDraftWhoseOnlyChangeHappenedForRealIsClean`
fail (the third may already pass). Every pre-existing LayoutDraftTests test still passes.

### Step 2: Re-sort untouched items in `reconcile`

In `LayoutDraft.reconcile`, after the newly-drawn insertion loop (after line 142, before
`realBar = newBar`), add:

```swift
        // Untouched items follow the bar's latest order: the user never placed them, so the draft
        // shows them where they really are, and `changes()` can leave them alone. Touched items and
        // placeholders keep their slots, which is where the user put them.
        let newIndex = Dictionary(newBar.enumerated().map { ($1.id, $0) }) { first, _ in first }
        let slots = draftBar.indices.filter { !touched.contains(draftBar[$0].id) && newIndex[draftBar[$0].id] != nil }
        let inRealOrder = slots.map { draftBar[$0] }.sorted { (newIndex[$0.id] ?? 0) < (newIndex[$1.id] ?? 0) }
        for (slot, item) in zip(slots, inRealOrder) { draftBar[slot] = item }
```

Update the doc comment above `reconcile` (lines 119-123): after "items still drawn take their latest
reading", say that untouched items also take the bar's latest order, while the user's moved items
keep their places.

Also update the comment in `changes()` (lines 159-161) so it says the untouched items are in real
order "after an edit and after `reconcile`".

**Verify**:
- `swift test --filter LayoutDraftTests 2>&1 | tail -n 3` → passed (old and new tests)
- `swift test --filter "LayoutModelTests|LayoutModelEditTests" 2>&1 | tail -n 3` → passed

### Step 3: `isDirty` is exactly "Apply has changes"

Replace `isDirty` (lines 75-77) with:

```swift
    /// Whether Apply has anything to write. Moving an icon and moving it back, or hiding an app
    /// and showing it in its old place, leaves it clean; so does an edit the bar has since made
    /// for real. Defined by `changes()`, so a dirty draft always has a summary to show.
    public var isDirty: Bool { !changes().isEmpty }
```

`changes()` uses its default `anchors`; which items can anchor only picks neighbours, never whether
a change exists, so the default is fine.

**Verify**:
- `swift test --filter LayoutDraftTests 2>&1 | tail -n 3` → passed
- `swift test 2>&1 | tail -n 3` → passed
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output

## Test plan

All in `Tests/YeeHawCoreTests/LayoutDraftTests.swift`:

1. `reconcilingPutsUntouchedIconsInTheBarsNewOrder`:
   `var draft = Self.draft()` (bar A B C D); `draft.move(from: 0, to: 4)` → `[B, C, D, A]`.
   B and C are swapped outside YeeHaw: `draft.reconcile(bar: [Self.a, Self.c, Self.b, Self.d], hidden: [])`.
   Expect `draft.bar == [Self.c, Self.b, Self.d, Self.a]` (before the fix: `[B, C, D, A]`), and
   `draft.changes().moves == [.init(item: Self.a, left: Self.d, right: nil)]`.
2. `aDraftWhoseOnlyChangeHappenedForRealIsClean`:
   `var draft = Self.draft()`; `draft.hide("B", at: 0)` → bar `[A, C, D]`, hidden `["B"]`.
   B is hidden for real (by the strip) and C and D swapped:
   `draft.reconcile(bar: [Self.a, Self.d, Self.c], hidden: ["B"])`.
   Expect `draft.bar == [Self.a, Self.d, Self.c]`, `draft.changes().isEmpty`, `!draft.isDirty`.
3. `aMovedIconKeepsItsPlaceWhileOthersFollowTheBar`:
   `var draft = Self.draft()`; `draft.move(from: 3, to: 1)` → `[A, D, B, C]`.
   Outside, C moves to the far left: `draft.reconcile(bar: [Self.c, Self.a, Self.b, Self.d], hidden: [])`.
   Untouched slots 0, 2, 3 (A, B, C) take the new real order C, A, B; D stays in slot 1.
   Expect `draft.bar == [Self.c, Self.d, Self.a, Self.b]`.
4. `isDirtyIsExactlyWhetherThereAreChanges`: build these drafts and for each
   `#expect(draft.isDirty == !draft.changes().isEmpty)`:
   a fresh `Self.draft()`; after `move(from: 0, to: 3)`; after moving it back
   (`move(from: 2, to: 0)`); `Self.draft(hidden: ["H"])` after
   `show("H", placeholders: [Self.placeholder("H")], at: 1)`; and the drafts from tests 1 and 2
   after their reconciles.

Existing tests must pass unchanged, in particular
`reconcilingDropsAVanishedIconAndKeepsTheOtherEdits` (its expected `[D, E, A]` already has the
untouched D and E in real order).

Verification: `swift test --filter LayoutDraftTests 2>&1 | tail -n 3` → passed, 4 more tests than before.

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, including the 4 new tests
- [ ] `grep -n "public var isDirty: Bool { !changes().isEmpty }" Sources/YeeHawCore/LayoutDraft.swift` prints one line
- [ ] `git diff --stat build/yeehaw-v1 -- Sources/YeeHaw` prints nothing (no app-target change)
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 007 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `reconcile`, `isDirty` or `changes()` don't match the excerpts.
- An existing `LayoutDraftTests`, `LayoutModelTests` or `LayoutModelEditTests` test fails after
  Step 2 or 3 and passing it would mean changing its expected value. That would mean a caller
  relies on the old order; report which test and why.
- Test 1 still fails after Step 2 (the re-sort didn't take effect, so the cause is elsewhere).
- The fix seems to need a change outside `LayoutDraft.swift`.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `isDirty` now runs `changes()`, which is roughly O(touched × bar). With a few dozen items that's
  negligible; if the draft ever holds hundreds, cache it.
- The invariant `changes()` relies on is now stated in two places: edits never reorder untouched
  items, and `reconcile` re-sorts them. Any new edit or reconcile path must keep untouched items
  in real relative order.
- Reviewers: check that placeholders can't be re-sorted (they're never in `newBar`, so
  `newIndex` excludes them), and that the re-sort runs after new items are inserted.
- Deferred: the post-Apply check in `LayoutModel` still only checks moved items' neighbours.
  With this fix the draft and the bar agree on untouched items, so a wider check isn't needed now.
