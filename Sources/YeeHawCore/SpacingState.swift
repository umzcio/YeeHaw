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
/// the last change and still draw the old spacing. Only YeeHaw's own changes are recorded; one
/// made outside it (`defaults write`, `defaults delete`) is noticed when the stored value no
/// longer matches `latest`, and the history starts again from then (`reconciled`).
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
    /// When the history starts: an app launched earlier draws an unknown spacing. Nil when it
    /// reaches back to YeeHaw's first change, before which every app had `before`.
    public private(set) var since: Date?

    public init(before: Int, since: Date? = nil) {
        self.before = before
        self.since = since
    }

    /// The spacing the history says is stored now.
    public var latest: Int {
        changes.last?.value ?? before
    }

    /// `history` if it still matches the `stored` value, else a fresh one starting at `date`
    /// with that value: something outside YeeHaw changed the spacing at an unknown time, so
    /// apps launched before `date` draw an unknown spacing.
    public static func reconciled(_ history: SpacingHistory?, stored: Int, at date: Date) -> SpacingHistory? {
        guard let history, history.latest != stored else { return history }
        return SpacingHistory(before: stored, since: date)
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
    /// has never changed it (every app has what's stored) or the app launched before the history
    /// starts, and the oldest known value when the launch date is unknown.
    public static func spacing(atLaunch date: Date?, history: SpacingHistory?) -> Int? {
        guard let history else { return nil }
        if let since = history.since {
            guard let date, date >= since else { return nil }
        }
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
