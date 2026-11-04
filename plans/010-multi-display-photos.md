# Plan 010: Icon photos are right with several displays

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHawCore/ItemMatcher.swift Sources/YeeHaw/System/AXMenuBarReader.swift Sources/YeeHaw/System/IconImageProvider.swift Sources/YeeHaw/UI/StatusItemController.swift Tests/YeeHawCoreTests/GlyphProofTests.swift Tests/YeeHawCoreTests/ItemMatcherTests.swift Tests/YeeHawTests/IconImageProviderTests.swift`
>
> Changes from these plans are expected:
> - 002: `StatusItemController.swift`, in `RevealProblem`, `notice` and `select`. Neither 002 nor 003 changes the `reveal.onClosed` hookup, so it should still match the excerpt below.
> - 003: `IconImageProvider.swift` and `IconImageProviderTests.swift`.
> - 006, if done: `ItemMatcher.swift`, `AXMenuBarReader.swift` and `ItemMatcherTests.swift`, adding `pid`.
>
> Locate each excerpt below by its quoted text. If a quoted line can't be found in the live code, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: `plans/003-throttle-and-cancel-captures.md`. That plan adds the injectable `captureBars` and `permitted` seams, the `FakeBars` test helper and `attemptKey`, all of which this plan uses. If 006 is also done, this plan follows its `pid` pattern; 006 is not required.
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. It photographs other apps' menu bar icons so it can show them while they are hidden.

With more than one display, each display draws its own copy of the menu bar, and every copy of an item has the **same id**: `LayoutRules.deduplicated`'s comment says so, "One entry per item id, keeping the first (leftmost) of the copies other displays draw". Photo handling assumes one copy per id:
- **Proof is per id.** The ownership proof returns a set of ids, so a copy that was never proven is stored because another copy with the same id was. The last copy in x order is the one saved.
- **The bar is found by x only.** The bar a copy is cropped from is chosen by x alone. With displays stacked vertically (same x range), every copy is cropped from the top bar.
- **One failure loses every display.** If one bar window fails to capture, the whole pass throws and no display is photographed.

The owner's Mac has one display, so this is low impact today. It makes photos wrong as soon as a second display is attached.

## Current state

### Files

- `Sources/YeeHawCore/ItemMatcher.swift`:
  - `DrawnItem` (lines 1-12), what `MenuBarAgent` draws;
  - `MenuBarItem` (39-67);
  - `ItemMatcher.match` (91-127);
  - `ItemMatcher.photographable` (129-149), the ownership proof.
- `Sources/YeeHaw/System/AXMenuBarReader.swift`: `drawnItem` (lines 102-108) builds `DrawnItem`s from Accessibility frames, which are global, top-left origin, in points.
- `Sources/YeeHaw/System/IconImageProvider.swift`: `captureIfPermitted`, `captureSettled`, `widened(_:among:)`, `BarShot`, `bar(containing:)`, and the live shot. Plan 003 renamed the live shot to `liveCaptureBars()`.
- `Sources/YeeHaw/UI/StatusItemController.swift`: the reveal's `onClosed` hookup re-finds the revealed item by id before `captureSettled`.
- `Sources/YeeHaw/App/YeeHawApp.swift` (read only, do not edit): lines 66-70 wire `proveOwnership` to `ItemMatcher.photographable`. Its return type flows through, so it compiles unchanged after Step 2.

### Excerpts (495d26f line numbers; plan 003 has shifted the `IconImageProvider` ones)

`ItemMatcher.swift:1-12`:
```swift
public struct DrawnItem: Equatable, Sendable {
    public var x, width: Double
    public var label: String
    public var appleIdentifier: String?

