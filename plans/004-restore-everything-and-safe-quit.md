# Plan 004: "Restore everything" is one click or one command away, and quitting never silently leaves icons hidden

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md` (if that file exists), unless a reviewer dispatched you
> and told you they maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/App/YeeHawApp.swift Sources/YeeHaw/App/DebugCommand.swift Sources/YeeHaw/UI/StatusItemController.swift README.md`
> Expected: only `Sources/YeeHaw/App/YeeHawApp.swift` changed (+2 lines). Plan 001 added the
> `Task { await HiddenMenuBarApps.unhideOnce() }` line and its comment after `watchForThaw()`.
> Anything else that changed in these files is drift: compare the "Current state" excerpts against
> the live code. On a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-spacing-never-hides-apps.md. This plan reuses the
  `HiddenMenuBarApps.unhideAll(menuBarOwners:)` helper that plan 001 adds. It does not define its own.
- **Category**: bug
- **Planned at**: commit `495d26f`, 2026-11-02

## Why this matters

YeeHaw hides other apps' menu bar icons by switching them off in macOS's menu bar Allow list. It
switches them back on only when it quits the ordinary way. Several common endings skip that:
- Control-C in Terminal (SIGINT).
- A closed Terminal window (SIGHUP).
- Control-\ (SIGQUIT).
- A force quit or a crash.

After any of them, the icons stay gone until YeeHaw is opened again, and opening it hides them
again. There's no way to say "put everything back". Worse, when the status menu's **Quit YeeHaw**
fails to switch the apps back on, it logs the error and quits anyway, so the user loses icons
with no explanation. After this plan:
- The extra signals quit the ordinary way.
- A status menu item and a `--restore` command-line flag put every icon back and unhide stuck apps.
- A failed Quit shows an alert naming the apps still hidden, with Retry and Quit Anyway.

## Current state

- `Sources/YeeHaw/App/YeeHawApp.swift`, the app delegate:
  - Lines 18-19:
    ```swift
    /// Turns SIGTERM (`kill`, `pkill`) into an ordinary quit, so hidden apps are switched back on.
    private var terminationSignal: DispatchSourceSignal?
    ```
  - Line 57 calls `quitOnTerminationSignal()`. Lines 102-115:
    ```swift
    /// SIGTERM is ignored as a signal and handled on the main queue as an ordinary quit instead,
    /// which switches hidden apps back on (by default it would end the process on the spot).
    private func quitOnTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                Self.log.notice("SIGTERM received; quitting the ordinary way")
                NSApp.terminate(nil)
            }
        }
        source.resume()
        terminationSignal = source
    }
    ```
  - Lines 33-55: `applicationDidFinishLaunching` parses `DebugCommand(arguments:)`. A read-only
    command runs before the launch checks. Any other command runs only after `LaunchRules.check`
    passes, and that check refuses when another YeeHaw copy is running (lines 41-51). A refused
    command prints its reason and `exit(1)`s. `run(_:)` (lines 82-87) awaits the command, then
    calls `exit(0)`, so a command never reaches the quit-time code.
  - Lines 278-290: `applicationWillTerminate` is the only place an ordinary quit switches apps back
    on (`try controller.quit()`, logging any error). Nothing can be shown to the user there.
- `Sources/YeeHaw/App/DebugCommand.swift`, the command-line flags:
  - Lines 6-11, the doc comment: "`--grant` saves the grants the user picks, `--reveal` starts the
    controller, and `--onboarding-preview` shows the first-run window … those three pass the same
    launch checks as YeeHaw itself (macOS version, Thaw, another copy running) first."
  - Lines 12-24: `enum DebugCommand { case probe, grant, onboardingPreview, reveal(BundleID), missingBundleID(flag:) }`.
  - Lines 29-49: `init?(arguments:)` checks `--probe`, `--grant`, `--onboarding-preview`, then `--reveal`.
  - Lines 52-57:
    ```swift
    var isReadOnly: Bool {
        switch self {
        case .probe, .missingBundleID: true
        case .grant, .onboardingPreview, .reveal: false
        }
    }
    ```
  - Lines 64-85: `run()` switches over the cases and calls `Self.emit(lines)`. `emit` prints the
    lines and writes them to `~/Library/Logs/YeeHaw/probe.txt`.
  - Lines 166-168: `private static func listed(_ values: [String]) -> String` (joins for output).
