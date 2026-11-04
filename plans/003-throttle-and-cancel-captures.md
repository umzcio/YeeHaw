# Plan 003: Screen captures are rate-limited, cancellable and covered by tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report; do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/System/IconImageProvider.swift Sources/YeeHaw/UI/StripColorSampler.swift Sources/YeeHaw/UI/StripPanel.swift Sources/YeeHaw/UI/LayoutModel.swift Sources/YeeHaw/UI/StatusItemController.swift Tests/YeeHawTests/IconImageProviderTests.swift Tests/YeeHawTests/StripColorTests.swift`
>
> Plan 002 is expected to have changed `StatusItemController.swift`, in `RevealProblem`, `notice` and the `switch` in `select`. 002 leaves the `reveal.onClosed` / `beforePress` hookup (lines 80-88) and `openStrip` untouched; that is the part this plan relies on. Every other file in the list should show no change. If any other listed file changed, compare the "Current state" excerpts below against the live code. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: `plans/002-reveal-never-switches-off-under-a-panel.md`
- **Category**: perf + tests
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw is a macOS 27.2 menu bar manager. It photographs other apps' menu bar icons with ScreenCaptureKit (SCK) so it can show them while they are hidden. It also samples the menu bar's colour with SCK so its "strip" panel matches the bar.

Every SCK capture makes macOS show its screen-recording indicator in the menu bar, and that re-lays out the bar's icons. Today captures run with no throttle:
- Every strip open re-reads the bar and photographs every drawn item, although the strip never shows drawn items.
- Every strip open samples the bar colour: an `SCShareableContent` query plus two band shots.
- Every Space, appearance or display change samples every display, even while the strip is closed.
- Every Layout window refresh photographs again.

Cancelling the strip's refresh task doesn't stop its capture. A cancelled settle sequence fires its remaining shots back to back, because the sleep's cancellation error is swallowed (`try?`).

After this plan:
- Photos are taken only when an item is due: missing, or older than a set age.
- A second capture pass never overlaps one in flight.
- A cancelled pass stops before its next shot.
- The bar colour is sampled lazily (when a strip or Layout window needs it) and at most every 5 minutes unless something that changes the colour happened.
- The capture orchestration in `IconImageProvider` gets tests. Today it has none, because the capture function and the permission check are hard-wired.

## Current state

### Files

- `Sources/YeeHaw/System/IconImageProvider.swift`: photographs menu bar items and caches the glyphs in memory and in `~/Library/Application Support/YeeHaw/Glyphs`. Holds `captureIfPermitted` (lines 108-153), `captureSettled` (155-187) and the SCK shot `captureBars` (317-339).
- `Sources/YeeHaw/UI/StripColorSampler.swift`: samples the bar colour per display. It already has injectable `permitted` and `capture` closures, which are the pattern to copy.
- `Sources/YeeHaw/UI/StripPanel.swift`: the strip panel. It resamples on show (lines 234-261) and on system notifications (267-305).
- `Sources/YeeHaw/UI/StatusItemController.swift`: YeeHaw's status item. `openStrip` (211-232) starts a refresh-and-capture task on every strip open.
- `Sources/YeeHaw/UI/LayoutModel.swift`: the Layout window's model. `refresh()` (185-207) captures on every refresh.
- `Sources/YeeHaw/App/YeeHawApp.swift` (read only, do not edit): lines 64-70 construct the one `IconImageProvider` and set `barWrites` and `proveOwnership`.
- `Tests/YeeHawTests/IconImageProviderTests.swift`: has `GlyphImageTests`, `IconImageProviderTests` and `AppleCropTests`, but nothing for capture.
- `Tests/YeeHawTests/StripColorTests.swift`: `StripColorSamplerTests` (lines 153-195) with the `ScriptedCapture` helper (lines 127-148).

### Excerpts at 495d26f

`IconImageProvider.swift:26-41`, the existing seams and init:
```swift
    /// Whether `captureIfPermitted` photographs at all; off in tests, which have no menu bar.
    private let capturesScreen: Bool
    /// Counts YeeHaw's own writes to the bar (`MenuBarController.writeCount`). ...
    var barWrites: @MainActor () -> Int = { 0 }
    /// Re-reads the bar once a shot is taken and says which of the items it was taken for can be
    /// stored as their own (`ItemMatcher.photographable`). ...
    var proveOwnership: @MainActor ([MenuBarItem]) async -> Set<String> = { _ in [] }

    init(directory: URL = IconImageProvider.defaultDirectory, capturesScreen: Bool = true) {
        self.directory = directory
        self.capturesScreen = capturesScreen
    }
```

