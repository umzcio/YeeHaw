public typealias BundleID = String

public protocol StateStoring: Sendable {
    func load() -> HidingState
    func save(_ s: HidingState)
}

/// One of the two protected preference files YeeHaw edits.
public protocol PreferencesFile: Sendable {
    /// Throws `GrantError.needsGrant` when access fails.
    func read(_ key: String) throws -> Any?
    func write(_ key: String, _ value: Any) throws
}

public enum GrantError: Error { case needsGrant(GrantedFile) }

public protocol MenuBarReading: Sendable {
    /// What is drawn right now, left to right.
    func items() async -> [MenuBarItem]
    /// `items()`, knowing which apps are switched off and which one a reveal is switching on or
    /// off: stale frames of the off apps are only matched after every other app's, and the
    /// revealed app's between the two (`ItemMatcher.match(drawn:extras:offApps:revealed:)`).
    func items(offApps: Set<BundleID>, revealed: BundleID?) async -> [MenuBarItem]
    /// Everything drawn right now, left to right, with only `id`'s items given an owner: a reader
    /// can answer this much faster than `items()` by reading only the drawn bar and that app's own
    /// items, so reveals poll it. Since nobody else's extras are read, a stale frame of `id`'s can
    /// claim another app's icon; `ItemMatcher.ownItems` sorts that out.
    func drawnBar(owning id: BundleID) async -> [MenuBarItem]
    func runningBundleIDs() async -> Set<BundleID>
    /// `PositionKey.prefixes` for the app, drawn or not (the executable name comes from the
    /// running app); just the bundle ID when it isn't running.
    func keyPrefixes(of id: BundleID) async -> [String]
}

extension MenuBarReading {
    public func items(offApps: Set<BundleID>, revealed: BundleID?) async -> [MenuBarItem] {
        await items()
    }

    public func drawnBar(owning id: BundleID) async -> [MenuBarItem] {
        await items()
    }
}

public protocol Sleeper: Sendable { func sleep(seconds: Double) async }