- `Sources/YeeHaw/UI/StatusItemController.swift`, YeeHaw's own icon and its menu:
  - Lines 5-9, the class doc comment: "Right-click, Control-click and Option-click show the small
    menu (Layout…, Settings…, Quit YeeHaw) … VoiceOver gets the same three as actions on the icon."
  - Lines 56-60: three `NSAccessibilityCustomAction`s (Open Layout, Open Settings, Quit YeeHaw).
  - Lines 172-186: `buildMenu()` adds Layout… and Settings…, then a separator, then Quit YeeHaw (`q`).
  - Lines 198-207:
    ```swift
    /// Switches back on everything YeeHaw switched off, then quits.
    @objc private func quitChosen() {
        strip.dismiss()
        do {
            try controller.quit()
        } catch {
            Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
        }
        NSApp.terminate(nil)
    }
    ```
  - Lines 258-280: `static func notice(...)`, a pure text builder tested in
    `Tests/YeeHawTests/StripTests.swift` (`StripNoticeTests`, line 208). Use it as the pattern for the
    new alert-text builder. UI strings there use curly apostrophes, e.g. `"YeeHaw couldn’t show \(name(id))’s menu."`.
- `Sources/YeeHawCore/MenuBarController.swift:98-107`: `public func quit() throws`. It is
  synchronous and doesn't need `launch()` first: it reads the Allow list fresh (`writeAllow`, line
  ~594). It switches every app in `state.journal` back on in one write and puts a revealed app's
  positions back. The journal is cleared only if the write landed, so after a failure
  `controller.state.journal` still lists the apps that are off. `state.hidden` (the user's hidden
  list) is kept, so the next launch hides those apps again. That is the documented Quit behaviour,
  and this plan keeps it.
- `Sources/YeeHaw/UI/SwitchedOffReview.swift:245-257`: `AppIdentity.name(of: BundleID) -> String` (display name).
- From plan 001, `Sources/YeeHaw/System/HiddenMenuBarApps.swift`:
  `@discardableResult static func unhideAll(menuBarOwners: Set<BundleID>, own: BundleID = OwnIconLocator.bundleID) -> [String]`
  (`@MainActor`). It unhides running apps that may be hidden because of YeeHaw and returns their names.
- `README.md` lines 18-19 ("Nothing is lost if YeeHaw quits or crashes…") and line 25
  ("**Right-click** (or Control-click) the hat for **Layout…**, **Settings…** and **Quit YeeHaw**.").
- Conventions:
  - Swift 6, SwiftPM. Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
  - Doc comments (`///`) explain **why**, in plain sentences. Match
    `Sources/YeeHaw/System/RevealCoordinator.swift` (e.g. lines 10-20).
  - Logs use `Logger(subsystem: Log.subsystem, category: …)` with `privacy: .public`.
  - No personal names or signing identity names anywhere.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| New tests | `swift test --filter RestoreTests 2>&1 \| tail -n 3` | passed |
| All tests | `swift test 2>&1 \| tail -n 3` | `Test run with <N> tests … passed` |
| Warnings | `swift test 2>&1 \| grep -c "warning:"` | `0` |

Before this plan (with plan 001 landed) `swift test` passes 452 tests with 0 warnings. If your
starting count differs, note it and add 4 to whatever it is.

## Scope

**In scope**:
- `Sources/YeeHaw/App/YeeHawApp.swift` (signal handling only)
- `Sources/YeeHaw/App/DebugCommand.swift`
- `Sources/YeeHaw/UI/StatusItemController.swift`
- `README.md` (lines 18-19 and 25 only)
- `Tests/YeeHawTests/RestoreTests.swift` (create)
- `plans/README.md` (status row only, if it exists)