`IconImageProvider.swift:112-133`, the start of `captureIfPermitted`:
```swift
    func captureIfPermitted(_ items: [MenuBarItem]) async {
        guard capturesScreen, CGPreflightScreenCaptureAccess() else { return }
        let targets = items.filter {
            ($0.bundleID != nil && $0.bundleID != OwnIconLocator.bundleID) || $0.appleIdentifier != nil
        }
        guard !targets.isEmpty else { return }
        let writesBefore = barWrites()
        let bars: [BarShot]
        do {
            bars = try await Self.captureBars()
        } catch {
            Self.log.error("Menu bar capture failed: \(error, privacy: .public)")
            return
        }
        // The bar is read again after the shot: ...
        let proven = await proveOwnership(items)
        guard barWrites() == writesBefore else {
            Self.log.info("Menu bar capture dropped: the bar changed while it was taken")
            return
        }
```
It then loops over `targets` (lines 134-152): it keeps proven ones, crops and stores them (`captures[key]` plus a PNG via `store`), and puts Apple items in `appleCaptures`.

`IconImageProvider.swift:164-172`, `captureSettled`:
```swift
    func captureSettled(_ item: MenuBarItem) async {
        guard capturesScreen, CGPreflightScreenCaptureAccess(), let id = item.bundleID,
              id != OwnIconLocator.bundleID else { return }
        let writesBefore = barWrites()
        var last: (crop: CGImage, scale: CGFloat, pixels: Data)?
        for shot in 0..<Self.settleShots {
            if shot > 0 { try? await Task.sleep(for: Self.settleInterval) }
            guard let bars = try? await Self.captureBars(), let bar = Self.bar(containing: item, in: bars),
                  let crop = bar.crop(x: item.x, width: item.width), let pixels = Self.pixels(crop) else { return }
```

`IconImageProvider.swift:317-321`, the live shot:
```swift
    /// `MenuBarAgent`'s bar windows aren't reported as on screen ...
    @concurrent
    private static func captureBars() async throws -> [BarShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
```
`BarShot` (lines 297-309) is `struct BarShot: @unchecked Sendable { let frame: CGRect; let image: CGImage; let scale: CGFloat }` with `func crop(x:width:) -> CGImage?`.

`StatusItemController.swift:220-231`, inside `openStrip`:
```swift
        // Re-read the bar in the background: YeeHaw's icon may have moved, and drawn items get
        // fresh photographs. The strip itself opens at once from the saved state.
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await controller.refresh()
            if let drawn = OwnIconLocator.drawn(in: controller.items) {
                yeehawItem = drawn
                ownIconMissing = false
            }
            await icons.captureIfPermitted(controller.items)
        }
```

`StatusItemController.swift:84-87`, the reveal's photo hookup. **Do not edit it.** Plan 002 keeps it as it is and skips calling `onClosed` from `RevealCoordinator.run` when a reveal closed because of a click outside (`Close.skipsPhoto`). That skip must keep working, and it does, because this plan only changes what happens inside `captureSettled`.
```swift
        reveal.onClosed = { [icons, controller] item in
            await controller.refresh()
            await icons.captureSettled(controller.items.first { $0.id == item.id } ?? item)
        }
```

`LayoutModel.swift:195-198`, inside `refresh()`:
```swift
            refreshPending = false
            await controller.refresh()
            await images.captureIfPermitted(controller.items)
            await sampleBarColour()
```

`StripColorSampler.swift:37-51` and `63-77`:
```swift
    private let permitted: @MainActor () -> Bool
    private let capture: Capture
    private var cache: [CGDirectDisplayID: StripRGB] = [:]
    /// The number of the last sample started, and the newest one whose result was kept, per display.
    private var started: [CGDirectDisplayID: Int] = [:]
    private var applied: [CGDirectDisplayID: Int] = [:]
    ...
    init(permitted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         capture: @escaping Capture = { display, height in await StripColorSampler.screenCapture(display: display, barHeight: height) }) {
        self.permitted = permitted
        self.capture = capture
    }
    ...
    func sample(display: CGDirectDisplayID, barHeight: CGFloat) async -> Outcome {
        guard permitted() else {
            cache[display] = nil
            applied[display] = started[display] // A capture still in flight is stale now.
            return .noPermission
        }
        let number = (started[display] ?? 0) + 1
        started[display] = number
        let outcome = await capture(display, barHeight)
        if case .sampled(let color) = outcome, number > applied[display] ?? 0 {
            applied[display] = number
            cache[display] = color
        }
        return outcome
    }
```

