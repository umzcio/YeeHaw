import AppKit
import ApplicationServices
import YeeHawCore

/// What YeeHaw needs from macOS, as Settings lists it.
enum AppPermission: CaseIterable, Identifiable, Hashable {
    case accessibility, allowList, layoutFile, screenRecording

    var id: Self { self }

    /// macOS 27's names for the panes (Privacy & Security), and the files' plain names.
    var title: String {
        switch self {
        case .accessibility: "Device Control and Data Access"
        case .allowList: "Menu Bar Allow List"
        case .layoutFile: "Menu Bar Layout"
        case .screenRecording: "Screen Recording"
        }
    }

    var detail: String {
        switch self {
        case .accessibility: "Reads which icons are in the menu bar and opens hidden ones"
        case .allowList: "Hides and shows apps’ icons"
        case .layoutFile: "Arranges icons and opens hidden ones next to YeeHaw"
        case .screenRecording: "Optional. Shows icons’ real images in the strip"
        }
    }

    var isOptional: Bool { self == .screenRecording }

    /// An SF Symbol for the row's icon tile.
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .allowList: "checklist"
        case .layoutFile: "arrow.left.arrow.right"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    /// The protected file a grant opens, for the two file permissions.
    var file: GrantedFile? {
        switch self {
        case .allowList: .allowList
        case .layoutFile: .positions
        case .accessibility, .screenRecording: nil
        }
    }

    /// The Privacy & Security pane Fix opens, for the two system permissions. The anchors are the
    /// ones System Settings' Privacy & Security extension declares on 27.2.
    var settingsURL: URL? {
        switch self {
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .allowList, .layoutFile: nil
        }
    }
}

/// Checks and fixes permissions.
@MainActor
protocol PermissionSystem: AnyObject {
    func isGranted(_ permission: AppPermission) -> Bool
    /// Asks for the permission: an open panel for a file grant, System Settings for the others.
    /// Returns true when it's granted as a result (only a file grant can be, right away).
    func fix(_ permission: AppPermission) async -> Bool
}

/// The real checks. None of them prompts: Screen Recording is read with
/// `CGPreflightScreenCaptureAccess` and fixed only in System Settings, never with
/// `CGRequestScreenCaptureAccess`.
@MainActor
final class LivePermissions: PermissionSystem {
    private let grants: FileGrantStore

    init(grants: FileGrantStore) {
        self.grants = grants
    }

    func isGranted(_ permission: AppPermission) -> Bool {
        switch permission {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .allowList, .layoutFile:
            guard let file = permission.file, let url = grants.url(for: file) else { return false }
            url.stopAccessingSecurityScopedResource()
            return true
        }
    }

    func fix(_ permission: AppPermission) async -> Bool {
        if let file = permission.file { return await grants.requestGrant(for: file) }
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
        return false
    }
}
