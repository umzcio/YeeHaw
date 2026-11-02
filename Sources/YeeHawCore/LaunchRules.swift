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

        public var title: String {
            switch self {
            case .unsupportedSystem: "YeeHaw needs macOS 27.2 or later"
            case .thawRunning: "Quit Thaw first"
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
            }
        }
    }

    /// Whether YeeHaw may start: the system is checked first, then whether Thaw is running.
    public static func check(os: OperatingSystemVersion, running: Set<String>) -> Outcome {
        let current = (os.majorVersion, os.minorVersion, os.patchVersion)
        let minimum = (minimumSystem.majorVersion, minimumSystem.minorVersion, minimumSystem.patchVersion)
        if current < minimum {
            return .refuse(.unsupportedSystem(found: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"))
        }
        if running.contains(thawBundleID) { return .refuse(.thawRunning) }
        return .proceed
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
    /// before YeeHaw starts; that launch reconciles (spec "Logout and shutdown"). Decided from
    /// the quit itself, so a logout another app cancelled leaves no trace on a later quit.
    public static func switchesBackOnAtTermination(_ reason: QuitReason) -> Bool {
        reason == .ordinary
    }
}

/// Where YeeHaw's own icon sits relative to Control Center.
public enum OwnIconPlacement {
    public static let controlCenterIdentifier = "com.apple.menuextra.controlcenter"

    /// True when one of `ownID`'s drawn items is immediately left of Control Center (by position;
    /// each display's copy of the bar counts on its own).
    public static func isNextToControlCenter(_ items: [MenuBarItem], ownID: BundleID) -> Bool {
        let sorted = items.sorted { $0.x < $1.x }
        return zip(sorted, sorted.dropFirst()).contains { left, right in
            left.bundleID == ownID && right.appleIdentifier == controlCenterIdentifier
        }
    }
}
