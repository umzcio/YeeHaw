import Foundation

public enum ControllerError: Error, Equatable {
    case notTracked(BundleID)
    case notHonored(BundleID)
    case needsGrant(GrantedFile)
    /// A move neighbour whose position key isn't in the table.
    case unresolvedNeighbor
    /// A preference file holds a value of the wrong type; YeeHaw won't overwrite it.
    case malformed(GrantedFile)
}

/// Joins the pure rules (Allow list, position table, reconciler) to the system through ports.
/// State is saved before every flip, so a crash always leaves the journal correct.
@MainActor public final class MenuBarController {
    public static let allowKey = "trackedApplications"
    public static let positionsKey = "TrailingItemPreferredPositions"
    public static let honorTimeout: Double = 5.0
    public static let pollInterval: Double = 0.05

    public private(set) var state: HidingState
    /// Last read, drawn only.
    public private(set) var items: [MenuBarItem] = []

    private let allowFile: PreferencesFile
    private let positionFile: PreferencesFile
    private let reader: MenuBarReading
    private let store: StateStoring
    private let sleeper: Sleeper
    /// The Allow list as YeeHaw last wrote or reconciled it, so its own writes never count as
    /// external changes.
    private var lastSnapshot: AllowSnapshot = [:]
    /// The last drawn item seen per app (preferring index 0), for naming keys while it's hidden.
    private var knownItems: [BundleID: MenuBarItem] = [:]

    public init(allowFile: PreferencesFile, positionFile: PreferencesFile, reader: MenuBarReading,
                store: StateStoring, sleeper: Sleeper) {
        self.allowFile = allowFile
        self.positionFile = positionFile
        self.reader = reader
        self.store = store
        self.sleeper = sleeper
        state = store.load()
    }

    // MARK: Lifecycle

    /// Reconciles crash leftovers in one Allow write (no per-app wait), then restores any
    /// reveal positions. `pendingReveal` stays saved until its positions are back.
    public func launch() async throws {
        try await guarded {
            let allow = try readAllow().snapshot
            lastSnapshot = allow
            let r = Reconciler.onLaunch(state, allow: allow)
            var next = r.state
            next.pendingReveal = state.pendingReveal
            save(next)
            if !r.actions.isEmpty { try writeAllow(r.actions) }
            if !r.restorePositions.isEmpty { try writePositions(r.restorePositions) }
            if state.pendingReveal != nil {
                state.pendingReveal = nil
                save(state)
            }
            await refresh()
        }
    }

    /// Switches everything in the journal back on, in one write, without waiting.
    public func quit() throws {
        try guarded {
            let r = Reconciler.onQuit(state)
            save(r.state)
            if !r.actions.isEmpty { try writeAllow(r.actions) }
        }
    }

    public func refresh() async {
        items = await reader.items()
        for item in items {
            guard let id = item.bundleID else { continue }
            if item.indexInApp == 0 || knownItems[id] == nil { knownItems[id] = item }
        }
    }

    // MARK: Hiding

    public func hide(_ id: BundleID) async throws {
        try await guarded {
            let allow = try readAllow().snapshot
            guard allow[id] != nil else { throw ControllerError.notTracked(id) }
            let r = Reconciler.hide(id, state, allow: allow)
            guard !r.actions.isEmpty else { return }
            save(r.state)
            try writeAllow(r.actions)
            try await waitIfRunning(id, drawn: false)
        }
    }

    public func show(_ id: BundleID) async throws {
        try await guarded {
            let r = Reconciler.show(id, state)
            if r.state != state { save(r.state) }
            guard !r.actions.isEmpty else { return }
            try writeAllow(r.actions)
            try await waitIfRunning(id, drawn: true)
        }
    }