`StripPanel.swift:37-38` and `282-305`:
```swift
    /// How long after a Space switch to resample, so the new Space's wallpaper is on screen.
    static let spaceSettle: Duration = .milliseconds(600)
    ...
    private func watchForResampling() {
        resampleAllScreens()
        resampleTriggers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resampleAllScreens() }
        })
        resampleTriggers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.spaceSettle)
                self?.resampleAllScreens()
            }
        })
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isShown { paint(currentFill(), animated: true) }
                resampleAllScreens()
            }
        }
    }
```
While the strip is shown, a Space change or display change already dismisses it (`StripPanel.swift:392-399`), so those two triggers never need to recolour a shown strip.

### Conventions

- Swift 6 language mode, SwiftPM, macOS 27.2. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`), not XCTest.
- Seams are init parameters with live defaults. Copy `StripColorSampler.init(permitted:capture:)` (lines 47-51).
- Doc comments (`///`) explain *why*, in plain sentences, one idea per sentence. The exemplar is `Sources/YeeHaw/System/RevealCoordinator.swift` (for example lines 10-27). Match it. Don't write comments that only restate the code.
- Never put personal names or a signing identity in code, comments or commits.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build app and tests | `swift build --build-tests 2>&1 \| tail -3` | ends with `Build complete!` |
| Warnings (clean) | `swift package clean && swift build --build-tests 2>&1 \| grep -c "warning:"` | `0` |
| One suite | `swift test --filter IconImageProviderTests 2>&1 \| tail -5` | a line `Test run with N tests ... passed` |
| All tests | `swift test 2>&1 \| grep -E "Test run with\|failed"` | one line `Test run with N tests in M suites passed ...`, no `failed` |

Notes:
- `grep -c` prints `0` and exits 1 when nothing matches. That is the expected result.
- Incremental builds only show warnings for recompiled files. Use the clean warnings command at the end.
- Don't run `scripts/build-app.sh` or launch the app unless the operator asks.

## Suggested executor toolkit

- If available, invoke `superpowers:test-driven-development` for Steps 3-5. Write each new test first and watch it fail before changing the code.

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHaw/System/IconImageProvider.swift`
- `Sources/YeeHaw/UI/StripColorSampler.swift`
- `Sources/YeeHaw/UI/StripPanel.swift` (only `spaceSettle` and `watchForResampling`)
- `Sources/YeeHaw/UI/LayoutModel.swift` (only the `captureIfPermitted` call in `refresh()`)
- `Sources/YeeHaw/UI/StatusItemController.swift` (only the two-line comment in `openStrip`)
- `Tests/YeeHawTests/IconImageProviderTests.swift`
- `Tests/YeeHawTests/StripColorTests.swift`
- `plans/README.md` (this plan's status row only)

**Out of scope** (do NOT touch):
- `reveal.onClosed` and `reveal.beforePress` in `StatusItemController.swift`. Plan 002 relies on them staying as they are, and its rule that `onClosed` is skipped after an outside click lives in `RevealCoordinator.run`.
- `Sources/YeeHaw/System/RevealCoordinator.swift`. Plan 002 rewrote it.
- `ItemMatcher.photographable`, `bar(containing:)` and per-display handling in `captureBars`. Plan 010 changes those and builds on the seams this plan adds.
- `StatusItemController.captureHiddenBeforeLaunch` and `start(grants:)`. They run once at launch, and the rate limit inside `captureIfPermitted` covers them.
- `Sources/YeeHaw/App/YeeHawApp.swift`. The live defaults keep its wiring unchanged.
- Any change to `captureSettled`'s signature, `func captureSettled(_ item: MenuBarItem) async`. Plan 002's hookup calls it.

## Git workflow

- Check that plan 002 has landed: `grep '^| 002' plans/README.md` shows `DONE`. If it doesn't, STOP.
- Branch from the commit where 002 is applied: `git switch -c advisor/003-throttle-and-cancel-captures`.
- Commit after Steps 2, 4, 5 and 6. Use conventional commits with a short body, ending with the attribution line. Example from `git log`: `feat: photograph a revealed icon as its menu closes, once it holds still`. For this plan:
  - `test: make icon capture injectable and characterize it`
  - `perf: rate-limit icon photos and stop cancelled captures`
  - `perf: sample the bar colour lazily, at most every five minutes`
  - `docs: say when strip opens photograph icons`
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  ```
- Do NOT push or open a PR.

## Steps

### Step 0: Record the baseline