**Out of scope** (do NOT touch):
- `Sources/YeeHawCore/MenuBarController.swift` and `HidingState.swift`. Restore is exactly
  `quit()` plus unhiding, and changing what quit writes is a separate decision.
- `Sources/YeeHaw/System/HiddenMenuBarApps.swift`. Reuse it as is. If its signature differs from
  the one above, STOP.
- `applicationWillTerminate` and `applicationShouldTerminate`. They can't show UI while
  terminating, and they keep their logout/restart rules.
- The single-instance check in `applicationDidFinishLaunching` (lines 40-51). Plan 011 changes it.
- `Sources/YeeHaw/UI/AuxiliaryWindow.swift`'s app-menu Quit. It goes through `NSApp.terminate`
  and `applicationWillTerminate`, as today.

## Git workflow

- Branch from the branch that has plan 001's commits (`advisor/001-spacing-never-hides-apps` if
  it isn't merged into `build/yeehaw-v1` yet): `git switch -c advisor/004-restore-everything-and-safe-quit`
- Conventional commits, as in `git log` (e.g. `fix: keep a revealed icon while its popover hangs
  from the bar`). Every message ends with a blank line and then
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Do NOT commit `plans/`. Do NOT push or open a PR.

## Steps

### Step 0: Confirm plan 001's helper exists

**Verify**: `grep -n "static func unhideAll(menuBarOwners: Set<BundleID>" Sources/YeeHaw/System/HiddenMenuBarApps.swift`
→ one line. If there's no output, STOP: plan 001 hasn't landed on this branch.

### Step 1: Quit the ordinary way on SIGINT, SIGHUP and SIGQUIT too

In `Sources/YeeHaw/App/YeeHawApp.swift`:
- Replace lines 18-19 with:
  ```swift
  /// One per signal in `quitSignals`, each turned into an ordinary quit so hidden apps are
  /// switched back on.
  private var terminationSignals: [DispatchSourceSignal] = []
  ```
- Rename the call at line 57 to `quitOnTerminationSignals()`.
- Replace lines 102-115 with:
  ```swift
  /// What `kill` and `pkill` (SIGTERM), Control-C (SIGINT), closing the Terminal window YeeHaw
  /// runs in (SIGHUP) and Control-\ (SIGQUIT) send. By default each ends the process on the
  /// spot, leaving hidden apps switched off. SIGKILL and crashes can't be caught; `--restore` is
  /// for those.
  nonisolated static let quitSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

  /// Each of `quitSignals` is ignored as a signal and handled on the main queue as an ordinary
  /// quit instead, which switches hidden apps back on.
  private func quitOnTerminationSignals() {
      for number in Self.quitSignals {
          signal(number, SIG_IGN)
          let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
          source.setEventHandler {
              MainActor.assumeIsolated {
                  Self.log.notice("Signal \(number, privacy: .public) received; quitting the ordinary way")
                  NSApp.terminate(nil)
              }
          }
          source.resume()
          terminationSignals.append(source)
      }
  }
  ```

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -nE "terminationSignal[^s]|quitOnTerminationSignal\(\)" Sources/YeeHaw/App/YeeHawApp.swift` → no output (only the plural names remain)

Commit: `fix: quit the ordinary way on Control-C, hang-up and SIGQUIT, not only SIGTERM`

### Step 2: Add the `--restore` flag

In `Sources/YeeHaw/App/DebugCommand.swift`:
- Add a case after `reveal`:
  ```swift
  /// `--restore`: what quitting YeeHaw does (every app it switched off goes back on, and a
  /// revealed app's positions go back), plus unhiding menu bar apps that may be hidden because of
  /// YeeHaw. For after a crash or a force quit, without starting YeeHaw. Opening YeeHaw again hides
  /// the user's hidden apps again.
  case restore
  ```
- In `init?(arguments:)`, after the `--onboarding-preview` block and before the `--reveal` guard:
  ```swift
  if arguments.contains("--restore") {
      self = .restore
      return
  }
  ```
- `isReadOnly`: change the second line to `case .grant, .onboardingPreview, .reveal, .restore: false`.
  `--restore` writes, so it must pass the launch checks. In particular it is refused while another
  YeeHaw copy runs, and that copy's menu has Restore Everything and Quit.
- In `run()` add `case .restore: lines = await Self.restore(grants: grants)`.
- Add, next to `reveal(_:grants:)`:
  ```swift
  /// `--restore`. The unhide pass also counts the user's hidden apps as menu bar apps, since
  /// they're switched off and not drawn.
  @MainActor
  private static func restore(grants: FileGrantStore) async -> [String] {
      let controller = MenuBarController.live(grants: grants)
      let off = controller.state.journal.sorted()
      var lines: [String] = []
      do {
          try controller.quit()
          lines.append("switched back on: \(listed(off))")
      } catch {
          lines.append("could not switch back on \(listed(controller.state.journal.sorted())): \(error)")
      }
      let owners = Set(await AXMenuBarReader().items().compactMap(\.bundleID)).union(controller.state.hidden)
      lines.append("unhidden: \(listed(HiddenMenuBarApps.unhideAll(menuBarOwners: owners)))")
      return lines
  }
  ```
- In the top doc comment (lines 6-11), replace "`--grant` saves the grants the user picks,
  `--reveal` starts the controller, and `--onboarding-preview` shows the first-run window against
  the Mac as it is; those three pass" with "`--grant` saves the grants the user picks, `--reveal`
  starts the controller, `--restore` puts back what YeeHaw switched off, and
  `--onboarding-preview` shows the first-run window against the Mac as it is; those four pass".
  Re-wrap to about 100 columns.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -c "restore" Sources/YeeHaw/App/DebugCommand.swift` → at least `6`

