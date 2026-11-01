import Foundation

/// A running app that owns a third-party menu bar item (spec "Spacing Apply").
public struct RunningMenuBarApp: Equatable, Sendable {
    public var bundleID: BundleID
    /// The app bundle's path, e.g. `/Applications/DigUp.app`.
    public var bundlePath: String
    public var name: String
    /// Whether it has windows open, which a restart would interrupt.
    public var hasVisibleWindows: Bool

    public init(bundleID: BundleID, bundlePath: String, name: String, hasVisibleWindows: Bool) {
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.name = name
        self.hasVisibleWindows = hasVisibleWindows
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
    public static let keys = [spacingKey, selectionPaddingKey]

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
            return RelaunchCandidate(app: app, tickedByDefault: !app.hasVisibleWindows)
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

    /// What to store for `value`: both keys get it, except that the default deletes them (nil),
    /// returning the Mac to stock rather than pinning a stored 16.
    public static func preferenceValues(for value: Int) -> [String: Int?] {
        let value = clamped(value)
        let stored: Int? = value == defaultValue ? nil : value
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, stored) })
    }

    /// The spacing a stored preference stands for: a number or numeric string (as
    /// `defaults write` stores it without `-int`), clamped into `range`; the default when unset
    /// or unreadable.
    public static func value(fromPreference raw: Any?) -> Int {
        switch raw {
        case let number as NSNumber:
            return clamped(Int(number.doubleValue.rounded()))
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespaces)).map(clamped) ?? defaultValue
        default:
            return defaultValue
        }
    }
}
