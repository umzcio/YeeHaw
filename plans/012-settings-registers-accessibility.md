# Plan 012: Settings' Accessibility "Fix…" adds YeeHaw to the Accessibility list before opening it

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. Do not improvise. When done, update the status row for this plan
> in `plans/README.md`, unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 495d26f..HEAD -- Sources/YeeHaw/System/Permissions.swift Sources/YeeHaw/UI/OnboardingModel.swift Tests/YeeHawTests/SettingsModelTests.swift`
> Expected: no output. If any file changed since this plan was written,
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

YeeHaw is a macOS 27.2 menu bar manager that needs Accessibility (macOS 27 calls the pane "Device
Control and Data Access"). macOS lists an app in that pane only after the app has asked with
`AXIsProcessTrustedWithOptions` and the prompt option; a plain `AXIsProcessTrusted()` check doesn't
add it. Onboarding does this before opening the pane, but Settings' "Fix…" button only opens the
pane. If YeeHaw's permission was ever removed (or reset with `tccutil`), Fix opens a pane with no
YeeHaw row to turn on, and the user is stuck. After this plan, Fix registers YeeHaw the same way
onboarding does, then opens the pane.

## Current state

- `Sources/YeeHaw/System/Permissions.swift`: `AppPermission` (rows in Settings), the
  `PermissionSystem` protocol, `FileAccess`, and `LivePermissions` (the real checks and fixes).
- `Sources/YeeHaw/UI/OnboardingModel.swift`: onboarding; `LiveOnboardingSystem` holds the
  registration call.
- `Sources/YeeHaw/App/YeeHawApp.swift:226` builds
  `LivePermissions(files: .live(grants: grants, controller: controller))`; that call keeps compiling
  if new init parameters have defaults.
- `Tests/YeeHawTests/SettingsModelTests.swift`: Settings tests, including `FileAccessTests`
  (lines 198-252) with its `Calls` recorder and `access(_:)` helper.

Settings' fix today:

```swift
// Permissions.swift:140-163
/// The real checks. None of them prompts: Screen Recording is read with
/// `CGPreflightScreenCaptureAccess` and fixed only in System Settings, never with
/// `CGRequestScreenCaptureAccess`.
@MainActor
final class LivePermissions: PermissionSystem {
    private let files: FileAccess

    init(files: FileAccess) {
        self.files = files
    }

    func isGranted(_ permission: AppPermission) -> Bool {
        switch permission {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .allowList, .layoutFile: return permission.file.map(files.isUsable) ?? false
        }
    }

    func fix(_ permission: AppPermission) async -> Bool {
        if let file = permission.file { return await files.grant(file) }
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
        return false
    }
}
```

Onboarding's registration (the behaviour to reuse):

```swift
// OnboardingModel.swift:118-122
    /// Registers YeeHaw with Accessibility first, so it's listed when the pane opens.
    func openAccessibility() {
        system.registerWithAccessibility()
        system.openAccessibilitySettings()
    }
// OnboardingModel.swift:201-207 (LiveOnboardingSystem)
    /// `AXIsProcessTrustedWithOptions` with the prompt option is what adds an app to the
    /// Accessibility list (a plain `AXIsProcessTrusted` doesn't). macOS shows its own prompt the
    /// first time, whose button opens the same pane; once trusted it's a plain check. The key is
    /// `kAXTrustedCheckOptionPrompt`'s value, which Swift 6 can't read from the global.
    func registerWithAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
```

Tests that describe the current behaviour by name or comment:

```swift
// SettingsModelTests.swift:143-152
    @Test func fixingASystemPermissionOnlyOpensSettings() async {
        let (permissions, _, model) = Self.model()
        ...
        #expect(permissions.fixes == [.screenRecording, .accessibility])
        #expect(fixed.isEmpty)
        #expect(model.state(of: .screenRecording) == .optionalOff)
    }
