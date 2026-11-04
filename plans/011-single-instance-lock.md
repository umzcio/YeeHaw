# Plan 011: Only one YeeHaw runs at a time, whichever build it is

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md` (if that file exists), unless a reviewer dispatched you
> and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff 495d26f..HEAD -- Sources/YeeHaw/App/YeeHawApp.swift Sources/YeeHawCore/LaunchRules.swift Tests/YeeHawCoreTests/LaunchRulesTests.swift`
> Expected: `LaunchRules.swift` and `LaunchRulesTests.swift` unchanged. `YeeHawApp.swift` changed
> only by plan 001 and plan 004:
> - 001 added two lines after `watchForThaw()`: a comment plus `Task { await HiddenMenuBarApps.unhideOnce() }`.
> - 004 replaced `terminationSignal` with `terminationSignals` and `quitOnTerminationSignal()`
>   with `quitOnTerminationSignals()` plus `quitSignals`.
>
> Any other change, especially to the launch-check block or `anotherInstanceRuns`, is drift. Compare
> it against the "Current state" excerpts. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/004-restore-everything-and-safe-quit.md (both edit `YeeHawApp.swift`;
  004 lands first so this plan's excerpts and line shifts are predictable)
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw edits two macOS preference files (the menu bar Allow list and the icon order). It keeps
its own record of what it switched off, so two copies running at once overwrite each other's
record and can leave icons switched off with nobody tracking them. Today the "another copy is
running" check matches running apps by bundle ID. A build run with `swift run` or from
`.build/debug` has no bundle ID, so the installed YeeHaw, opened after it, doesn't see it, and both
run. A second flaw: when a launch date is unknown, both copies decide the other one wins and both
refuse to start. After this plan, a file lock in `~/Library/Application Support/YeeHaw/` admits
exactly one copy of any build. The old check stays as a backstop for copies from before the lock
existed, and it breaks unknown-date ties by process ID.

## Current state

- `Sources/YeeHaw/App/YeeHawApp.swift` (line numbers at `495d26f`; plans 001 and 004 shift them by a few lines):
  - Lines 33-55, the start of `applicationDidFinishLaunching`:
    ```swift
    func applicationDidFinishLaunching(_ notification: Notification) {
        let command = DebugCommand(arguments: CommandLine.arguments)
        if let command, command.isReadOnly {
            run(command)
            return
        }

        // Before anything is written, debug runs that write included.
        let apps = NSWorkspace.shared.runningApplications
        if case .refuse(let refusal) = LaunchRules.check(os: ProcessInfo.processInfo.operatingSystemVersion,
                                                         running: Set(apps.compactMap(\.bundleIdentifier)),
                                                         anotherInstance: Self.anotherInstanceRuns(among: apps)) {
            if command != nil {
                DebugCommand.refused(refusal)
                exit(1)
            }
            refuseToStart(refusal)
            return
        }
        if let command {
            run(command)
            return
        }
    ```
    Read-only debug commands (`--probe`) skip the checks on purpose: they may run beside a live
    YeeHaw. Writing commands (`--grant`, `--reveal`, `--onboarding-preview`, and `--restore` from
    plan 004) go through them.
  - Lines 89-100:
    ```swift
    /// Whether another copy of YeeHaw (a build run from elsewhere, or `open -n`) is the one that
    /// keeps running. Two copies would each save their own record of what they switched off over
    /// the other's.
    private static func anotherInstanceRuns(among apps: [NSRunningApplication]) -> Bool {
        let me = NSRunningApplication.current
        let ownID = Bundle.main.bundleIdentifier ?? OwnIconLocator.bundleID
        return apps.contains { app in
            app.bundleIdentifier == ownID && !app.isTerminated
                && LaunchRules.isAnotherInstance(mine: (me.processIdentifier, me.launchDate),
                                                 other: (app.processIdentifier, app.launchDate))
        }
    }
    ```
    `app.bundleIdentifier` is nil for an unbundled build, so the installed copy never matches it.
  - Lines 11-23: the stored properties (`controller`, `grants`, …, `launchObserver`), each with a `///` comment.
- `Sources/YeeHawCore/LaunchRules.swift:62-71`:
  ```swift
  /// Whether `other`, a process with YeeHaw's bundle ID, is the copy that keeps running rather
  /// than this one (`mine`): the one launched first wins, then the lower process ID, so two
  /// copies opened together never both quit. A copy whose launch date is unknown counts.
  public static func isAnotherInstance(mine: (pid: Int32, launched: Date?),
                                       other: (pid: Int32, launched: Date?)) -> Bool {
      guard other.pid != mine.pid else { return false }
      guard let theirs = other.launched, let ours = mine.launched else { return true }
      if theirs != ours { return theirs < ours }
      return other.pid < mine.pid
  }
  ```
  Line 68 returns `true` for **both** copies when a date is missing, so both refuse.
  `LaunchRules.check(os:running:anotherInstance:)` (lines 50-60) refuses with `.alreadyRunning`
  when `anotherInstance` is true. Its title and message (lines 29, 41-43) need no change.
- `Tests/YeeHawCoreTests/LaunchRulesTests.swift:126-138`: `theOldestCopyIsTheOneThatRuns`. Its last
  line, `// Unknown launch date for the other copy: it counts as running.` followed by
  `#expect(LaunchRules.isAnotherInstance(mine: (pid: 20, launched: late), other: (pid: 10, launched: nil)))`,
  still holds after the fix (10 < 20), but its comment must change.
- The app isn't sandboxed (no entitlements file; `scripts/build-app.sh` signs without
  entitlements). Every build therefore shares the same `~/Library/Application Support`.
