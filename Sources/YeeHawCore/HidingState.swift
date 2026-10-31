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
}

public enum AllowAction: Equatable, Sendable { case switchOn(BundleID), switchOff(BundleID) }

/// Pure rules deciding which Allow switches to flip and how the persisted state changes.
/// Actions are ordered: every `.switchOff` (in `hidden` order), then every `.switchOn` (sorted).
public enum Reconciler {
    public static func onLaunch(
        _ s: HidingState, allow: AllowSnapshot
    ) -> (actions: [AllowAction], restorePositions: [String: Double?], state: HidingState) {
        var state = s
        state.hidden = s.hidden.filter { allow[$0] != nil }
        let hiddenSet = Set(state.hidden)
        let offs = state.hidden.filter { allow[$0] == true }
        let ons = s.journal.filter { allow[$0] != nil && !hiddenSet.contains($0) }.sorted()
        state.journal = s.journal.filter { hiddenSet.contains($0) }.union(offs)
        let restore = s.pendingReveal?.originalPositions ?? [:]
        state.pendingReveal = nil
        return (offs.map(AllowAction.switchOff) + ons.map(AllowAction.switchOn), restore, state)
    }

    public static func onQuit(_ s: HidingState) -> (actions: [AllowAction], state: HidingState) {
        var state = s
        state.journal = []
        return (s.journal.sorted().map(AllowAction.switchOn), state)
    }

    public static func hide(
        _ id: BundleID, _ s: HidingState, allow: AllowSnapshot
    ) -> (actions: [AllowAction], state: HidingState) {
        guard allow[id] == true, !s.hidden.contains(id) else { return ([], s) }
        var state = s
        state.hidden.append(id)
        state.journal.insert(id)
        return ([.switchOff(id)], state)
    }

    public static func show(
        _ id: BundleID, _ s: HidingState
    ) -> (actions: [AllowAction], state: HidingState) {
        var state = s
        state.hidden.removeAll { $0 == id }
        guard state.journal.remove(id) != nil else { return ([], state) }
        return ([.switchOn(id)], state)
    }

    public static func externalChange(
        _ s: HidingState, before: AllowSnapshot, after: AllowSnapshot
    ) -> HidingState {
        var state = s
        for id in s.journal where before[id] == false && after[id] == true {
            state.journal.remove(id)
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