// SettingsModelTests.swift:187-195
    @Test func systemPermissionsAreFixedByOpeningTheirPane() {
        // Fix opens System Settings at the right pane; it never calls CGRequestScreenCaptureAccess.
        #expect(AppPermission.screenRecording.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        ...
```

`FakePermissions` (lines 32-46) replaces `LivePermissions` in `SettingsModelTests`, so
`LivePermissions.fix` itself has no test today.

Conventions:
- Doc comments (`///`) explain why, in plain sentences; match
  `Sources/YeeHaw/System/RevealCoordinator.swift`.
- Tests: Swift Testing, `@MainActor` suites; model the new suite on `FileAccessTests`.
- `AppPermission.fixHelp` for Accessibility ("Opens Privacy & Security in System Settings") stays
  accurate; leave it.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Build | `swift build 2>&1 \| grep -E "warning:\|error:"` | no output |
| Build tests | `swift build --build-tests 2>&1 \| grep -E "warning:\|error:"` | no output |
| Focused tests | `swift test --filter "SettingsModelTests\|LivePermissionsTests\|OnboardingModelTests" 2>&1 \| tail -n 3` | a line with `Test run with` ... `passed` |
| All tests | `swift test 2>&1 \| tail -n 3` | passed, no failures |

Don't run the app or click Fix for real: it would show macOS's Accessibility prompt.

## Scope

**In scope** (the only files you should modify):
- `Sources/YeeHaw/System/Permissions.swift`
- `Sources/YeeHaw/UI/OnboardingModel.swift` (`LiveOnboardingSystem.registerWithAccessibility` only)
- `Tests/YeeHawTests/SettingsModelTests.swift`
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- `OnboardingSystem` protocol and `FakeOnboardingSystem` (`Tests/YeeHawTests/OnboardingModelTests.swift`):
  onboarding already works and its tests stay as they are.
- Screen Recording's fix: it must keep only opening the pane (no `CGRequestScreenCaptureAccess`).
- `SettingsWindow.swift` and `AppPermission`'s titles and help strings.

## Git workflow

- From `build/yeehaw-v1`: `git checkout -b advisor/012-settings-registers-accessibility`
- Conventional commits, e.g. `fix: list YeeHaw in Accessibility before Settings opens the pane`.
  End every message with a blank line and
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No personal names. Do NOT push or open a PR.

## Steps

### Step 1: One shared registration call

In `Sources/YeeHaw/System/Permissions.swift`, above `LivePermissions`, add:

```swift
/// Adding YeeHaw to Privacy & Security → Accessibility.
enum AccessibilityRegistration {
    /// `AXIsProcessTrustedWithOptions` with the prompt option is what adds an app to the
    /// Accessibility list (a plain `AXIsProcessTrusted` doesn't). macOS shows its own prompt the
    /// first time, whose button opens the same pane; once trusted it's a plain check. The key is
    /// `kAXTrustedCheckOptionPrompt`'s value, which Swift 6 can't read from the global.
    @MainActor static func register() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
```

In `Sources/YeeHaw/UI/OnboardingModel.swift`, `LiveOnboardingSystem.registerWithAccessibility()`
(lines 201-207) becomes:

```swift
    /// See `AccessibilityRegistration.register`.
    func registerWithAccessibility() {
        AccessibilityRegistration.register()
    }
```

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -rn "AXTrustedCheckOptionPrompt" Sources` → exactly one line, in `Permissions.swift`

### Step 2: LivePermissions registers before opening the Accessibility pane

Change `LivePermissions` so the two side effects are injectable, with the live ones as defaults:

```swift
/// The real checks and fixes. The checks never prompt: Screen Recording is read with
/// `CGPreflightScreenCaptureAccess` and fixed only in System Settings, never with
/// `CGRequestScreenCaptureAccess`. Fixing Accessibility first registers YeeHaw
/// (`AccessibilityRegistration`), so the pane has a row to turn on even after the permission was
/// removed; macOS may show its own prompt then.
@MainActor
final class LivePermissions: PermissionSystem {
    private let files: FileAccess
    private let registerAccessibility: () -> Void
    private let openURL: (URL) -> Void

    init(files: FileAccess, registerAccessibility: @escaping () -> Void = AccessibilityRegistration.register,
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.files = files
        self.registerAccessibility = registerAccessibility
        self.openURL = openURL
    }

    // isGranted unchanged

    func fix(_ permission: AppPermission) async -> Bool {
        if let file = permission.file { return await files.grant(file) }
        if permission == .accessibility { registerAccessibility() }
        if let url = permission.settingsURL { openURL(url) }
        return false
    }
}
```

If the default argument `AccessibilityRegistration.register` doesn't compile because of actor
isolation, use `{ AccessibilityRegistration.register() }` instead. `NSWorkspace.open` returns a
`Bool`; the closure must discard it (`_ = NSWorkspace.shared.open($0)`) if the compiler warns.

**Verify**:
- `swift build 2>&1 | grep -E "warning:|error:"` → no output
- `grep -n "LivePermissions(files:" Sources/YeeHaw/App/YeeHawApp.swift` → still one line, unchanged

### Step 3: Tests

In `Tests/YeeHawTests/SettingsModelTests.swift`:

- Rename `fixingASystemPermissionOnlyOpensSettings` to `fixingASystemPermissionReportsNoGrant`;
  its body stays.
- In `systemPermissionsAreFixedByOpeningTheirPane`, change the comment to:
  `// Fix opens System Settings at the right pane (Accessibility registers YeeHaw first; see LivePermissionsTests); it never calls CGRequestScreenCaptureAccess.`
- Add the new suite from the Test plan at the end of the file.

**Verify**:
- `swift test --filter "SettingsModelTests|LivePermissionsTests|OnboardingModelTests|FileAccessTests" 2>&1 | tail -n 3` → passed
- `swift build --build-tests 2>&1 | grep -E "warning:|error:"` → no output
- `swift test 2>&1 | tail -n 3` → passed

## Test plan

New suite at the end of `Tests/YeeHawTests/SettingsModelTests.swift`:

```swift
@MainActor
@Suite struct LivePermissionsTests {
    static func permissions(_ calls: FileAccessTests.Calls) -> LivePermissions {
        LivePermissions(files: FileAccessTests.access(calls),
                        registerAccessibility: { calls.log.append("register") },
                        openURL: { calls.log.append("open \($0.absoluteString)") })
    }
    ...
}
```

(`FileAccessTests.Calls` and `FileAccessTests.access(_:)` exist at lines 200-213; reuse them. If
`Calls` or `access` aren't visible from another suite, make them `static`/internal rather than
private; they're already internal at 495d26f.)

Tests:
1. `fixingAccessibilityRegistersYeeHawThenOpensThePane` (async):
   `let calls = FileAccessTests.Calls()`, `let fixed = await Self.permissions(calls).fix(.accessibility)`
   → `!fixed`, `calls.log == ["register", "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]`.
2. `fixingScreenRecordingOnlyOpensThePane` (async): `fix(.screenRecording)` →
   `calls.log == ["open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]` (no "register").
3. `fixingAFileGrantNeverTouchesSystemSettings` (async): `calls.panelAnswer = false`;
   `fix(.allowList)` → `calls.log == ["panel allowList"]`.

Verification: `swift test --filter LivePermissionsTests 2>&1 | tail -n 3` → passed, 3 tests.

## Done criteria

All must hold:

- [ ] `swift build --build-tests 2>&1 | grep -E "warning:|error:"` prints nothing (0 warnings)
- [ ] `swift test 2>&1 | tail -n 3` reports the run passed, including the 3 new `LivePermissionsTests`
- [ ] `grep -rn "AXTrustedCheckOptionPrompt" Sources` prints exactly one line
- [ ] `grep -n "if permission == .accessibility { registerAccessibility() }" Sources/YeeHaw/System/Permissions.swift` prints one line
- [ ] `grep -n "fixingASystemPermissionOnlyOpensSettings" Tests/YeeHawTests/SettingsModelTests.swift` prints nothing
- [ ] `git status --short` lists only in-scope files
- [ ] `plans/README.md` row 012 updated

## STOP conditions

Stop and report back (do not improvise) if:

- `LivePermissions` or `LiveOnboardingSystem.registerWithAccessibility` don't match the excerpts.
- `LivePermissions` is constructed anywhere besides `YeeHawApp.swift:226`
  (`grep -rn "LivePermissions(" Sources`) in a way the defaults don't cover.
- Making `FileAccessTests.Calls`/`access` usable from the new suite needs more than removing a
  `private`.
- Any onboarding test changes behaviour (`OnboardingModelTests` must pass untouched).
- A verification fails twice after a reasonable fix attempt.

## Maintenance notes

- Registration shows macOS's own Accessibility prompt the first time it runs for a given build
  signature. That's the same prompt onboarding shows, and Fix is a deliberate click, so it's
  expected.
- A new system permission with a "register first" step should follow the same pattern: an
  injectable side effect in `LivePermissions` with the live call as its default.
- Reviewers: confirm Screen Recording still never calls `CGRequestScreenCaptureAccess`
  (`grep -rn "CGRequestScreenCaptureAccess" Sources` prints nothing).
