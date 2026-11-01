import Foundation

/// Which `CFPreferences` host a global preference lives under. `NSStatusItemSpacing` is
/// normally a current-host (ByHost) preference, but `defaults write -globalDomain` without
/// `-currentHost` stores it for any host, and apps read that one when the current-host key is
/// unset.
public enum PreferenceHost: Hashable, Sendable {
    case current
    case any
}

/// One change Apply makes to a global preference; a nil value deletes the key.
public struct PreferenceWrite: Equatable, Sendable {
    public var host: PreferenceHost
    public var key: String
    public var value: Int?

    public init(host: PreferenceHost, key: String, value: Int?) {
        self.host = host
        self.key = key
        self.value = value
    }
}

/// Both spacing preferences as stored on both hosts (nil: unset; `SpacingPlan.unreadable`: set
/// to something that isn't a number).
public struct StoredSpacing: Equatable, Sendable {
    public var spacing: Int?
    public var padding: Int?
    public var anySpacing: Int?
    public var anyPadding: Int?

    public init(spacing: Int? = nil, padding: Int? = nil, anySpacing: Int? = nil, anyPadding: Int? = nil) {
        self.spacing = spacing
        self.padding = padding
        self.anySpacing = anySpacing
        self.anyPadding = anyPadding
    }

    /// The spacing apps launched from now on get: the current-host key, else the any-host one,
    /// else macOS's default.
    public var value: Int {
        let stored = spacing ?? anySpacing
        guard let stored, stored != SpacingPlan.unreadable else { return SpacingPlan.defaultValue }
        return SpacingPlan.clamped(stored)
    }

    /// What storing `value` takes: both current-host keys set to it, or for the default, every
    /// key deleted on both hosts, back to stock. Keys already right are left alone.
    public func writes(for value: Int) -> [PreferenceWrite] {
        let value = SpacingPlan.clamped(value)
        let target: Int? = value == SpacingPlan.defaultValue ? nil : value
        var writes: [PreferenceWrite] = []
        for (key, stored) in [(SpacingPlan.spacingKey, spacing), (SpacingPlan.selectionPaddingKey, padding)]
        where stored != target {
            writes.append(PreferenceWrite(host: .current, key: key, value: target))
        }
        // A current-host value overrides the any-host one, so those only matter for the default.
        if target == nil {
            for (key, stored) in [(SpacingPlan.spacingKey, anySpacing), (SpacingPlan.selectionPaddingKey, anyPadding)]
            where stored != nil {
                writes.append(PreferenceWrite(host: .any, key: key, value: nil))
            }
        }
        return writes
    }

    /// Whether the stored keys already say exactly `value`.
    public func isCanonical(for value: Int) -> Bool {
        writes(for: value).isEmpty
    }
}

/// The spacings YeeHaw has stored and when, so it can tell which running apps launched before
/// the last change and still draw the old spacing.
public struct SpacingHistory: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable {
        public var date: Date
        public var value: Int
    }

    /// How many changes are kept.
    public static let limit = 20

    /// The spacing before the oldest change kept.
    public private(set) var before: Int
    public private(set) var changes: [Change] = []

    public init(before: Int) {
        self.before = before
    }

    public mutating func record(_ value: Int, at date: Date) {
        changes.append(Change(date: date, value: value))
        if changes.count > Self.limit {
            before = changes.removeFirst().value
        }
    }

    /// The spacing an app launched at `date` picked up.
    public func spacing(atLaunch date: Date) -> Int {
        changes.last { $0.date <= date }?.value ?? before
    }

    /// The spacing an app launched at `date` picked up, as far as YeeHaw knows: nil when YeeHaw
    /// has never changed it (every app has what's stored), and the oldest known value when the
    /// launch date is unknown.
    public static func spacing(atLaunch date: Date?, history: SpacingHistory?) -> Int? {
        guard let history else { return nil }
        guard let date else { return history.before }
        return history.spacing(atLaunch: date)
    }
}

/// What the window server and Accessibility say about one app's windows.
public struct WindowFacts: Equatable, Sendable {
    public var pid: Int32
    /// Hidden, like Command-H.
    public var isHidden: Bool
    /// A regular app, with a Dock icon (not a menu-bar-only accessory app).
    public var isRegular: Bool
    /// Accessibility's window list for the current Space, minimized and hidden windows included;
    /// nil if it couldn't be read.
    public var axWindows: Int?
    /// Normal-level windows on screen now.
    public var onScreenWindows: Int
    /// Normal-level windows the window server knows of anywhere: other Spaces, minimized, hidden
    /// or ordered out.
    public var windowsAnywhere: Int

    public init(pid: Int32, isHidden: Bool, isRegular: Bool, axWindows: Int?, onScreenWindows: Int,
                windowsAnywhere: Int) {
        self.pid = pid
        self.isHidden = isHidden
        self.isRegular = isRegular
        self.axWindows = axWindows
        self.onScreenWindows = onScreenWindows
        self.windowsAnywhere = windowsAnywhere
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