    public init(x: Double, width: Double, label: String, appleIdentifier: String? = nil) {
```

`ItemMatcher.swift:134-149`:
```swift
    public static func photographable(_ items: [MenuBarItem], reread: [MenuBarItem],
                                      offApps: Set<BundleID>) -> Set<String> {
        func overlaps(_ a: MenuBarItem, _ b: MenuBarItem) -> Bool {
            min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > neighbourOverlap
        }
        func alone(_ item: MenuBarItem, in read: [MenuBarItem]) -> Bool {
            !read.contains { $0.id != item.id && overlaps($0, item) }
        }
        return Set(items.filter { item in
            guard let again = reread.first(where: { $0.id == item.id }),
                  abs(again.x - item.x) <= tolerance, abs(again.width - item.width) <= tolerance,
                  !item.contested, !again.contested,
                  !(item.bundleID.map(offApps.contains) ?? false) else { return false }
            return alone(item, in: items) && alone(again, in: reread)
        }.map(\.id))
    }
```
`reread.first(where: { $0.id == item.id })` always finds the first copy. A second display's copy is therefore compared with the first copy's frame and fails the proof. The first copy's id is in the set anyway, so the unproven copy is stored.

`AXMenuBarReader.swift:102-108`:
```swift
    private static func drawnItem(_ element: AXUIElement, appleIdentifier: String?) -> DrawnItem {
        let frame = frame(of: element)
        return DrawnItem(
            x: frame.minX, width: frame.width,
            label: string(element, kAXDescriptionAttribute) + string(element, kAXTitleAttribute),
            appleIdentifier: appleIdentifier)
    }
```

`IconImageProvider.swift:134-152` at 495d26f, the store loop in `captureIfPermitted`. Plan 003 kept this loop and added guards above it.
```swift
        let drawn = items.sorted { $0.x < $1.x }
        for item in targets {
            guard proven.contains(item.id) else {
                Self.log.info("Not keeping a photo of \(item.id, privacy: .public): it can't be proven to be its own")
                continue
            }
            let column = item.bundleID == nil ? Self.widened(item, among: drawn) : (x: item.x, width: item.width)
            guard let bar = Self.bar(containing: item, in: bars),
                  let crop = bar.crop(x: column.x, width: column.width),
                  // Blank or opaque shots (drawn but not rendered yet, or a solid background) are dropped.
                  let glyph = GlyphImage.make(from: crop, scale: bar.scale) else { continue }
            guard let id = item.bundleID else {
                appleCaptures[item.id] = glyph
                continue
            }
            let key = Self.cacheKey(bundleID: id, indexInApp: item.indexInApp)
            captures[key] = glyph
            store(crop, scale: bar.scale, key: key)
        }
```

`IconImageProvider.swift:174` (inside `captureSettled`): `guard barWrites() == writesBefore, await proveOwnership([item]).contains(item.id),`

`IconImageProvider.swift:209-215`:
```swift
    nonisolated static func widened(_ item: MenuBarItem, among drawn: [MenuBarItem]) -> (x: Double, width: Double) {
        let left = drawn.filter { $0.id != item.id && $0.x < item.x }.map { $0.x + $0.width }.max()
        let right = drawn.filter { $0.id != item.id && $0.x > item.x }.map(\.x).min()
```

`IconImageProvider.swift:311-315`:
```swift
    /// The bar whose x range holds the item, preferring the topmost (stacked displays share x).
    private static func bar(containing item: MenuBarItem, in bars: [BarShot]) -> BarShot? {
        bars.filter { $0.frame.minX - 0.5 <= item.x && item.x + item.width <= $0.frame.maxX + 0.5 }
            .min { $0.frame.minY < $1.frame.minY }
    }
```

`IconImageProvider.swift:326-337`, the per-window loop in the live shot (now `liveCaptureBars`). One `try` failing aborts every window.
```swift
        var shots: [BarShot] = []
        for window in windows {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            ...
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            shots.append(BarShot(frame: window.frame, image: image, scale: scale))
        }
        return shots
```
`BarShot.frame` is the `SCWindow.frame`: global, top-left origin, in points. This is the same space as Accessibility frames, so `item.y` compares directly with `frame.minY`.

`StatusItemController.swift:84-87` at 495d26f. Plans 002 and 003 leave this hookup unchanged, though its line numbers may shift. Find it by the `first { $0.id == item.id }` expression.
```swift
        reveal.onClosed = { [icons, controller] item in
            await controller.refresh()
            await icons.captureSettled(controller.items.first { $0.id == item.id } ?? item)
        }
```

### What plan 003 added (check that it is present)

- `IconImageProvider.init(directory:capturesScreen:permitted:captureBars:now:sleep:)`.
- `static func attemptKey(_ item: MenuBarItem) -> String`.
- In `Tests/YeeHawTests/IconImageProviderTests.swift`: a capture suite with `FakeBars`, `ShotFailed`, and `BarShot` fixtures built with the global `crop(width:height:ink:...)` helper. Several of its tests set `proveOwnership = { items in Set(items.map(\.id)) }`.

### Conventions

- New stored properties and init parameters go last, with defaults, so existing call sites compile unchanged. Plan 006 used this pattern for `pid`.
- YeeHawCore has no AppKit. Pure helpers live there and are tested in `Tests/YeeHawCoreTests`.
- Tests use Swift Testing (`@Test`, `#expect`, `#require`).
- Doc comments (`///`) explain *why*, in plain sentences. The exemplar is `Sources/YeeHaw/System/RevealCoordinator.swift` (lines 10-27).
- Never put personal names or a signing identity in code, comments or commits.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build app and tests | `swift build --build-tests 2>&1 \| tail -3` | ends with `Build complete!` |
| Warnings (clean) | `swift package clean && swift build --build-tests 2>&1 \| grep -c "warning:"` | `0` |
| One suite | `swift test --filter <SuiteName> 2>&1 \| tail -3` | `Test run with N tests ... passed` |
| All tests | `swift test 2>&1 \| grep -E "Test run with\|failed"` | one `... passed` line, no `failed` |

`grep -c` prints `0` and exits 1 when nothing matches. That is expected. Don't build the app bundle or launch YeeHaw unless asked.

## Scope

**In scope**:
- `Sources/YeeHawCore/ItemMatcher.swift`
- `Sources/YeeHaw/System/AXMenuBarReader.swift` (only `drawnItem`)
- `Sources/YeeHaw/System/IconImageProvider.swift`
- `Sources/YeeHaw/UI/StatusItemController.swift` (only the item lookup inside the `reveal.onClosed` hookup)
- `Tests/YeeHawCoreTests/GlyphProofTests.swift`
- `Tests/YeeHawCoreTests/ItemMatcherTests.swift`
- `Tests/YeeHawTests/IconImageProviderTests.swift`
- `plans/README.md` (this plan's row)

**Out of scope**:
- **The window filter `onScreenWindowsOnly: false` in `liveCaptureBars`.** Its comment explains that MenuBarAgent's bars aren't reported as on screen. Changing it needs a live multi-display check.
- **`LayoutRules.deduplicated` and the Layout window's one tile per id.** That is intended.
- **Making item ids unique per display.** Ids key photos, drafts and position matching.
- **The rate limit and cancellation added by 003.** Keep them exactly as they are.
- **`YeeHawApp.swift`.** It must compile unchanged.

## Git workflow

- Check `grep '^| 003' plans/README.md` shows `DONE`. If it doesn't, STOP.
- `git switch -c advisor/010-multi-display-photos`, then record `BASE=$(git rev-parse --short HEAD)`.
- One commit per step from Step 1 to Step 5. Use conventional commits, for example `fix: prove and store each display's copy of an icon on its own`.
- Every message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- Do NOT push or open a PR.

## Steps

### Step 0: Baseline

`swift test 2>&1 | grep -E "Test run with|failed"`. Note the total N.

**Verify**: there is one `passed` line and no `failed`. Also run `grep -n "func attemptKey\|captureBars: @escaping" Sources/YeeHaw/System/IconImageProvider.swift`, which should show 2 matches; if not, STOP, because 003 isn't in place.

### Step 1: Carry each copy's height (`y`)

In `ItemMatcher.swift`:
- `DrawnItem`: add `/// The item's top edge (global, top-left origin): each display draws its own copy of the bar, and stacked displays share x.` `public var y: Double`. Add the init parameter `y: Double = 0` last.
- `MenuBarItem`: add `/// The top edge of this copy's frame (global, top-left origin), telling apart the copies each display draws.` `public var y: Double`. Add the init parameter `y: Double = 0` last: after `pid` if plan 006 added it, else after `contested`.
- In `ItemMatcher.match`, pass `y: d.y` in all three `MenuBarItem(` constructions (Apple, matched extra, unknown).
- Add a slot type and accessor below `MenuBarItem`:
  ```swift
  /// One drawn copy of an item. Every display draws its own copy of the bar under the same id,
  /// so a photograph is proven and stored per copy, not per id.
  public struct ItemSlot: Hashable, Sendable {
      public var id: String
      public var x: Double
      public var y: Double
      public init(id: String, x: Double, y: Double) { self.id = id; self.x = x; self.y = y }
  }

  extension MenuBarItem {
      public var slot: ItemSlot { ItemSlot(id: id, x: x, y: y) }
  }
  ```

In `AXMenuBarReader.swift`'s `drawnItem`, pass `y: frame.minY` after `appleIdentifier: appleIdentifier`.

Test in `ItemMatcherTests.swift`:
1. `eachDrawnCopyKeepsItsHeight`: `DrawnItem(x: 100, width: 20, label: "A", y: -900)` matched to `AppExtra(bundleID: "com.example.a", indexInApp: 0, x: 100, width: 20)` gives `items[0].y == -900`. An Apple drawn item at `y: -900` also gives `y == -900`.

**Verify**: `swift test --filter ItemMatcherTests` passes, and the full suite gives N + 1. Commit.

### Step 2: Prove each copy on its own

Change `ItemMatcher.photographable` to return `Set<ItemSlot>`:
```swift
public static func photographable(_ items: [MenuBarItem], reread: [MenuBarItem],
                                  offApps: Set<BundleID>) -> Set<ItemSlot> {
    func sameBar(_ a: MenuBarItem, _ b: MenuBarItem) -> Bool { abs(a.y - b.y) <= tolerance }
    func overlaps(_ a: MenuBarItem, _ b: MenuBarItem) -> Bool {
        sameBar(a, b) && min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > neighbourOverlap
    }
    func alone(_ item: MenuBarItem, in read: [MenuBarItem]) -> Bool {
        !read.contains { $0.slot != item.slot && overlaps($0, item) }
    }
    return Set(items.filter { item in
        guard let again = reread.first(where: { $0.id == item.id && sameBar($0, item)
                                                && abs($0.x - item.x) <= tolerance }),
              abs(again.width - item.width) <= tolerance,
              !item.contested, !again.contested,
              !(item.bundleID.map(offApps.contains) ?? false) else { return false }
        return alone(item, in: items) && alone(again, in: reread)
    }.map(\.slot))
}
```
Update its doc comment: it returns the slots (copies) proven, one per drawn copy.

In `IconImageProvider.swift`:
- Change the property type to `var proveOwnership: @MainActor ([MenuBarItem]) async -> Set<ItemSlot> = { _ in [] }`, and update its comment.
- In `captureIfPermitted`, change `proven.contains(item.id)` to `proven.contains(item.slot)`.
- In `captureSettled`, change `.contains(item.id)` to `.contains(item.slot)`.

Update the existing tests that compare with ids:
- `GlyphProofTests.swift` lines 40, 56, 59-60 and 77: replace `[Self.digup.id, Self.fiddle.id]` with `[Self.digup.slot, Self.fiddle.slot]`, and likewise `[Self.digup.id]`, `[Self.fiddle.id, next.id]` and `[wifi.id]`. The `.isEmpty` checks stay.
- `IconImageProviderTests.swift` (003's capture suite): every `Set(items.map(\.id))` in a `proveOwnership` closure becomes `Set(items.map(\.slot))`. Find them with `grep -nF 'map(\.id))' Tests/YeeHawTests/IconImageProviderTests.swift`. After the edit, the same command prints nothing.

New tests in `GlyphProofTests.swift`:
2. `eachDisplaysCopyIsProvenOnItsOwn`:
   - copies are `left = Self.item("com.example.a", x: 100, width: 20)` and `right = Self.item("com.example.a", x: 1612, width: 20)`;
   - the reread has `left` and a moved copy of `right` (`x: 1650`);
   - expect `photographable([left, right], reread: [left, movedRight], offApps: []) == [left.slot]`.
3. `copiesOnStackedDisplaysDontOverlap`:
   - `a = Self.item("com.example.a", x: 100, width: 20)`;
   - `b` is `Self.item("com.example.b", x: 100, width: 20)` with `b.y = -900`;
   - expect `photographable([a, b], reread: [a, b], offApps: []) == [a.slot, b.slot]`. Without `sameBar` they would overlap and neither would be proven.

**Verify**:
- `swift build --build-tests` → `Build complete!`. `YeeHawApp.swift` must compile without edits.
- `swift test --filter "GlyphProofTests|IconImageProvider"` passes.
- The full suite gives N + 3.
- Commit.

### Step 3: Crop each copy from its own bar, and store one copy per photo

In `IconImageProvider.swift`:
1. `bar(containing:in:)` matches y as well as x. Keep the topmost preference only as a tie-break:
   ```swift
   /// The bar holding the item's copy: its x range and its height both, since stacked displays share x.
   static func bar(containing item: MenuBarItem, in bars: [BarShot]) -> BarShot? {
       bars.filter { $0.frame.minX - 0.5 <= item.x && item.x + item.width <= $0.frame.maxX + 0.5
                     && $0.frame.minY - 0.5 <= item.y && item.y <= $0.frame.maxY + 0.5 }
           .min { $0.frame.minY < $1.frame.minY }
   }
   ```
   Drop `private`, so tests can call it.
2. `widened(_:among:)` considers neighbours on the same bar only. Add `abs($0.y - item.y) <= ItemMatcher.tolerance &&` to both filters.
3. Add an ordering helper:
   ```swift
   /// Whether `bar` is the primary display's (its frame holds the global origin).
   nonisolated static func isPrimary(_ bar: BarShot) -> Bool {
       bar.frame.minX <= 0 && 0 < bar.frame.maxX && bar.frame.minY <= 0 && 0 < bar.frame.maxY
   }

   /// The order copies are tried in when several displays draw one item: the primary display's copy
   /// first, then left to right. The first that makes a usable glyph is kept, so one copy per photo
   /// is stored, and the choice doesn't depend on which display happens to be rightmost.
   static func photoOrder(_ items: [MenuBarItem], bars: [BarShot]) -> [MenuBarItem] {
       func rank(_ item: MenuBarItem) -> Int { bar(containing: item, in: bars).map(isPrimary) == true ? 0 : 1 }
       return items.sorted { (rank($0), $0.x) < (rank($1), $1.x) }
   }
   ```
4. In `captureIfPermitted`'s store loop, iterate `for item in Self.photoOrder(targets, bars: bars)`. Keep `var kept: Set<String> = []`, and skip with `guard !kept.contains(Self.attemptKey(item)) else { continue }` right after the proof check. After a glyph is stored (both the Apple branch and the third-party branch), `kept.insert(Self.attemptKey(item))`.

New tests in 003's capture suite in `IconImageProviderTests.swift`. Use the item `IconImageProviderTests.drawn("com.example.app", index: 2)` (x 60, width 20) and a copy of it with `x = 260`. Bars:
- primary: `BarShot(frame: CGRect(x: 0, y: 0, width: 200, height: 24), image: crop(width: 400, height: 48, ink: CGRect(x: 128, y: 10, width: 24, height: 28)), scale: 2)`.
- right display: `BarShot(frame: CGRect(x: 200, y: 0, width: 200, height: 24), image: crop(width: 400, height: 48, ink: CGRect(x: 128, y: 10, width: 12, height: 28)), scale: 2)`.
- upper display, stacked: frame `CGRect(x: 0, y: -900, width: 200, height: 24)`, blank image `crop(width: 400, height: 48, ink: .zero)`.

Tests:
4. `thePrimaryDisplaysCopyIsStored`: both copies proven, and bars are primary and right. `provider.image(for: "com.example.app", indexInApp: 2).size.width == 13`. That is the primary's 24 px of ink plus a pixel each side, at 2x. The right copy would give 7. Before this step, the rightmost copy won.
5. `anUnprovenCopyDoesntRideOnAProvenOne`:
   - Prove only the primary copy's slot, and make the primary bar blank (`ink: .zero`).
   - Expect no file for the cache key. Before Step 2, the right copy was stored.
6. `aCopyIsCroppedFromItsOwnStackedBar`:
   - Bars are upper (blank) and primary; one item at y 0; prove all.
   - Expect the file exists. Before this step, the upper bar was used, and nothing was stored.

Test in `AppleCropTests`:
7. `widenedIgnoresAnotherDisplaysItems`:
   - A clock at x 1908, width 127.5, y 0.
   - A neighbour `Self.item("cc", x: 1866, width: 26)` with `y = -900`.
   - Expect `column.x == 1904` and `column.width == 127.5 + 8`. The neighbour is on another bar, so the full slack applies on both sides.

**Verify**: `swift test --filter "IconImageProvider|AppleCrop"` passes, and the full suite gives N + 7. Commit.

### Step 4: One bar's failure doesn't cost the others

In `IconImageProvider.swift`:
1. Add a pure helper:
   ```swift
   /// The shots that worked. One bar window that can't be captured (a display going to sleep, a
   /// bar being torn down) no longer costs every display its photos; only when every window
   /// failed is the first error thrown, so the caller logs it as before.
   nonisolated static func keptShots(_ results: [Result<BarShot, Error>]) throws -> [BarShot] {
       let shots = results.compactMap { try? $0.get() }
       if shots.isEmpty, case .failure(let error)? = results.first(where: { (try? $0.get()) == nil }) { throw error }
       return shots
   }
   ```
   You may write the body more plainly if it reads better; keep the behaviour.
2. In `liveCaptureBars`, collect `var results: [Result<BarShot, Error>] = []`. Put each window's capture in `do { ...; results.append(.success(BarShot(...))) } catch { results.append(.failure(error)) }`, and end with `return try keptShots(results)`. Don't change the window filter or the stream configuration.

Tests in `IconImageProviderTests.swift` (003's capture suite):
8. `aFailedBarKeepsTheOthers`:
   - `keptShots([.success(primary), .failure(ShotFailed())]).count == 1`;
   - `#expect(throws: ShotFailed.self) { try IconImageProvider.keptShots([.failure(ShotFailed())]) }`;
   - `keptShots([]).isEmpty`.

**Verify**: the suite passes, and the full suite gives N + 8. `grep -n "try await SCScreenshotManager.captureImage" Sources/YeeHaw/System/IconImageProvider.swift` → the one match sits inside a `do {` block. Commit.

### Step 5: The settled photo uses the revealed copy

In `ItemMatcher.swift`, add:
```swift
/// The copy of `item` in a fresh read that is the same drawn copy: same id, same bar (y), nearest
/// in x. A re-read can widen an icon (an app drawing a different glyph), so x isn't matched exactly.
public static func sameCopy(of item: MenuBarItem, in read: [MenuBarItem]) -> MenuBarItem? {
    read.filter { $0.id == item.id && abs($0.y - item.y) <= tolerance }
        .min { abs($0.x - item.x) < abs($1.x - item.x) }
}
```

In `StatusItemController.swift`'s `reveal.onClosed` hookup, replace `controller.items.first { $0.id == item.id } ?? item` with `ItemMatcher.sameCopy(of: item, in: controller.items) ?? item`. Change nothing else in that closure or file.

Tests in `ItemMatcherTests.swift`:
9. `theSameCopyIsTheNearestOnTheSameBar`:
   - read is `[x 60 y 0, x 1572 y 0, x 62 y -900]`, all with id `com.example.a#0`;
   - the item is at x 61, y 0;
   - the result is the x 60 copy;
   - an item whose id appears nowhere returns `nil`.

**Verify**:
- `swift test --filter ItemMatcherTests` passes, and the full suite gives N + 9.
- `grep -n "first { \$0.id == item.id }" Sources/YeeHaw/UI/StatusItemController.swift` → no output.
- Commit.

### Step 6: Final checks

- `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` → `0`
- `swift test 2>&1 | grep -E "Test run with|failed"` → N + 9, passed.
- `git diff --stat $BASE..HEAD` → only in-scope files. `YeeHawApp.swift` must not be listed.

Set row 010 in `plans/README.md` to `DONE`.

## Test plan

- Core:
  - `ItemMatcherTests`: 2 new (y carried; same copy).
  - `GlyphProofTests`: 2 new (per-copy proof; stacked copies don't overlap), plus 5 assertions moved from ids to slots.
- App, in `IconImageProviderTests.swift`:
  - 3 capture tests (primary preferred, no riding, stacked crop);
  - 1 `AppleCropTests` (widening per bar);
  - 1 `keptShots` test;
  - 003's tests updated to prove slots.
- Patterns: 003's capture suite (`FakeBars`, `BarShot` fixtures from `crop(...)`), and `GlyphProofTests` for pure proofs.
- Verification: `swift test` → baseline + 9, all pass.

## Done criteria

- [ ] `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` prints `0`
- [ ] `swift test` passes with the Step 0 baseline + 9
- [ ] `grep -n "Set<ItemSlot>" Sources/YeeHawCore/ItemMatcher.swift Sources/YeeHaw/System/IconImageProvider.swift` → at least 2 matches
- [ ] `grep -n "proven.contains(item.id)\|contains(item.id)" Sources/YeeHaw/System/IconImageProvider.swift` → no output
- [ ] `grep -rn "func keptShots\|func photoOrder\|func sameCopy" Sources` → 3 matches
- [ ] `git diff --stat $BASE..HEAD` lists only in-scope files
- [ ] `plans/README.md` row 010 is `DONE`

## STOP conditions

Stop and report back (do not improvise) if:

- 003 is not `DONE`, or `IconImageProvider` lacks the `captureBars` init seam or `attemptKey`.
- `proveOwnership` already returns something other than `Set<String>`.
- `YeeHawApp.swift` stops compiling after Step 2. Its `proveOwnership` closure should infer the new type. Editing it is out of scope, so report instead.
- The `reveal.onClosed` hookup no longer looks up the revealed item in `controller.items`. Plan 002 changed how the settled photo is chosen, and Step 5 needs a new home.
- An existing test outside `GlyphProofTests` and 003's capture suite fails because of the new `y` in `MenuBarItem`'s `Equatable`.
- Test 4 can't tell the copies apart because `GlyphImage.make` rejects the 12-px-wide ink. Report it; don't loosen `GlyphImage` thresholds.

## Maintenance notes

- **Unverified on real hardware.** The owner's Mac has one display. Whether 27.2 draws inactive displays' bars dimmed, and which copy looks truest, is not known. The primary-first order with fallback is a deterministic default. If a second display shows dim photos, change `photoOrder`, for example to prefer the display holding YeeHaw's own icon.
- **Ids of third-party copies.** Whether third-party items on a second display get the same id as on the first (duplicate extras) or come back as `unknown@x` is unverified. Slots make the photo code correct either way.
- **A follow-up for later.** `liveCaptureBars` still includes off-screen bar windows. If several windows share a frame (other Spaces, full screen), `bar(containing:)` picks the first. Dedupe by frame, preferring `isOnScreen`, once it can be checked live.
- **What reviewers should check.** `kept` is keyed by `attemptKey`, so an Apple item and a third-party item never share a key. `photoOrder` must be a stable, total order.