1. Run `git rev-parse --short HEAD` and write the result down as BASE. This is the commit you branched from, with plan 002 applied.
2. Run `swift test 2>&1 | grep -E "Test run with|failed"` and write down N (the total test count).

**Verify**: the output is one `Test run with N tests in M suites passed` line, with no `failed`. If tests already fail, STOP.

### Step 1: Make capture, permission, clock and sleep injectable (no behaviour change)

In `IconImageProvider.swift`:

1. Rename `private static func captureBars()` (line 320) to `static func liveCaptureBars()`. Keep `@concurrent` and its doc comment. It must no longer be `private`, because the default argument below refers to it.
2. Add stored seams below `capturesScreen` (after line 27). Give each a `///` comment:
   ```swift
   /// Whether Screen Recording is granted. Checked without prompting; tests pass their own.
   private let permitted: @MainActor () -> Bool
   /// Takes one shot of every `MenuBarAgent` bar. Tests pass scripted shots.
   private let captureBars: @MainActor () async throws -> [BarShot]
   /// The time, for the rate limit. Tests move it forward by hand.
   private let now: @MainActor () -> ContinuousClock.Instant
   /// Waits between `captureSettled`'s shots. It throws when the task is cancelled.
   private let sleep: @MainActor (Duration) async throws -> Void
   ```
3. Extend `init`. Keep `capturesScreen`: `LayoutModelEditTests.swift:148` passes it.
   ```swift
   init(directory: URL = IconImageProvider.defaultDirectory, capturesScreen: Bool = true,
        permitted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
        captureBars: @escaping @MainActor () async throws -> [BarShot] = { try await IconImageProvider.liveCaptureBars() },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
   ```
   Assign all of them.
4. Replace the hard-wired calls:
   - `captureIfPermitted`: `CGPreflightScreenCaptureAccess()` becomes `permitted()`, and `Self.captureBars()` becomes `captureBars()`.
   - `captureSettled`: `CGPreflightScreenCaptureAccess()` becomes `permitted()`, `Self.captureBars()` becomes `captureBars()`, and `Task.sleep(for: Self.settleInterval)` becomes `sleep(Self.settleInterval)`. Keep the `try?` in this step: behaviour must not change yet.

**Verify**:
- `swift build --build-tests 2>&1 | tail -3` ends with `Build complete!`.
- `grep -n "CGPreflightScreenCaptureAccess\|Self.captureBars\|Task.sleep" Sources/YeeHaw/System/IconImageProvider.swift` shows only the default-argument line(s) in `init`.

### Step 2: Characterization tests for today's capture behaviour

These tests pin down what capture does today. They must pass **before** any behaviour change. Add a new suite to `Tests/YeeHawTests/IconImageProviderTests.swift`, after `IconImageProviderTests`. Model it on `IconImageProviderTests` (lines 59-126): `@Suite @MainActor`, a temporary directory per test, removed with `defer`.

Helpers to add in the new suite:
```swift
/// Scripted bar shots: hands out `shots` in turn (the last repeats), or throws `error`, and counts calls.
@MainActor final class FakeBars {
    var calls = 0
    var shots: [[IconImageProvider.BarShot]]
    var error: Error?
    /// Runs inside each call, e.g. to count a write to the bar while the shot is taken.
    var during: (() -> Void)?
    /// How long each call takes, so a test can act while a shot is in flight.
    var delay: Duration?
    init(_ shots: [[IconImageProvider.BarShot]]) { self.shots = shots }
    func capture() async throws -> [IconImageProvider.BarShot] {
        calls += 1
        during?()
        if let delay { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return shots[min(calls - 1, shots.count - 1)]
    }
}
struct ShotFailed: Error {}
```
- A 200x24 pt bar at scale 2: `IconImageProvider.BarShot(frame: CGRect(x: 0, y: 0, width: 200, height: 24), image: crop(width: 400, height: 48, ink: CGRect(x: 128, y: 10, width: 24, height: 28)), scale: 2)`. This uses the file's existing global `crop(...)` helper (lines 7-18). The item to photograph is `IconImageProviderTests.drawn("com.example.app", index: 2)`, which sits at x 60, width 20, so its column is pixels 120-160 and holds the ink. Make a second bar with ink at `x: 136` for "a different picture".
- A provider factory: `IconImageProvider(directory: directory, permitted: { permission.granted }, captureBars: { try await bars.capture() }, now: { clock.now }, sleep: { _ in })`.
  - For `permission`, reuse the existing `@MainActor final class Permission { var granted = true }` from `StripColorTests.swift:150`. It is in the same test target, so don't declare a second type with that name.
  - For `clock`, add `@MainActor final class TestClock { var now = ContinuousClock.now }`. `StripColorSamplerTests` uses it in Step 5 too.
  - Before adding any helper type, check that its name is free: `grep -rn "class TestClock\|class FakeBars\|struct ShotFailed\|class Counter" Tests` → no output.
