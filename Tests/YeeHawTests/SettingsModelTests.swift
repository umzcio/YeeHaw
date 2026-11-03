import Foundation
import ServiceManagement
import Testing
import YeeHawCore
@testable import YeeHaw

@MainActor
final class FakeLoginItem: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    /// What `register()` leaves the status at.
    var statusAfterRegister: SMAppService.Status = .enabled
    var failure: Error?
    private(set) var registers = 0
    private(set) var unregisters = 0
    private(set) var settingsOpened = 0

    func register() throws {
        registers += 1
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisters += 1
        if let failure { throw failure }
        status = .notRegistered
    }

    func openSystemSettingsLoginItems() { settingsOpened += 1 }
}

@MainActor
final class FakePermissions: PermissionSystem {
    var granted: Set<AppPermission> = []
    /// Permissions a fix grants (the file grants, picked in an open panel).
    var fixGrants: Set<AppPermission> = [.allowList, .layoutFile]
    private(set) var fixes: [AppPermission] = []

    func isGranted(_ permission: AppPermission) -> Bool { granted.contains(permission) }
    func fix(_ permission: AppPermission) async -> Bool {
        fixes.append(permission)
        guard fixGrants.contains(permission) else { return false }
        granted.insert(permission)
        return true
    }
}

@MainActor
@Suite struct LoginItemModelTests {
    @Test func reflectsTheService() {
        let service = FakeLoginItem()
        service.status = .enabled
        let model = LoginItemModel(service: service)
        #expect(model.isOn)
        #expect(!model.needsApproval)
    }

    @Test func turningOnRegistersOnce() {
        let service = FakeLoginItem()
        let model = LoginItemModel(service: service)
        model.setOn(true)
        model.setOn(true)
        #expect(service.registers == 1)
        #expect(model.isOn)
        #expect(model.error == nil)
    }

    @Test func turningOffUnregisters() {
        let service = FakeLoginItem()
        service.status = .enabled
        let model = LoginItemModel(service: service)
        model.setOn(false)
        #expect(service.unregisters == 1)
        #expect(!model.isOn)
    }

    @Test func aFailureLeavesItOffAndSaysSo() {
        let service = FakeLoginItem()
        service.failure = Boom()
        let model = LoginItemModel(service: service)
        model.setOn(true)
        #expect(!model.isOn)
        #expect(model.error != nil)
        service.failure = nil
        model.setOn(true)
        #expect(model.error == nil)
    }

    @Test func awaitingApprovalCountsAsOnAndOffersSettings() {
        let service = FakeLoginItem()
        service.statusAfterRegister = .requiresApproval
        let model = LoginItemModel(service: service)
        model.setOn(true)
        #expect(model.isOn)
        #expect(model.needsApproval)
        model.openLoginItems()
        #expect(service.settingsOpened == 1)
    }

    @Test func refreshPicksUpOutsideChanges() {
        let service = FakeLoginItem()
        let model = LoginItemModel(service: service)
        service.status = .enabled
        model.refresh()
        #expect(model.isOn)
    }
}

@MainActor
@Suite struct SettingsModelTests {
    static func model(granted: Set<AppPermission> = []) -> (FakePermissions, FakeOnboardingSystem, SettingsModel) {
        let permissions = FakePermissions()
        permissions.granted = granted
        let source = FakeOnboardingSystem()
        let model = SettingsModel(loginItem: LoginItemModel(service: FakeLoginItem()), permissions: permissions,
                                  review: SwitchedOffReviewModel(source: source))
        return (permissions, source, model)
    }

    @Test func permissionsAreListedInOrderWithScreenRecordingOptional() {
        #expect(AppPermission.allCases == [.accessibility, .allowList, .layoutFile, .screenRecording])
        #expect(AppPermission.allCases.filter(\.isOptional) == [.screenRecording])
    }

    @Test func statesFollowTheSystem() {
        let (_, _, model) = Self.model(granted: [.accessibility, .allowList])
        #expect(model.state(of: .accessibility) == .granted)
        #expect(model.state(of: .allowList) == .granted)
        #expect(model.state(of: .layoutFile) == .missing)
        #expect(model.state(of: .screenRecording) == .optionalOff)
    }

    @Test func fixingAGrantUpdatesItAndReportsIt() async {
        let (permissions, _, model) = Self.model(granted: [.accessibility])
        var fixed: [AppPermission] = []
        model.onGrantFixed = { fixed.append($0) }
        await model.fix(.layoutFile)
        #expect(permissions.fixes == [.layoutFile])
        #expect(model.state(of: .layoutFile) == .granted)
        #expect(fixed == [.layoutFile])
    }

    @Test func fixingASystemPermissionReportsNoGrant() async {
        let (permissions, _, model) = Self.model()
        var fixed: [AppPermission] = []
        model.onGrantFixed = { fixed.append($0) }
        await model.fix(.screenRecording)
        await model.fix(.accessibility)
        #expect(permissions.fixes == [.screenRecording, .accessibility])
        #expect(fixed.isEmpty)
        #expect(model.state(of: .screenRecording) == .optionalOff)
    }

