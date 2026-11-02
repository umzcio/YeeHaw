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

    /// The one word for a permission YeeHaw has, in Settings and onboarding alike.
    static let grantedStatus = "Allowed"
    /// The button that opens a file's grant panel (with the file already selected), in both windows.
    static let grantActionTitle = "Grant Access…"

    /// Settings' button for a permission YeeHaw doesn't have.
    var fixTitle: String {
        switch self {
        case .accessibility: "Fix…"
        case .allowList, .layoutFile: Self.grantActionTitle
        case .screenRecording: "Turn On…"
        }
    }

    var fixHelp: String {
        switch self {
        case .allowList, .layoutFile: "Opens the file panel with the file already selected"
        case .accessibility, .screenRecording: "Opens Privacy & Security in System Settings"
        }
    }

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

/// Whether YeeHaw can really use a protected file, not just whether its bookmark resolves: the
/// controller records `needsGrant` when a read or write fails with a resolvable bookmark (a nil
/// read, a refused synchronize), and a fresh grant only counts once the file reads through it.
/// Shared by Settings' rows and onboarding's grant steps.
@MainActor
struct FileAccess {
    var hasBookmark: (GrantedFile) -> Bool
    /// The controller's `state.needsGrant`.
    var flagged: () -> Set<GrantedFile>
    /// The open panel; true when the user picked the file.
    var requestGrant: (GrantedFile) async -> Bool
    /// One read through the grant (`MenuBarController.verifyAccess`), which also clears or
    /// records `needsGrant`.
    var verify: (GrantedFile) async -> Bool

    /// Quick, for a status shown at once: a bookmark, and no failure recorded since.
    func isUsable(_ file: GrantedFile) -> Bool {
        hasBookmark(file) && !flagged().contains(file)
    }

    /// Thorough: a bookmark, and the file reads through it now.
    func check(_ file: GrantedFile) async -> Bool {
        guard hasBookmark(file) else { return false }
        return await verify(file)
    }

    /// Asks for the file, then reads it, so a pick that doesn't give access isn't reported as one.
    func grant(_ file: GrantedFile) async -> Bool {
        guard await requestGrant(file) else { return false }
        return await verify(file)
    }

    static func live(grants: FileGrantStore, controller: MenuBarController) -> FileAccess {
        FileAccess(hasBookmark: { grants.hasGrant($0) },
                   flagged: { controller.state.needsGrant },
                   requestGrant: { await grants.requestGrant(for: $0) },
                   verify: { await controller.verifyAccess($0) })
    }
}

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
