import Foundation

/// A running app that owns a third-party menu bar item (spec "Spacing Apply").
public struct RunningMenuBarApp: Equatable, Sendable {
    public var bundleID: BundleID
    /// The app bundle's path, e.g. `/Applications/DigUp.app`.
    public var bundlePath: String
    public var name: String
    /// Whether it has windows open, which a restart would interrupt: hidden (Command-H),
    /// minimized and other-Space windows count (see `SpacingPlan.hasOpenWindows`).
    public var hasOpenWindows: Bool
    /// Hidden with Command-H; it's reopened hidden too.
    public var isHidden: Bool
    /// When this process launched, which says the spacing it picked up.
    public var launchDate: Date?

    public init(bundleID: BundleID, bundlePath: String, name: String, hasOpenWindows: Bool,
                isHidden: Bool = false, launchDate: Date? = nil) {
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.name = name
        self.hasOpenWindows = hasOpenWindows
        self.isHidden = isHidden
        self.launchDate = launchDate
    }
}

/// An app Apply may restart, and whether its checkbox starts ticked.
public struct RelaunchCandidate: Equatable, Sendable {
    public var app: RunningMenuBarApp
    public var tickedByDefault: Bool

    public init(app: RunningMenuBarApp, tickedByDefault: Bool) {
        self.app = app
        self.tickedByDefault = tickedByDefault
    }
}

/// Menu bar spacing (spec Technique 4): the two current-host global preferences each app reads
/// when it launches, and which running apps Apply may restart so they pick a new value up.
public enum SpacingPlan {
    /// macOS's own value when neither preference is set.
    public static let defaultValue = 16
    /// `NSStatusItemSpacing` and `NSStatusItemSelectionPadding` both get this value.
    public static let range = 0...32
    public static let spacingKey = "NSStatusItemSpacing"
    public static let selectionPaddingKey = "NSStatusItemSelectionPadding"

    /// The apps Apply may restart, one per app in the order given. Never `com.apple.*`, never an
    /// app outside `/Applications` or `~/Applications` (`home` is the user's home folder), and
    /// never YeeHaw itself (`own`). Menu-bar-only apps start ticked; apps with open windows start
    /// unticked, since restarting them interrupts whatever is open.
    public static func candidates(_ apps: [RunningMenuBarApp], own: BundleID,
                                  home: String = NSHomeDirectory()) -> [RelaunchCandidate] {
        var seen: Set<BundleID> = []
        return apps.compactMap { app in
            guard !app.bundleID.hasPrefix("com.apple."), app.bundleID != own,
                  isInApplicationsFolder(app.bundlePath, home: home),
                  seen.insert(app.bundleID).inserted else { return nil }
            return RelaunchCandidate(app: app, tickedByDefault: !app.hasOpenWindows)
        }
    }

    /// Whether `path` is a bundle inside `/Applications` or `<home>/Applications` (subfolders
    /// included), after resolving `..` and the like.
    static func isInApplicationsFolder(_ path: String, home: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardized = (path as NSString).standardizingPath
        let folders = ["/Applications/", (home as NSString).standardizingPath + "/Applications/"]
        return folders.contains { folder in
            standardized.hasPrefix(folder) && standardized.count > folder.count
        }
    }

    public static func clamped(_ value: Int) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension SpacingPlan {
    /// Stands for a stored preference that isn't a number.
    public static let unreadable = Int.min

    /// A stored preference as an unclamped whole number: nil when unset, `unreadable` when it
    /// isn't a number.
    public static func storedValue(_ raw: Any?) -> Int? {
        switch raw {
        case nil:
            return nil
        case let number as NSNumber:
            let double = number.doubleValue
            return double.isFinite ? Int(max(min(double, 1e9), -1e9).rounded()) : unreadable
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces)) ?? unreadable
        default:
            return unreadable
        }
    }

    /// Whether restarting the app would interrupt open windows: whatever Accessibility lists
    /// (hidden and minimized windows too), anything on screen, and for a regular app, any window
    /// the window server knows of (it may be full screen in another Space, which Accessibility
    /// doesn't list; a false positive only leaves the app unticked). An accessory app's off-screen
    /// windows don't count: menu bar apps keep closed windows around. `exempt` holds processes
    /// YeeHaw hid itself after restarting them (some open their main window at launch); they
    /// count as windowless while they stay hidden.
    public static func hasOpenWindows(_ facts: WindowFacts, exempt: Set<Int32> = []) -> Bool {
        if facts.isHidden, exempt.contains(facts.pid) { return false }
        if let ax = facts.axWindows, ax > 0 { return true }
        if facts.onScreenWindows > 0 { return true }
        return facts.isRegular && facts.windowsAnywhere > 0
    }

    /// The apps owning a third-party item, once each: those drawn, in the bar's order, then the
    /// ones YeeHaw hides.
    public static func appOrder(drawn: [BundleID?], hidden: [BundleID]) -> [BundleID] {
        var order: [BundleID] = []
        var seen: Set<BundleID> = []
        for id in drawn.compactMap(\.self) + hidden where seen.insert(id).inserted {
            order.append(id)
        }
        return order
    }
}
