import Foundation

/// A running menu bar app whose icon may open nothing, and what would fix it.
public enum HealthIssue: Equatable, Sendable {
    /// Hidden, like Command-H. A hidden app still gets its icon's clicks but can't show the panel
    /// or popover they open. Unhiding fixes it.
    case hidden(BundleID)
    /// Its icon was pressed `MenuBarHealth.stuckAfter` times in a row and nothing opened.
    /// Restarting it usually fixes it.
    case stuck(BundleID)

    public var id: BundleID {
        switch self {
        case .hidden(let id), .stuck(let id): id
        }
    }
}

/// Notices running menu bar apps that can't show what their icon opens, so the strip can offer
/// the fix. Only remembers how many reveals in a row opened nothing; whether an app is hidden is
/// read fresh each time (`issue(among:own:home:)`).
public struct MenuBarHealth: Equatable, Sendable {
    /// Reveals in a row that opened nothing before an app counts as stuck. One could be a click
    /// on an icon that opens nothing by design; two in a row is worth a word.
    public static let stuckAfter = 2

    private var misses: [BundleID: Int] = [:]

    public init() {}

    /// Call when a reveal of `id` pressed its icon: `opened` is whether a menu or window appeared.
    public mutating func recordReveal(_ id: BundleID, opened: Bool) {
        if opened { misses[id] = nil } else { misses[id, default: 0] += 1 }
    }

    /// Call once the app was unhidden or restarted: it starts afresh.
    public mutating func forget(_ id: BundleID) {
        misses[id] = nil
    }

    public func isStuck(_ id: BundleID) -> Bool {
        misses[id, default: 0] >= Self.stuckAfter
    }

    /// The issue to show, if any, among the running copies of apps that own a menu bar item
    /// (`apps`, in the order to name them): a hidden menu-bar-only app first, else a stuck app.
    /// Hidden uses `SpacingPlan.shouldUnhide` with no owners, so a regular app someone hid with
    /// Command-H never counts.
    public func issue(among apps: [RunningAppFacts], own: BundleID,
                      home: String = NSHomeDirectory()) -> HealthIssue? {
        if let hidden = apps.first(where: { SpacingPlan.shouldUnhide($0, menuBarOwners: [], own: own, home: home) }) {
            return .hidden(hidden.bundleID)
        }
        if let stuck = apps.first(where: { $0.bundleID != own && isStuck($0.bundleID) }) {
            return .stuck(stuck.bundleID)
        }
        return nil
    }
}
