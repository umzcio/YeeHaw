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
    func runningBundleIDs() async -> Set<BundleID>
    /// `PositionKey.prefixes` for the app, drawn or not (the executable name comes from the
    /// running app); just the bundle ID when it isn't running.
    func keyPrefixes(of id: BundleID) async -> [String]
}

public protocol Sleeper: Sendable { func sleep(seconds: Double) async }