    /// Sets the strip order. Only reorders apps already hidden; any left out keep their place at the end.
    public func reorderHidden(_ ids: [BundleID]) {
        let current = state.hidden
        var order = ids.filter { current.contains($0) }.reduce(into: [BundleID]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        order += current.filter { !order.contains($0) }
        guard order != current else { return }
        state.hidden = order
        save(state)
    }

    /// Apps switched off by the user (off and not in the journal).
    public func userOwnedOff() throws -> Set<BundleID> {
        try guarded { Reconciler.userOwnedOff(state, allow: try readAllow().snapshot) }
    }

    /// Takes ownership of apps that are already off. Apps that are on or untracked are ignored.
    public func adopt(_ ids: [BundleID]) async throws {
        try await guarded {
            let allow = try readAllow().snapshot
            save(Reconciler.adopt(ids.filter { allow[$0] == false }, state))
            await refresh()
        }
    }

    /// Call when the Allow file changed on disk. Only changes since YeeHaw's own last write count.
    public func allowListChanged() async throws {
        try await guarded {
            let current = try readAllow().snapshot
            save(Reconciler.externalChange(state, before: lastSnapshot, after: current))
            lastSnapshot = current
            await refresh()
        }
    }

    // MARK: Ordering

    /// Places every key of `item` between its new neighbours. A no-op for items with no owning app.
    public func move(_ item: MenuBarItem, leftNeighbor: MenuBarItem?, rightNeighbor: MenuBarItem?) throws {
        guard let id = item.bundleID else { return }
        try guarded {
            let table = PositionTable(try readPositions())
            let keys = PositionKey.keys(bundleID: id, names: item.keyNames, indexInApp: item.indexInApp, table: table)
            let left = try leftNeighbor.map { try neighborKey($0, table) }
            let right = try rightNeighbor.map { try neighborKey($0, table) }
            try writePositions(table.placement(of: keys, leftNeighbor: left, rightNeighbor: right))
        }
    }

    // MARK: Reveal

    /// Briefly draws a hidden app's item immediately left of YeeHaw's icon. The app stays in
    /// `hidden` and the journal; `pendingReveal` is saved before anything is written.
    public func beginReveal(_ id: BundleID, nextTo yeehaw: MenuBarItem) async throws -> MenuBarItem {
        try await guarded {
            if state.pendingReveal != nil { try await finishReveal() }
            let values = try readPositions()
            let table = PositionTable(values)
            guard let yeehawID = yeehaw.bundleID,
                  let yeehawKey = PositionKey.keys(bundleID: yeehawID, names: yeehaw.keyNames,
                                                   indexInApp: yeehaw.indexInApp, table: table).first
            else { throw ControllerError.unresolvedNeighbor }
            let keys = PositionKey.keys(bundleID: id, names: knownItems[id]?.keyNames ?? [], indexInApp: 0, table: table)

            state.pendingReveal = PendingReveal(
                bundleID: id, originalPositions: Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0]) }))
            save(state)

            let slot = table.slotValue(leftOf: yeehawKey)
            try writePositions(Dictionary(uniqueKeysWithValues: keys.map { ($0, slot) }))
            try writeAllow([.switchOn(id)])
            guard let drawn = try await waitUntil(id, drawn: true) else { throw ControllerError.notHonored(id) }
            return drawn
        }
    }

    /// Switches the revealed app off, waits until it's gone, then restores its positions.
    public func endReveal() async throws {
        try await guarded { try await finishReveal() }
    }

    // MARK: Private

    private func finishReveal() async throws {
        guard let pending = state.pendingReveal else { return }
        try writeAllow([.switchOff(pending.bundleID)])
        try await waitIfRunning(pending.bundleID, drawn: false)
        try writePositions(pending.originalPositions)
        state.pendingReveal = nil
        save(state)
    }

    private func save(_ next: HidingState) {
        state = next
        store.save(state)
    }

    private func neighborKey(_ item: MenuBarItem, _ table: PositionTable) throws -> String {
        let key: String?
        if let id = item.bundleID {
            key = PositionKey.keys(bundleID: id, names: item.keyNames, indexInApp: item.indexInApp, table: table).first
        } else if let apple = item.appleIdentifier {
            key = PositionKey.appleKey(appleIdentifier: apple, table: table)
        } else {
            key = nil
        }
        // The clock is 0 by definition; any other key must exist or the placement would be a guess.
        guard let key, key == PositionKey.clock || table.values[key] != nil else {
            throw ControllerError.unresolvedNeighbor
        }
        return key
    }

    private func waitIfRunning(_ id: BundleID, drawn: Bool) async throws {
        if await reader.runningBundleIDs().contains(id) {
            _ = try await waitUntil(id, drawn: drawn)
        } else {
            await refresh()
        }
    }

    /// Polls every `pollInterval` until the app's item appears (or disappears), for at most
    /// `honorTimeout`, counted in polls rather than wall time. No retry: throws `.notHonored`.
    @discardableResult
    private func waitUntil(_ id: BundleID, drawn: Bool) async throws -> MenuBarItem? {
        let polls = Int((Self.honorTimeout / Self.pollInterval).rounded())
        var slept = 0
        while true {
            await refresh()
            let match = items.first { $0.bundleID == id }
            if (match != nil) == drawn { return match }
            guard slept < polls else { throw ControllerError.notHonored(id) }
            slept += 1
            await sleeper.sleep(seconds: Self.pollInterval)
        }
    }

    // MARK: Files

    private func readAllow() throws -> AllowList {
        let value = try allowFile.read(Self.allowKey)
        markGranted(.allowList)
        do {
            guard let value else {
                return try AllowList(data: PropertyListSerialization.data(fromPropertyList: [Any](), format: .binary, options: 0))
            }
            guard let data = value as? Data else { throw AllowListError.malformed }
            return try AllowList(data: data)
        } catch {
            throw ControllerError.malformed(.allowList)
        }
    }

    /// Reads fresh, applies every action, and writes the list back once.
    private func writeAllow(_ actions: [AllowAction]) throws {
        var list = try readAllow()
        for action in actions {
            switch action {
            case .switchOn(let id): list.setAllowed(true, for: id)
            case .switchOff(let id): list.setAllowed(false, for: id)
            }
        }
        try allowFile.write(Self.allowKey, try list.encoded())
        lastSnapshot = list.snapshot
    }

    private func readPositions() throws -> [String: Double] {
        let value = try positionFile.read(Self.positionsKey)
        markGranted(.positions)
        guard let value else { return [:] }
        guard let dictionary = value as? [String: Double] else { throw ControllerError.malformed(.positions) }
        return dictionary
    }

    /// Reads fresh, applies the changes (nil removes a key), and writes the whole dictionary back.
    private func writePositions(_ changes: [String: Double?]) throws {
        var values = try readPositions()
        for (key, value) in changes { values[key] = value }
        try positionFile.write(Self.positionsKey, values)
    }

    private func writePositions(_ changes: [String: Double]) throws {
        try writePositions(changes.mapValues { Optional($0) })
    }

    private func markGranted(_ file: GrantedFile) {
        if state.needsGrant.contains(file) {
            state.needsGrant.remove(file)
            store.save(state)
        }
    }

    private func recordGrantFailure(_ error: Error) -> Error {
        guard case GrantError.needsGrant(let file) = error else { return error }
        state.needsGrant.insert(file)
        store.save(state)
        return ControllerError.needsGrant(file)
    }

    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw recordGrantFailure(error) }
    }

    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw recordGrantFailure(error) }
    }
}
