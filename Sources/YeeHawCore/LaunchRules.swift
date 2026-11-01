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
        /// The first-run window: permissions, grants, switched-off apps, YeeHaw's own place.
        case onboarding
        /// `MenuBarController.launch()`: reconcile crash leftovers and hide what's hidden.
        case launchController
        /// YeeHaw's own icon and its strip.
        case showStatusItem
    }

    /// What a launch that passed `check` does, in order. Onboarding comes first so the controller
    /// starts with its grants, and the icon last so it appears where onboarding placed it.
    public static func steps(onboardingComplete: Bool) -> [Step] {
        (onboardingComplete ? [] : [.onboarding]) + [.launchController, .showStatusItem]
    }

    /// An ordinary quit switches back on every app YeeHaw switched off. At logout, restart or
    /// shutdown they stay off and stay in the journal, so the next login doesn't flash every icon
    /// before YeeHaw starts; that launch reconciles (spec "Logout and shutdown").
    public static func switchesBackOnAtTermination(poweringOff: Bool) -> Bool {
        !poweringOff
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