- Set `provider.proveOwnership = { items in Set(items.map(\.id)) }` to prove everything, or `{ _ in [] }` to prove nothing.
- "Stored" means `FileManager.default.fileExists(atPath: provider.fileURL(IconImageProvider.cacheKey(bundleID: "com.example.app", indexInApp: 2))!.path)` is true.

Write these tests (names are suggestions; keep the meaning):
1. `withoutScreenRecordingNothingIsShot`: `granted = false` gives `bars.calls == 0`.
2. `capturesScreenOffShootsNothing`: `capturesScreen: false` gives `bars.calls == 0`.
3. `onlyYeeHawsOwnItemShootsNothing`: the items are only `IconImageProviderTests.drawn(OwnIconLocator.bundleID, index: 0)`, which gives `bars.calls == 0`.
4. `aProvenItemIsStored`: prove everything. One call, the file exists, and `provider.image(for: "com.example.app", indexInApp: 2).isTemplate` is true.
5. `anUnprovenItemIsNotStored`: prove nothing. One call, and no file.
6. `aShotTakenWhileTheBarChangedIsDropped`: `provider.barWrites` returns a counter that `bars.during` increments. No file.
7. `aFailedShotStoresNothing`: `bars.error = ShotFailed()`. No file, and the call returns.
8. `settledStoresOnceTwoShotsMatch`: two identical shots. `captureSettled(item)` makes `bars.calls == 2`, and the file exists.
9. `settledGivesUpWhenTheIconNeverHoldsStill`: shots alternate between the two bars (`[[a],[b],[a],[b]]`). `bars.calls == IconImageProvider.settleShots`, and no file.

**Verify**: `swift test --filter IconImageProviderCaptureTests 2>&1 | tail -3` (use your suite's name) → `Test run with 9 tests ... passed`. Then the full suite → N + 9 tests, all pass. Commit.

### Step 3: Rate limit and in-flight guard in `captureIfPermitted`

**The rule:**
- A routine capture photographs an item only when it is due:
  - it has never been attempted this session; or
  - it has a photo, and its last attempt is at least `maxAge` old; or
  - it has no photo, and its last attempt is at least `missingRetry` (60 s) old.
- If no target is due, no SCK call is made at all.
- Once any target is due, the pass shoots and processes all targets as today, since the shot is already paid for.
- The default `maxAge` is 10 minutes (strip opens and launch). The Layout window passes 60 s.

**Why this rule:**
- The strip never shows drawn items. Their photos matter later: when the app gets hidden, and in the Layout window.
- New apps (no photo) are photographed on the next strip open.
- Glyphs that change with an app's state drift by at most 10 minutes. The reveal's settled photo (`captureSettled`) already catches the state at each use.
- This cuts strip-open shots from one per open to at most one per item per 10 minutes. Each shot flashes the recording indicator and re-lays out the bar.
- The Layout window shows drawn items' photos (the clock's text, for example). It is opened deliberately, so 60 s keeps it current while stopping bursts from repeated refreshes (window becomes key, after Apply).
- Recording the attempt even when the proof fails stops an item that can never be proven from triggering a shot on every open.

Implementation in `IconImageProvider.swift`:
```swift
/// How old a photo may get before a routine capture (a strip open, launch) takes it again.
static let photoMaxAge: Duration = .seconds(600)
/// How old the Layout window lets a photo get: it shows drawn items' photos, so they stay current there.
static let layoutPhotoMaxAge: Duration = .seconds(60)
/// How soon an item that has no photo yet is tried again after a pass that couldn't keep one.
static let missingRetry: Duration = .seconds(60)
/// When each item was last part of a capture pass, by `attemptKey`.
private var lastAttempt: [String: ContinuousClock.Instant] = [:]
/// Set while `captureIfPermitted` runs, so a second pass never overlaps it.
private var capturing = false
```
- `static func attemptKey(_ item: MenuBarItem) -> String`: `cacheKey(bundleID:indexInApp:)` for third-party items, `"apple:" + item.id` for Apple items.
- `private func hasPhoto(_ item: MenuBarItem) -> Bool`: `appleCaptures[item.id] != nil` for Apple items, else `captured(cacheKey) != nil`.
- `private func isDue(_ item: MenuBarItem, maxAge: Duration, at time: ContinuousClock.Instant) -> Bool`, per the rule above.
- New signature: `func captureIfPermitted(_ items: [MenuBarItem], maxAge: Duration = IconImageProvider.photoMaxAge) async`. Update its doc comment to state the rule in one or two sentences.
- New order at the top. Nothing may `await` before `capturing = true`, so two calls on the main actor can't both pass the guard.
  ```swift
  guard capturesScreen, !capturing, permitted() else { return }
  let targets = ... (unchanged)
  guard !targets.isEmpty else { return }
  let time = now()
  guard targets.contains(where: { isDue($0, maxAge: maxAge, at: time) }), !Task.isCancelled else { return }
  capturing = true
  defer { capturing = false }
  for item in targets { lastAttempt[Self.attemptKey(item)] = time }
  ```