Commit: `feat: --restore puts back every icon YeeHaw switched off and unhides stuck apps`

### Step 3: Restore Everything and Quit in the status menu; a failed quit asks instead of hiding the failure

In `Sources/YeeHaw/UI/StatusItemController.swift`:
- Class doc comment (lines 7-9): the menu list becomes "(Layout…, Settings…, Restore Everything
  and Quit, Quit YeeHaw)", and "VoiceOver gets the same three" becomes "VoiceOver gets the same four".
- In the custom actions (lines 56-60), before Quit YeeHaw, add
  `NSAccessibilityCustomAction(name: "Restore Everything and Quit") { [weak self] in self?.restoreChosen(); return true },`
- In `buildMenu()` (lines 182-185), after `menu.addItem(.separator())` and before the Quit item, add:
  ```swift
  let restore = NSMenuItem(title: "Restore Everything and Quit", action: #selector(restoreChosen), keyEquivalent: "")
  restore.target = self
  menu.addItem(restore)
  ```
- Replace `quitChosen()` (lines 198-207) with:
  ```swift
  /// Switches back on everything YeeHaw switched off, then quits.
  @objc private func quitChosen() {
      switchBackOnAndQuit(unhiding: false)
  }

  /// Quit, plus showing menu bar apps that may be hidden because of YeeHaw (an earlier Spacing
  /// Apply left some hidden): one place to get every icon back.
  @objc private func restoreChosen() {
      switchBackOnAndQuit(unhiding: true)
  }

  /// If switching back on fails, an alert names the apps still switched off and offers Retry or
  /// Quit Anyway. Quitting without asking would leave those icons gone with no explanation.
  private func switchBackOnAndQuit(unhiding: Bool) {
      strip.dismiss()
      while true {
          do {
              try controller.quit()
              break
          } catch {
              Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
              let stillOff = controller.state.journal.sorted().map(AppIdentity.name(of:))
              guard Self.askToRetryQuit(stillOff: stillOff) else { break }
          }
      }
      if unhiding {
          let owners = Set(controller.items.compactMap(\.bundleID)).union(controller.state.hidden)
          HiddenMenuBarApps.unhideAll(menuBarOwners: owners)
      }
      NSApp.terminate(nil)
  }

  /// Shows the failed-quit alert; true when the user chose Retry.
  private static func askToRetryQuit(stillOff: [String]) -> Bool {
      let text = quitFailure(stillOff: stillOff)
      NSApp.activate()
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = text.title
      alert.informativeText = text.message
      alert.addButton(withTitle: "Retry")
      alert.addButton(withTitle: "Quit Anyway")
      return alert.runModal() == .alertFirstButtonReturn
  }

  /// What the failed-quit alert says. `stillOff` are the names of the apps still switched off;
  /// empty when only a revealed app's position couldn't be put back (the next launch does that).
  nonisolated static func quitFailure(stillOff: [String]) -> (title: String, message: String) {
      guard let last = stillOff.last else {
          return ("YeeHaw couldn’t put an icon back in place",
                  "The icon YeeHaw was showing may stay next to YeeHaw’s hat until YeeHaw opens again.")
      }
      let names = stillOff.count == 1 ? last : stillOff.dropLast().joined(separator: ", ") + " and " + last
      return ("Some icons are still hidden",
              "YeeHaw couldn’t switch \(names) back on. If you quit anyway, they stay out of the menu bar "
                  + "until you open YeeHaw and quit it again, or switch them on in System Settings → Menu Bar.")
  }
  ```
  The quit still ends in `NSApp.terminate(nil)`, so `applicationWillTerminate` runs as before. Its
  second `controller.quit()` finds nothing to do, or logs the same failure after Quit Anyway.

