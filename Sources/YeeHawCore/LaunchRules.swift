import Foundation

/// The decisions YeeHaw makes as it starts and stops, kept free of AppKit so they can be tested:
/// whether it may run at all, what it does in which order, and whether quitting switches hidden
/// apps back on.
public enum LaunchRules {
    /// Live switching works from macOS 27.2 (spec "Why 27.2 is the minimum").
    public static let minimumSystem = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)
    /// Thaw writes the same two preference files.
    public static let thawBundleID = "com.stonerl.Thaw"

    public enum Outcome: Equatable, Sendable {
        case proceed
        case refuse(Refusal)
    }

    public enum Refusal: Equatable, Sendable {
        /// `found` is the running version, as "27.0.1".
        case unsupportedSystem(found: String)
        case thawRunning
        /// Another copy of YeeHaw is already running; two would overwrite each other's record of
        /// what they switched off.
        case alreadyRunning

        public var title: String {
            switch self {
            case .unsupportedSystem: "YeeHaw needs macOS 27.2 or later"
            case .thawRunning: "Quit Thaw first"
            case .alreadyRunning: "YeeHaw is already running"
            }
        }

        public var message: String {
            switch self {
            case .unsupportedSystem(let found):
                return "This Mac has macOS \(found). YeeHaw shows and hides menu bar icons in a way that "
                    + "only works from macOS 27.2. Update macOS in System Settings → General → Software Update, "
                    + "then open YeeHaw again."
            case .thawRunning:
                return "Thaw is running, and both apps change the same settings. Quit Thaw, then open YeeHaw again."
            case .alreadyRunning:
                return "Another copy of YeeHaw is open, and its hat is in the menu bar. Use that one, "
                    + "or quit it before opening this copy."
            }
        }
    }

    /// Whether YeeHaw may start: the system is checked first, then whether Thaw is running, then
    /// whether another copy of YeeHaw already is (`isAnotherInstance`).
    public static func check(os: OperatingSystemVersion, running: Set<String>,
                             anotherInstance: Bool = false) -> Outcome {
        let current = (os.majorVersion, os.minorVersion, os.patchVersion)
        let minimum = (minimumSystem.majorVersion, minimumSystem.minorVersion, minimumSystem.patchVersion)
        if current < minimum {
            return .refuse(.unsupportedSystem(found: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        }
        if running.contains(thawBundleID) { return .refuse(.thawRunning) }
        if anotherInstance { return .refuse(.alreadyRunning) }
        return .proceed
    }

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

    public enum Step: Equatable, Sendable {
        /// Undoes a reveal a crash left drawn (`MenuBarController.endReveal`), so it isn't left
        /// showing for as long as onboarding stays open.
        case endPendingReveal
        /// The first-run window: permissions, grants, switched-off apps, YeeHaw's own place.
        case onboarding
        /// `MenuBarController.launch()`: reconcile crash leftovers and hide what's hidden.
        case launchController
        /// YeeHaw's own icon and its strip.
        case showStatusItem
    }

    /// What a launch that passed `check` does, in order. Onboarding comes first so the controller
    /// starts with its grants, and the icon last so it appears where onboarding placed it. A
    /// reveal left by a crash is undone first when onboarding would delay the launch that
    /// otherwise restores it.
    public static func steps(onboardingComplete: Bool, pendingReveal: Bool = false) -> [Step] {
        if onboardingComplete { return [.launchController, .showStatusItem] }
        return (pendingReveal ? [.endPendingReveal] : []) + [.onboarding, .launchController, .showStatusItem]
    }

    /// Why YeeHaw is being asked to quit, from the quit Apple event's `kAEQuitReason` attribute.
    public enum QuitReason: Equatable, Sendable {
        case ordinary, logout, restart, shutdown

        /// `code` is the attribute's enum value (nil when the event has none, or there's no
        /// event: the app menu's Quit, the status menu's Quit YeeHaw).
        public init(code: UInt32?) {
            switch code {
            case Self.fourCC("logo"), Self.fourCC("rlgo"): self = .logout        // kAELogOut, kAEReallyLogOut
            case Self.fourCC("rrst"), Self.fourCC("rest"): self = .restart       // kAEShowRestartDialog, kAERestart
            case Self.fourCC("rsdn"), Self.fourCC("shut"): self = .shutdown      // kAEShowShutdownDialog, kAEShutDown
            default: self = .ordinary
            }
        }

        private static func fourCC(_ text: StaticString) -> UInt32 {
            text.withUTF8Buffer { $0.reduce(0) { $0 << 8 | UInt32($1) } }
        }
    }

    /// An ordinary quit switches back on every app YeeHaw switched off. At logout, restart or
    /// shutdown they stay off and stay in the journal, so the next login doesn't flash every icon
    /// before YeeHaw starts and that launch reconciles (spec "Logout and shutdown"), but only when
    /// YeeHaw opens at login (`opensAtLogin`: the login item is enabled, not merely waiting for
    /// approval). Otherwise nothing would start it again, so they're switched back on as for an
    /// ordinary quit.
    ///
    /// Known gap: when another app cancels a logout after YeeHaw has quit, the user stays logged in
    /// with those apps hidden until YeeHaw is opened again, which Open at Login doesn't do mid-session.
    public static func switchesBackOnAtTermination(_ reason: QuitReason, opensAtLogin: Bool) -> Bool {
        reason == .ordinary || !opensAtLogin
    }
}