- In `captureSettled`, after a successful `store(...)`, set `lastAttempt[Self.attemptKey(item)] = now()`. A routine pass then doesn't re-shoot what the reveal just photographed.

`LayoutModel.swift:197` becomes `await images.captureIfPermitted(controller.items, maxAge: IconImageProvider.layoutPhotoMaxAge)`.

Tests to add to the capture suite (write them first):
10. `aFreshPhotoIsNotRetaken`: prove everything. Two `captureIfPermitted([item])` calls at the same clock give `bars.calls == 1`.
11. `aPhotoIsRetakenOnceItsOld`: as above, then `clock.now += IconImageProvider.photoMaxAge`, and a third call gives `bars.calls == 2`.
12. `theLayoutsShorterAgeApplies`: after a first call, `clock.now += .seconds(61)`, and a call with `maxAge: IconImageProvider.layoutPhotoMaxAge` gives 2 calls. A call with the default age at the same clock gives no third call.
13. `anItemWithNoPhotoIsRetriedAfterAMinuteNotBefore`: prove nothing. `clock.now += .seconds(30)` gives still 1 call. `clock.now += .seconds(31)` gives 2.
14. `aNewItemTriggersAPass`: after a fresh pass for item A, a call with `[A, B]` (B at index 3, x 90) gives 2 calls.
15. `aSecondPassDoesNotOverlapOneInFlight`: set `bars.delay = .milliseconds(50)` so the first shot stays in flight. Start `let first = Task { await provider.captureIfPermitted([a]) }`. Loop `while bars.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }` (the pattern from `StripColorTests.swift:189`). Then `await provider.captureIfPermitted([b])`, then `await first.value`. Expect `bars.calls == 1`.

**Verify**: the capture suite passes with 15 tests. Then `swift test 2>&1 | grep -E "Test run with|failed"` → N + 15, all pass.

### Step 4: Stop cancelled captures

In `captureIfPermitted`:
- Right after `bars = try await captureBars()` succeeds, add `guard !Task.isCancelled else { return }`.
- Right after `let proven = await proveOwnership(items)`, add:
  ```swift
  guard !Task.isCancelled else {
      Self.log.info("Menu bar capture dropped: cancelled")
      return
  }
  ```
  `StatusItemController.openStrip` cancels the previous strip refresh. That refresh must not store photos after it was replaced.

In `captureSettled`, replace the sleep line and add a check before each shot:
```swift
if shot > 0 {
    do { try await sleep(Self.settleInterval) } catch { return }
}
guard !Task.isCancelled else { return }
```

Tests (write first):
16. `aCancelledPassShootsNothing`: `let task = Task { await provider.captureIfPermitted([item]) }; task.cancel(); await task.value`, then `bars.calls == 0`. The test runs on the main actor, so the task body can't start before `cancel()`.
17. `aPassCancelledDuringTheProofStoresNothing`: `provider.proveOwnership = { items in withUnsafeCurrentTask { $0?.cancel() }; return Set(items.map(\.id)) }`. Then 1 call and no file.
18. `aSettleCancelledMidwayStopsShooting`: construct the provider with `sleep: { _ in throw CancellationError() }` and shots that never match. `captureSettled` makes `bars.calls == 1` and no file. Today it would make 4 calls.
19. `aCancelledSettleShootsNothing`: as test 16, but with `captureSettled(item)`. 0 calls.

**Verify**: the capture suite passes with 19 tests, and the full suite gives N + 19, all pass. Then commit: `perf: rate-limit icon photos and stop cancelled captures`.

### Step 5: Lazy, debounced bar-colour sampling