In `README.md`:
- Line 25 becomes: `- **Right-click** (or Control-click) the hat for **Layout…**, **Settings…**,
  **Restore Everything and Quit** and **Quit YeeHaw**.` (keep it on lines wrapped like its neighbours).
- After the sentence ending "the next launch repairs anything a crash left behind." (line 19), add:
  ` To put every icon back without opening YeeHaw (after a crash or a force quit), run
  \`~/Applications/YeeHaw.app/Contents/MacOS/YeeHaw --restore\`.`

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -n "Restore Everything and Quit" Sources/YeeHaw/UI/StatusItemController.swift | wc -l` → `3` (doc comment, custom action, menu item)
- `grep -n "\-\-restore" README.md` → one line

Commit: `feat: Restore Everything and Quit; a failed quit names the icons still hidden`

### Step 4: Tests

Create `Tests/YeeHawTests/RestoreTests.swift` with the tests in the Test plan.

**Verify**:
- `swift test --filter RestoreTests 2>&1 | tail -n 3` → passed
- `swift test 2>&1 | tail -n 3` → passed, `Test run with 456 tests` (452 + 4)
- `swift test 2>&1 | grep -c "warning:"` → `0`

Commit: `test: --restore parsing, quit signals and the failed-quit text`

## Test plan

New file `Tests/YeeHawTests/RestoreTests.swift`, structured like `Tests/YeeHawTests/StripTests.swift`
(`import Testing`, `import YeeHawCore`, `@testable import YeeHaw`, one `@Suite struct RestoreTests`):

1. `restoreFlagIsAWritingCommand`:
   `guard case .restore? = DebugCommand(arguments: ["YeeHaw", "--restore"]) else { Issue.record("--restore not parsed"); return }`
   then `#expect(DebugCommand(arguments: ["YeeHaw", "--restore"])?.isReadOnly == false)`.
   (`DebugCommand` isn't `Equatable`, so match with `case`.)
2. `everyCatchableQuitSignalQuitsTheOrdinaryWay`:
   `#expect(Set(YeeHawApp.quitSignals) == [SIGTERM, SIGINT, SIGHUP, SIGQUIT])`.
   Add `import Foundation` for the signal constants.
3. `failedQuitNamesTheAppsStillOff`:
   - `StatusItemController.quitFailure(stillOff: ["DigUp"]).message` contains `"switch DigUp back on"`.
   - With `["DigUp", "Tailscale"]` it contains `"DigUp and Tailscale"`.
   - With `["A", "B", "C"]` it contains `"A, B and C"`.
   - The title is `"Some icons are still hidden"`.
4. `failedQuitWithOnlyAPositionLeftSaysSo`: `quitFailure(stillOff: []).title == "YeeHaw couldn’t put an icon back in place"` (curly apostrophe).

The alert, the menu item and the live `--restore` run aren't unit-testable (AppKit modal and real
files). They're covered by the manual check below.

