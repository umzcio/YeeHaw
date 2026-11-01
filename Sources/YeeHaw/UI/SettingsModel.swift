import AppKit
import os
import ServiceManagement
import YeeHawCore

/// Opening YeeHaw at login (`SMAppService.mainApp`).
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
final class MainAppLoginItem: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

/// The "Open at Login" switch. Waiting for approval in System Settings counts as on: YeeHaw asked,
/// and the note says what's left to do.
@MainActor
@Observable
final class LoginItemModel {
    private(set) var status: SMAppService.Status
    private(set) var error: String?

    @ObservationIgnored private let service: LoginItemService
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "settings")

    init(service: LoginItemService) {
        self.service = service
        status = service.status
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func setOn(_ on: Bool) {
        refresh()
        guard on != isOn else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            error = nil
        } catch {
            self.error = on ? "YeeHaw couldn’t add itself to your login items." : "YeeHaw couldn’t remove itself from your login items."
            Self.log.error("Login item change failed: \(error, privacy: .public)")
        }
        status = service.status
    }

    func refresh() {
        status = service.status
    }

    func openLoginItems() {
        service.openSystemSettingsLoginItems()
    }
}

/// The Settings window's state: open at login, each permission's status with its fix, and the
/// switched-off apps review.
@MainActor
@Observable
final class SettingsModel {
    enum PermissionState: Equatable {
        case granted, missing, optionalOff
    }

    let loginItem: LoginItemModel
    let review: SwitchedOffReviewModel
    private(set) var granted: Set<AppPermission> = []
    private(set) var fixing: AppPermission?
    var showsReview = false

    /// Called after a file grant was fixed, so the controller can launch with it.
    @ObservationIgnored var onGrantFixed: ((AppPermission) -> Void)?

    @ObservationIgnored private let permissions: PermissionSystem

    init(loginItem: LoginItemModel, permissions: PermissionSystem, review: SwitchedOffReviewModel) {
        self.loginItem = loginItem
        self.permissions = permissions
        self.review = review
        refresh()
    }

    func refresh() {
        granted = Set(AppPermission.allCases.filter(permissions.isGranted))
        loginItem.refresh()
    }

    /// Re-reads the two system permissions, which change in System Settings (polled while open).
    func refreshSystemPermissions() {
        var next = granted
        for permission in [AppPermission.accessibility, .screenRecording] {
            if permissions.isGranted(permission) { next.insert(permission) } else { next.remove(permission) }
        }
        if next != granted { granted = next }
    }

    func state(of permission: AppPermission) -> PermissionState {
        if granted.contains(permission) { return .granted }
        return permission.isOptional ? .optionalOff : .missing
    }

    func fix(_ permission: AppPermission) async {
        guard fixing == nil else { return }
        fixing = permission
        defer { fixing = nil }
        let fixed = await permissions.fix(permission)
        refresh()
        if fixed, permission.file != nil { onGrantFixed?(permission) }
    }

    func openReview() {
        review.reload()
        showsReview = true
    }
}