- Conventions:
  - Swift 6, SwiftPM. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`, `Issue.record`).
  - Doc comments (`///`) explain **why**, in plain sentences. Match
    `Sources/YeeHaw/System/RevealCoordinator.swift` (e.g. lines 10-20).
  - Logs use `Logger(subsystem: Log.subsystem, category: …)` with `privacy: .public`.
  - No personal names or signing identity names anywhere. Don't change the bundle ID.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter "InstanceLockTests\|LaunchRulesTests" 2>&1 \| tail -n 3` | passed |
| All tests | `swift test 2>&1 \| tail -n 3` | `Test run with <N> tests … passed` |
| Warnings | `swift test 2>&1 \| grep -c "warning:"` | `0` |

Before this plan (plans 001 and 004 landed) `swift test` passes 456 tests with 0 warnings. If your
starting count differs, note it and add 4.

## Scope

**In scope**:
- `Sources/YeeHaw/System/InstanceLock.swift` (create)
- `Sources/YeeHaw/App/YeeHawApp.swift` (the launch-check block, `anotherInstanceRuns`'s doc comment, one new property)
- `Sources/YeeHawCore/LaunchRules.swift` (`isAnotherInstance` only)
- `Tests/YeeHawTests/InstanceLockTests.swift` (create)
- `Tests/YeeHawCoreTests/LaunchRulesTests.swift`
- `plans/README.md` (status row only, if it exists)

**Out of scope** (do NOT touch):
- `Sources/YeeHaw/App/DebugCommand.swift`. Its commands get the lock through
  `applicationDidFinishLaunching` with no change of their own.
- `LaunchRules.Refusal` texts and `LaunchRules.check`'s signature.
- Signal handling and quit paths (plan 004's work).
- Bundle ID, Info.plist, signing, `scripts/`.

## Git workflow

- Branch from the branch that has plans 001 and 004 (`advisor/004-restore-everything-and-safe-quit`
  if they aren't merged into `build/yeehaw-v1` yet): `git switch -c advisor/011-single-instance-lock`
- Conventional commits, as in `git log` (e.g. `fix: keep a revealed icon while its popover hangs
  from the bar`). Every message ends with a blank line and then
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Do NOT commit `plans/`. Do NOT push or open a PR.

## Steps

### Step 1: Break unknown-launch-date ties by process ID

In `Sources/YeeHawCore/LaunchRules.swift`:
- Line 68 becomes:
  `guard let theirs = other.launched, let ours = mine.launched else { return other.pid < mine.pid }`
- The doc comment's last sentence (line 64), "A copy whose launch date is unknown counts.",
  becomes "When either launch date is unknown, the lower process ID wins, so two copies never
  both step aside."

In `Tests/YeeHawCoreTests/LaunchRulesTests.swift`:
- In `theOldestCopyIsTheOneThatRuns`, change the comment above the last `#expect` to
  `// Unknown launch date for the other copy: the lower process ID wins.`
- Add a new test after it:
  ```swift
  @Test func unknownLaunchDatesNeverMakeBothCopiesStepAside() {
      let late = Date(timeIntervalSince1970: 200)
      // Each pair is the same two processes seen from both sides: exactly one steps aside.
      for (a, b) in [((pid: Int32(10), launched: Date?.none), (pid: Int32(20), launched: Date?.none)),
                     ((pid: 10, launched: nil), (pid: 20, launched: late)),
                     ((pid: 10, launched: late), (pid: 20, launched: nil))] {
          #expect(LaunchRules.isAnotherInstance(mine: a, other: b) != LaunchRules.isAnotherInstance(mine: b, other: a))
      }
      #expect(!LaunchRules.isAnotherInstance(mine: (pid: 10, launched: nil), other: (pid: 20, launched: nil)))
  }
  ```
  If the tuple-array literal doesn't type-check, write the three pairs as three separate pairs of
  `#expect` lines instead. The assertions must stay the same.

**Verify**:
- `swift test --filter LaunchRulesTests 2>&1 | tail -n 3` → passed
- `grep -n "else { return true }" Sources/YeeHawCore/LaunchRules.swift` → no output

Commit: `fix: two YeeHaw copies with an unknown launch date no longer both refuse to start`

### Step 2: Add `InstanceLock`

Create `Sources/YeeHaw/System/InstanceLock.swift`:
```swift
import Foundation

/// Lets exactly one YeeHaw run per user, whichever build it is. The bundle ID check misses a copy
/// run with `swift run` or from `.build/debug`, which has no bundle ID, and two copies would each
/// save their own record of what they switched off over the other's. An exclusive `flock` on a
/// file in Application Support is held for the life of the process; macOS releases it when the
/// process ends, crash and force quit included, so a stale lock can't block the next launch.
final class InstanceLock: Sendable {
    enum Outcome {
        /// This process holds the lock; keep the value alive for as long as YeeHaw runs.
        case acquired(InstanceLock)
        /// Another process holds it: another YeeHaw is running.
        case heldElsewhere
        /// The lock file couldn't be opened or locked for another reason (the reason is in the
        /// text). YeeHaw still starts, relying on the bundle ID check, rather than refusing to
        /// run over a missing folder.
        case unavailable(String)

        var isHeldElsewhere: Bool {
            if case .heldElsewhere = self { return true }
            return false
        }
    }

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "YeeHaw/instance.lock")

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Takes the lock at `url` without waiting, creating its folder and file if needed.
    static func acquire(at url: URL = defaultURL) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            return .unavailable("\(error)")
        }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .heldElsewhere : .unavailable(String(cString: strerror(code)))
        }
        return .acquired(InstanceLock(descriptor: descriptor))
    }
}
```

Create `Tests/YeeHawTests/InstanceLockTests.swift` with the three tests in the Test plan. **Never call
`InstanceLock.acquire()` with the default URL in a test**: it would collide with a YeeHaw
running on the same Mac.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `swift test --filter InstanceLockTests 2>&1 | tail -n 3` → passed (3 tests)
- `grep -rn "InstanceLock.acquire()" Tests` → no output

Commit: `feat: a file lock admits one YeeHaw at a time, bundled or not`

### Step 3: Use the lock in the launch checks

In `Sources/YeeHaw/App/YeeHawApp.swift`:
- Add a stored property after `launchObserver` (line 23 at `495d26f`):
  ```swift
  /// Held for as long as YeeHaw runs, so no other copy starts (`InstanceLock`).
  private var instanceLock: InstanceLock?
  ```
- In `applicationDidFinishLaunching`, directly after the comment
  `// Before anything is written, debug runs that write included.` and before
  `let apps = NSWorkspace.shared.runningApplications`, insert:
  ```swift
  let lock = InstanceLock.acquire()
  switch lock {
  case .acquired(let held):
      instanceLock = held
  case .heldElsewhere:
      break
  case .unavailable(let reason):
      Self.log.error("Instance lock unavailable (\(reason, privacy: .public)); relying on the bundle ID check")
  }
  ```
  Then change the `anotherInstance:` argument of `LaunchRules.check` to
  `anotherInstance: lock.isHeldElsewhere || Self.anotherInstanceRuns(among: apps)) {`.
  Leave everything else in that block as it is. The read-only early return above it stays first,
  so `--probe` still runs beside a live YeeHaw without taking the lock.
- Replace the doc comment of `anotherInstanceRuns` (lines 89-91 at `495d26f`) with:
  ```swift
  /// Whether another copy of YeeHaw with the same bundle ID (`open -n`, or a copy from before
  /// `InstanceLock` existed, which never takes the lock) is the one that keeps running. Copies
  /// without a bundle ID are caught by the lock instead.
  ```

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -n "lock.isHeldElsewhere || Self.anotherInstanceRuns(among: apps)" Sources/YeeHaw/App/YeeHawApp.swift` → one line
- `grep -n "InstanceLock.acquire()" Sources/YeeHaw/App/YeeHawApp.swift` → one line, **after** the line with `command.isReadOnly`
  (check with `grep -n "command.isReadOnly\|InstanceLock.acquire()" Sources/YeeHaw/App/YeeHawApp.swift`; the `isReadOnly` line number is smaller)
- `swift test 2>&1 | tail -n 3` → passed, `Test run with 460 tests` (456 + 4)
- `swift test 2>&1 | grep -c "warning:"` → `0`

Commit: `fix: refuse to start beside another YeeHaw even when it has no bundle ID`

## Test plan

`Tests/YeeHawTests/InstanceLockTests.swift`, structured like the other files in `Tests/YeeHawTests`
(`import Foundation`, `import Testing`, `@testable import YeeHaw`, `@Suite struct InstanceLockTests`).
Each test makes its own folder:
`FileManager.default.temporaryDirectory.appending(path: "InstanceLockTests-\(UUID().uuidString)")`,
and the lock file is `instance.lock` inside it. The folder doesn't exist beforehand, which
exercises the `createDirectory` path. Remove it at the end with `try? FileManager.default.removeItem(at:)`.

1. `aSecondCopyFindsTheLockHeld`:
   `guard case .acquired(let first) = InstanceLock.acquire(at: url) else { Issue.record("first copy didn't get the lock"); return }`,
   then `#expect(InstanceLock.acquire(at: url).isHeldElsewhere)`, then `withExtendedLifetime(first) {}`
   so the first lock isn't released early.
2. `theLockIsFreeAgainOnceReleased`: `var first: InstanceLock?`, set it from the `.acquired` case,
   set `first = nil`, then `guard case .acquired = InstanceLock.acquire(at: url) else { Issue.record(...) ; return }`.
3. `anUncreatableFolderIsUnavailableNotHeld`:
   `let outcome = InstanceLock.acquire(at: URL(filePath: "/dev/null/YeeHaw/instance.lock"))`. Expect
   `guard case .unavailable = outcome` to succeed and `#expect(!outcome.isHeldElsewhere)`.

`LaunchRulesTests`: one new test (Step 1), one comment change.

Expected totals: 456 + 1 (LaunchRules) + 3 (InstanceLock) = 460 tests, all passing, 0 warnings.

## Done criteria

- [ ] `swift build 2>&1 | grep -E "warning:|error:"` prints nothing
- [ ] `swift test 2>&1 | tail -n 3` shows the run passed with 460 tests (or starting count + 4); `swift test 2>&1 | grep -c "warning:"` prints `0`
- [ ] `grep -n "else { return other.pid < mine.pid }" Sources/YeeHawCore/LaunchRules.swift` prints one line
- [ ] `grep -n "LOCK_EX | LOCK_NB" Sources/YeeHaw/System/InstanceLock.swift` prints one line
- [ ] `grep -n "lock.isHeldElsewhere || Self.anotherInstanceRuns(among: apps)" Sources/YeeHaw/App/YeeHawApp.swift` prints one line
- [ ] `grep -rn "InstanceLock.acquire()" Tests` prints nothing
- [ ] `git status --short` lists only files from the Scope section (and the untracked `plans/` folder)
- [ ] `git log --oneline` shows this plan's three commits, each message ending with the `Co-Authored-By` line
- [ ] `plans/README.md` status row updated (if the file exists)

Manual check, only if the operator asks: with the installed YeeHaw running
(`open ~/Applications/YeeHaw.app`), run `swift build && .build/debug/YeeHaw`. It shows "YeeHaw is
already running" and quits. Quit the installed copy, start `.build/debug/YeeHaw` first, then
`open ~/Applications/YeeHaw.app`. The installed copy now refuses too (before this plan it started).
`lsof ~/Library/Application\ Support/YeeHaw/instance.lock` shows the running copy.

## STOP conditions

Stop and report back (do not improvise) if:

- Test 1 finds the lock acquired twice in one process. That would mean `flock` on this macOS
  doesn't conflict between two separate `open()` descriptors, so the test design (and maybe the lock
  approach) is wrong. Report it rather than switching to `fcntl`/`lockf`, which have different semantics.
- The drift check shows changes to the launch-check block or `anotherInstanceRuns` beyond what
  plans 001 and 004 describe.
- The compiler rejects `InstanceLock: Sendable` or the Darwin calls, and the fix would need
  `@unchecked Sendable` or `nonisolated(unsafe)`. A `final class` with only a `let Int32` should
  be Sendable.
- `URL.applicationSupportDirectory` resolves inside a sandbox container (a path containing
  `/Containers/`). That would mean the app became sandboxed, and the lock wouldn't be shared
  between builds.
- Any existing test fails, especially in `LaunchRulesTests`. Report it rather than changing old
  assertions beyond the one comment.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- The lock file is `~/Library/Application Support/YeeHaw/instance.lock`. It stays on disk empty
  after YeeHaw quits, which is normal. Only the `flock` matters, and the kernel drops it when the
  process exits.
- `--probe` (read-only) never takes the lock. Writing debug commands (`--grant`, `--reveal`,
  `--onboarding-preview`, `--restore`) do, so `--restore` is refused while YeeHaw runs; use its
  menu's Restore Everything and Quit then.
- The bundle ID check is kept only for copies from before this change. Once no such build can be
  around, `anotherInstanceRuns` and `LaunchRules.isAnotherInstance` could be removed in a tidy-up.
- Reviewers: check that the lock is taken before anything is written, and that `instanceLock` is
  stored on the delegate (if it were a local, it would be released at the end of
  `applicationDidFinishLaunching`).