## Done criteria

- [ ] `swift build 2>&1 | grep -E "warning:|error:"` prints nothing
- [ ] `swift test 2>&1 | tail -n 3` shows the run passed with 456 tests (or starting count + 4); `swift test 2>&1 | grep -c "warning:"` prints `0`
- [ ] `grep -n "nonisolated static let quitSignals" Sources/YeeHaw/App/YeeHawApp.swift` prints one line
- [ ] `grep -n "case restore" Sources/YeeHaw/App/DebugCommand.swift` prints one line
- [ ] `grep -n "HiddenMenuBarApps.unhideAll" Sources/YeeHaw/App/DebugCommand.swift Sources/YeeHaw/UI/StatusItemController.swift` prints two lines
- [ ] `grep -rn "func unhideAll\|unhide()" Sources | grep -v HiddenMenuBarApps.swift` prints nothing (no second unhide helper was written)
- [ ] `git status --short` lists only files from the Scope section (and the untracked `plans/` folder)
- [ ] `git log --oneline` shows this plan's commits, each message ending with the `Co-Authored-By` line
- [ ] `plans/README.md` status row updated (if the file exists)

Manual check, only if the operator asks: `scripts/build-app.sh --install`, `pkill -x YeeHaw;
open ~/Applications/YeeHaw.app`, hide one icon, then `pkill -INT -x YeeHaw`. The icon is back, and
the log (`/usr/bin/log show --last 5m --predicate 'subsystem == "com.zapps.yeehaw"' --info --style compact`)
shows "Signal 2 received; quitting the ordinary way". Then open YeeHaw again (the icon hides
again) and run `kill -9 $(pgrep -x YeeHaw)`. The icon stays hidden. Next run
`~/Applications/YeeHaw.app/Contents/MacOS/YeeHaw --restore`, which prints `switched back on: …`,
and the icon is back.

## STOP conditions

Stop and report back (do not improvise) if:

- Step 0's grep finds nothing, or `unhideAll`'s signature differs from
  `unhideAll(menuBarOwners: Set<BundleID>, own: BundleID = …) -> [String]`. Don't write a second
  unhide helper here.
- The drift check shows changes to these files other than plan 001's two-line addition (for
  example plan 011 already landed and rewrote the launch checks).
- The compiler rejects the signal handler closure capturing `number`, or
  `nonisolated static let quitSignals`, and the fix would need `nonisolated(unsafe)` or `@preconcurrency`.
- `MenuBarController.quit()` turns out to need `launch()` first in the `--restore` path. For
  example, the manual check prints a `needsGrant` error even though the app has its grants.
  Report it; don't add a `launch()` call, since launch also re-hides apps.
- Making `--restore` work while another YeeHaw is running seems to need a change to
  `LaunchRules`. It should be refused then; that is intended.
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- `--restore` uses the app's own UserDefaults (the hidden list and journal). Run it from the
  installed bundle (`~/Applications/YeeHaw.app/Contents/MacOS/YeeHaw --restore`). An unbundled
  `.build/debug/YeeHaw` binary reads a different defaults domain and finds an empty journal.
- Restore keeps the user's hidden list, as Quit does. Opening YeeHaw again hides those apps again.
  If the owner wants Restore to also forget the hidden list ("start over"), that is a Core change
  (`Reconciler`/`MenuBarController`) and a separate plan.
- Reviewers: check that the Retry loop can't spin without the user answering (it only loops after
  `runModal` returns Retry), and that every path still ends in `NSApp.terminate(nil)`.
- Plan 011 (single-instance lock) edits the launch checks in `YeeHawApp.swift` next. `--restore` will
  hold that lock too, so it can't run beside a live YeeHaw.