**The rule:**
- A sample stays good for `freshFor` (5 minutes) unless something that changes the bar's colour happened since: a Space switch, an appearance change or a display change.
- Those events now only mark the samples out of date (`invalidate()`). The next strip show or Layout refresh captures again.
- Bursts of events (switching through several Spaces) cost nothing until the strip is next opened.
- The cached colour is still painted at once on show, so the strip never opens in the neutral fallback once a colour is known.
- Wallpaper changes within a Space have no notification, and the 5-minute limit bounds how stale that gets.

In `StripColorSampler.swift`:
1. Add an injectable clock, matching `permitted`:
   ```swift
   private let now: @MainActor () -> ContinuousClock.Instant
   ```
   Add the init parameter `now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }` after `capture`.
2. Add:
   ```swift
   /// How long a sample stays good while nothing that changes the bar's colour has happened.
   static let freshFor: Duration = .seconds(300)
   /// When each display's kept sample was taken; cleared by `invalidate()`.
   private var sampledAt: [CGDirectDisplayID: ContinuousClock.Instant] = [:]

   /// Marks every display's sample out of date (the Space, the appearance or the displays changed),
   /// so the next `sample` captures again. The colours stay cached, so the strip still opens in the
   /// last known colour rather than the neutral.
   func invalidate() {
       sampledAt = [:]
   }
   ```
3. In `sample(display:barHeight:)`:
   - In the no-permission branch, also clear `sampledAt[display]`.
   - After the permission guard, add:
     ```swift
     if let color = cache[display], let at = sampledAt[display], now() - at < Self.freshFor {
         return .sampled(color)
     }
     ```
   - Where a success is kept (`applied[display] = number; cache[display] = color`), also set `sampledAt[display] = now()`.
   - Update the method's doc comment to say a fresh sample is returned from the cache without capturing.

In `StripPanel.swift`:
1. Delete `spaceSettle` and its doc comment (lines 37-38). Nothing else uses it: `grep -rn spaceSettle Sources Tests` → only line 294, which this step rewrites.
2. Rewrite `watchForResampling()` (lines 282-305):
   - Keep the first `resampleAllScreens()` call. It runs once at launch, so the first show opens in the bar's colour.
   - The display-change and Space-change observers call only `self?.sampler.invalidate()` (inside the existing `Task { @MainActor [weak self] in ... }`).
   - The appearance observer calls `sampler.invalidate()`. Then, if `isShown`: `paint(currentFill(), animated: true)`, then `resampleForShow()`. The neutral fallback depends on the appearance, and the strip stays open across an appearance change.
   - Update the doc comment (lines 282-284) to describe the new behaviour.
3. `resampleAllScreens()` keeps its body. After this step its only caller is the launch call.

Test changes in `StripColorTests.swift`:
- `aTransientFailureKeepsTheLastGoodColour` (lines 176-182) samples twice in a row and expects the second capture to run. Add `sampler.invalidate()` between the two samples. This is the only existing test that needs editing. Explain why in the commit body.
- New tests in `StripColorSamplerTests`. Construct the sampler with `now: { clock.now }`, using the `TestClock` class added in Step 2:
  20. `aFreshSampleIsReusedWithoutCapturing`: two samples, so `script.calls == 1`, and the second returns `.sampled(navy)`.
  21. `invalidatingMakesTheNextSampleCapture`: sample, `invalidate()`, sample, so `calls == 2`.
  22. `aSampleExpiresAfterFiveMinutes`: sample, `clock.now += StripColorSampler.freshFor`, sample, so `calls == 2`.
  23. `aFailedSampleIsNotFresh`: script `[.failed("x"), .sampled(navy)]`. Two samples give `calls == 2`.

**Verify**:
- `swift test --filter StripColorSamplerTests 2>&1 | tail -3` → passes, 4 more tests than before.
- `grep -n "spaceSettle\|Task.sleep" Sources/YeeHaw/UI/StripPanel.swift` → no output.
- Full suite → N + 23, all pass.

Commit: `perf: sample the bar colour lazily, at most every five minutes`.

### Step 6: Correct the strip's comment

In `StatusItemController.swift`, inside `openStrip`, replace only these two comment lines. If plan 002 left them intact, they still read:
```swift
        // Re-read the bar in the background: YeeHaw's icon may have moved, and drawn items get
        // fresh photographs. The strip itself opens at once from the saved state.
```
Replace them with:
```swift
        // Re-read the bar in the background: YeeHaw's icon may have moved, and drawn items whose
        // photo is missing or old get a new one (`captureIfPermitted`'s rate limit). The strip
        // itself opens at once from the saved state.
```
Don't change any code in this file.