    @Test func refreshSeesPermissionsGrantedElsewhere() {
        let (permissions, _, model) = Self.model()
        permissions.granted = [.accessibility, .screenRecording]
        model.refresh()
        #expect(model.state(of: .accessibility) == .granted)
        #expect(model.state(of: .screenRecording) == .granted)
    }

    @Test func reviewReopensTheSwitchedOffListUnticked() {
        let (_, source, model) = Self.model()
        source.switchedOffApps = [SwitchedOffReviewTests.app("OneDrive")]
        model.openReview()
        #expect(model.showsReview)
        #expect(model.review.apps.map(\.name) == ["OneDrive"])
        #expect(model.review.apps.allSatisfy { !$0.ticked })
    }

    @Test func thePollPicksUpSystemPermissionsAndLeavesFileGrantsAlone() {
        let (permissions, _, model) = Self.model(granted: [.allowList])
        permissions.granted = [.accessibility, .screenRecording, .layoutFile]
        model.refreshSystemPermissions()
        #expect(model.state(of: .accessibility) == .granted)
        #expect(model.state(of: .screenRecording) == .granted)
        // File grants are re-read only when the window opens or comes to the front.
        #expect(model.state(of: .allowList) == .granted)
        #expect(model.state(of: .layoutFile) == .missing)
        permissions.granted = []
        model.refreshSystemPermissions()
        #expect(model.state(of: .accessibility) == .missing)
        #expect(model.state(of: .screenRecording) == .optionalOff)
        #expect(model.state(of: .allowList) == .granted)
    }

    @Test func systemPermissionsAreFixedByOpeningTheirPane() {
        // Fix opens System Settings at the right pane (Accessibility registers YeeHaw first; see LivePermissionsTests); it never calls CGRequestScreenCaptureAccess.
        #expect(AppPermission.screenRecording.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(AppPermission.accessibility.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(AppPermission.allowList.settingsURL == nil)
        #expect(AppPermission.layoutFile.settingsURL == nil)
    }
}

@MainActor
@Suite struct FileAccessTests {
    final class Calls {
        var bookmarks: Set<GrantedFile> = []
        var flagged: Set<GrantedFile> = []
        var panelAnswer = true
        var readable: Set<GrantedFile> = []
        var log: [String] = []
    }

    static func access(_ calls: Calls) -> FileAccess {
        FileAccess(hasBookmark: { calls.bookmarks.contains($0) },
                   flagged: { calls.flagged },
                   requestGrant: { calls.log.append("panel \($0.rawValue)"); return calls.panelAnswer },
                   verify: { calls.log.append("read \($0.rawValue)"); return calls.readable.contains($0) })
    }

    @Test func aBookmarkAloneIsNotEnoughWhileTheControllerSaysAccessFails() {
        let calls = Calls()
        calls.bookmarks = [.allowList, .positions]
        calls.flagged = [.positions]
        let access = Self.access(calls)
        #expect(access.isUsable(.allowList))
        #expect(!access.isUsable(.positions))
        calls.bookmarks = []
        #expect(!access.isUsable(.allowList))
    }

    @Test func checkingReadsThroughTheGrant() async {
        let calls = Calls()
        calls.bookmarks = [.allowList, .positions]
        calls.readable = [.positions]
        let access = Self.access(calls)
        #expect(await !access.check(.allowList))
        #expect(await access.check(.positions))
        calls.bookmarks = []
        calls.log = []
        #expect(await !access.check(.positions))
        #expect(calls.log.isEmpty)
    }

    @Test func aGrantCountsOnlyOnceTheFileReads() async {
        let calls = Calls()
        let access = Self.access(calls)
        calls.readable = []
        #expect(await !access.grant(.allowList))
        #expect(calls.log == ["panel allowList", "read allowList"])
        calls.readable = [.allowList]
        #expect(await access.grant(.allowList))
        calls.panelAnswer = false
        calls.log = []
        #expect(await !access.grant(.positions))
        #expect(calls.log == ["panel positions"])
    }
}

@MainActor
@Suite struct LivePermissionsTests {
    static func permissions(_ calls: FileAccessTests.Calls) -> LivePermissions {
        LivePermissions(files: FileAccessTests.access(calls),
                        registerAccessibility: { calls.log.append("register") },
                        openURL: { calls.log.append("open \($0.absoluteString)") })
    }

    @Test func fixingAccessibilityRegistersYeeHawThenOpensThePane() async {
        let calls = FileAccessTests.Calls()
        let fixed = await Self.permissions(calls).fix(.accessibility)
        #expect(!fixed)
        #expect(calls.log == ["register",
                              "open x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    }

    @Test func fixingScreenRecordingOnlyOpensThePane() async {
        let calls = FileAccessTests.Calls()
        let fixed = await Self.permissions(calls).fix(.screenRecording)
        #expect(!fixed)
        #expect(calls.log == ["open x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"])
    }

    @Test func fixingAFileGrantNeverTouchesSystemSettings() async {
        let calls = FileAccessTests.Calls()
        calls.panelAnswer = false
        _ = await Self.permissions(calls).fix(.allowList)
        #expect(calls.log == ["panel allowList"])
    }
}
