public struct PendingReveal: Codable, Equatable, Sendable {
    public var bundleID: BundleID
    /// Position values to restore after a reveal; a nil value means "remove that key".
    public var originalPositions: [String: Double?]

    public init(bundleID: BundleID, originalPositions: [String: Double?]) {
        self.bundleID = bundleID
        self.originalPositions = originalPositions
    }
}

public enum GrantedFile: String, Codable, Sendable { case allowList, positions }

public struct HidingState: Codable, Equatable, Sendable {
    /// Strip order of the apps the user hid.
    public var hidden: [BundleID]
    /// Apps YeeHaw itself switched off.
    public var journal: Set<BundleID>
    public var pendingReveal: PendingReveal?
    public var needsGrant: Set<GrantedFile>

    public init(
        hidden: [BundleID] = [], journal: Set<BundleID> = [],
        pendingReveal: PendingReveal? = nil, needsGrant: Set<GrantedFile> = []
    ) {
        self.hidden = hidden
        self.journal = journal
        self.pendingReveal = pendingReveal
        self.needsGrant = needsGrant
    }

    public static let empty = HidingState()

    private enum CodingKeys: String, CodingKey { case hidden, journal, pendingReveal, needsGrant }

    /// Every field may be missing (a state saved by an older YeeHaw), so a newer field never
    /// makes the whole record unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try c.decodeIfPresent([BundleID].self, forKey: .hidden) ?? []
        journal = try c.decodeIfPresent(Set<BundleID>.self, forKey: .journal) ?? []
        pendingReveal = try c.decodeIfPresent(PendingReveal.self, forKey: .pendingReveal)
        needsGrant = try c.decodeIfPresent(Set<GrantedFile>.self, forKey: .needsGrant) ?? []
    }
}

public enum AllowAction: Equatable, Sendable {
    case switchOn(BundleID), switchOff(BundleID)
    /// Lists a running copy in the app's `menuItemLocations`, so its switch reaches that copy.
    case addLocation(BundleID, AllowLocation)
}

/// Pure rules deciding which Allow switches to flip and how the persisted state changes.
/// Actions are ordered: every `.addLocation` (in `hidden` order), every `.switchOff` (in `hidden`
/// order), then every `.switchOn` (sorted). `locations` are the Allow-list locations of the app's
/// running copies (`RunningCopy.location`): an app's switch is written with them listed.
public enum Reconciler {
    /// The running copies of every app that stays hidden are listed, even if it's off already.
    public static func onLaunch(
        _ s: HidingState, allow: AllowSnapshot, locations: [BundleID: [AllowLocation]] = [:]
    ) -> (actions: [AllowAction], restorePositions: [String: Double?], state: HidingState) {
        var state = s
        // An app that's off but not in the journal was switched off by the user, even if it's in
        // Hidden (they did it while YeeHaw wasn't running): Apple's switch wins, and it's theirs.
        state.hidden = s.hidden.filter { allow[$0] == true || (allow[$0] == false && s.journal.contains($0)) }
        let hiddenSet = Set(state.hidden)
        let offs = state.hidden.filter { allow[$0] == true }
        let ons = s.journal.filter { allow[$0] != nil && !hiddenSet.contains($0) }.sorted()
        // An app whose entry is missing can't be switched on now; it stays journaled, so it's
        // switched on once macOS lists it again.
        state.journal = s.journal.filter { hiddenSet.contains($0) || allow[$0] == nil }.union(offs)
        let restore = s.pendingReveal?.originalPositions ?? [:]
        state.pendingReveal = nil
        let listed = state.hidden.flatMap { id in listing(id, locations[id] ?? []) }
        return (listed + offs.map(AllowAction.switchOff) + ons.map(AllowAction.switchOn), restore, state)
    }

    /// Switches the journal back on and puts a revealed app's positions back, so nothing is left
    /// at the reveal slot next to YeeHaw's icon once it's gone.
    public static func onQuit(
        _ s: HidingState
    ) -> (actions: [AllowAction], restorePositions: [String: Double?], state: HidingState) {
        var state = s
        state.journal = []
        state.pendingReveal = nil
        return (s.journal.sorted().map(AllowAction.switchOn), s.pendingReveal?.originalPositions ?? [:], state)
    }

    public static func hide(
        _ id: BundleID, _ s: HidingState, allow: AllowSnapshot, locations: [AllowLocation] = []
    ) -> (actions: [AllowAction], state: HidingState) {
        guard allow[id] == true, !s.hidden.contains(id) else { return ([], s) }
        var state = s
        state.hidden.append(id)
        state.journal.insert(id)
        return (listing(id, locations) + [.switchOff(id)], state)
    }

    public static func show(
        _ id: BundleID, _ s: HidingState, locations: [AllowLocation] = []
    ) -> (actions: [AllowAction], state: HidingState) {
        var state = s
        state.hidden.removeAll { $0 == id }
        guard state.journal.remove(id) != nil else { return ([], state) }
        return (listing(id, locations) + [.switchOn(id)], state)
    }

    /// An app opened while it's hidden may run from a copy its entry doesn't list, which would
    /// draw its icon: the copy is listed and the app switched off again. Only apps YeeHaw has
    /// switched off (journaled) count, so nothing is hidden again once quitting has switched
    /// everything back on. An app being revealed is left to the reveal, whose end switches it off
    /// with its copies listed.
    public static func launched(
        _ id: BundleID, _ s: HidingState, allow: AllowSnapshot, locations: [AllowLocation]
    ) -> [AllowAction] {
        guard s.hidden.contains(id), s.journal.contains(id), allow[id] != nil, !locations.isEmpty,
              s.pendingReveal?.bundleID != id else { return [] }
        return listing(id, locations) + [.switchOff(id)]
    }

    private static func listing(_ id: BundleID, _ locations: [AllowLocation]) -> [AllowAction] {
        locations.map { .addLocation(id, $0) }
    }

    public static func externalChange(
        _ s: HidingState, before: AllowSnapshot, after: AllowSnapshot
    ) -> HidingState {
        var state = s
        for id in s.journal where before[id] == false && after[id] == true {
            state.journal.remove(id)
            state.hidden.removeAll { $0 == id }
        }
        // A hidden app YeeHaw hasn't switched off (a launch that couldn't hide it yet) that the
        // user switches off is theirs from then on.
        for id in s.hidden where !s.journal.contains(id) && before[id] != false && after[id] == false {
            state.hidden.removeAll { $0 == id }
        }
        return state
    }

    public static func userOwnedOff(_ s: HidingState, allow: AllowSnapshot) -> Set<BundleID> {
        Set(allow.filter { !$0.value && !s.journal.contains($0.key) }.keys)
    }

    public static func adopt(_ ids: [BundleID], _ s: HidingState) -> HidingState {
        var state = s
        for id in ids {
            if !state.hidden.contains(id) { state.hidden.append(id) }
            state.journal.insert(id)
        }
        return state
    }
}