**Verify**: `git diff --stat -- Sources/YeeHaw/UI/StatusItemController.swift` → `1 file changed, 3 insertions(+), 2 deletions(-)`. Commit.

### Step 7: Final checks

- `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` → `0`
- `swift test 2>&1 | grep -E "Test run with|failed"` → N + 23 tests, passed, no `failed`.
- `git status --short` → only in-scope files.

Update `plans/README.md`: set row 003's Status to `DONE`.

## Test plan

- New suite in `Tests/YeeHawTests/IconImageProviderTests.swift`: 19 tests.
  - 9 characterization tests (Step 2): permission, `capturesScreen`, own item, proven, unproven, bar changed, failed shot, settled match, settled never still.
  - 6 rate-limit and in-flight tests (Step 3).
  - 4 cancellation tests (Step 4).
- `Tests/YeeHawTests/StripColorTests.swift`: 4 new sampler tests and 1 edited test (Step 5).
- Structural pattern: `IconImageProviderTests` (temporary directory, `@MainActor` suite), and `StripColorSamplerTests` with `ScriptedCapture` (scripted async seam, polling for an in-flight call).
- Verification: `swift test` → N + 23 tests pass, where N is the Step 0 baseline.

## Done criteria

ALL must hold:

- [ ] `swift package clean && swift build --build-tests 2>&1 | grep -c "warning:"` prints `0`
- [ ] `swift test` passes, and the total equals the Step 0 baseline + 23
- [ ] `grep -n "CGPreflightScreenCaptureAccess()" Sources/YeeHaw/System/IconImageProvider.swift` matches only the `init` default argument
- [ ] `grep -n "try? await Task.sleep\|try? await sleep" Sources/YeeHaw/System/IconImageProvider.swift` → no output
- [ ] `grep -n "Task.isCancelled" Sources/YeeHaw/System/IconImageProvider.swift` → at least 4 matches
- [ ] `grep -n "func invalidate" Sources/YeeHaw/UI/StripColorSampler.swift` → 1 match
- [ ] `grep -rn "spaceSettle" Sources Tests` → no output
- [ ] `grep -n "layoutPhotoMaxAge" Sources/YeeHaw/UI/LayoutModel.swift` → 1 match
- [ ] `git diff --stat BASE..HEAD` (BASE from Step 0) lists only in-scope files. In particular, it doesn't list `YeeHawApp.swift`, `RevealCoordinator.swift` or `ItemMatcher.swift`.
- [ ] `plans/README.md` row 003 is `DONE`

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 002 isn't `DONE` in `plans/README.md`.
- `captureSettled`'s signature is no longer `func captureSettled(_ item: MenuBarItem) async`, or `captureIfPermitted` has gained parameters you didn't add. Another plan changed them; don't merge the two designs by guessing.
- `reveal.onClosed` no longer calls `icons.captureSettled`. Then the settled-photo path moved, and the `lastAttempt` update in Step 3 may be in the wrong place.
- A characterization test in Step 2 fails against the unchanged behaviour. The plan's description of today's behaviour is wrong; report which test failed and how.
- Making `liveCaptureBars` non-private, or the `@MainActor` closure defaults, produce a Swift 6 concurrency error you can't fix by adding `@MainActor` or `@Sendable` to a closure type. Don't add `nonisolated(unsafe)` or `@preconcurrency`.
- An existing test other than `aTransientFailureKeepsTheLastGoodColour` fails after Step 5. Some caller depends on every `sample` capturing.
- The fix appears to need edits to `YeeHawApp.swift`, `RevealCoordinator.swift` or `ItemMatcher.swift`.

## Maintenance notes

- Plan 010 (multi-display photos) builds on the `captureBars` seam, the `FakeBars` helper and the `BarShot` fixtures added here. It changes `proveOwnership` to return per-copy slots, so the tests here that set `proveOwnership = { items in Set(items.map(\.id)) }` will be updated there.
- `lastAttempt` is in memory only. After a relaunch every item is due once, which matches today's launch-time photo pass.
- Reviewers should check two things:
  - Nothing `await`s between the `capturing` guard and `capturing = true`.
  - `defer { capturing = false }` covers every early return after it.
- Deferred: skipping the strip-open capture entirely and relying only on the Layout window and launch. It was rejected because a newly launched app would then show its app icon in the strip, not its glyph, until the Layout window was opened.
- Deferred: the `SCShareableContent` query in `liveCaptureBars` runs once per shot. Caching the window list across `captureSettled`'s 4 shots would save queries, but stale window lists after a display change are a risk. Revisit only if captures still show in profiles.
