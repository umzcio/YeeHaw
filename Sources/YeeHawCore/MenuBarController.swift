import Foundation

public enum ControllerError: Error, Equatable {
    case notTracked(BundleID)
    case notHonored(BundleID)
    /// The app isn't running, so it has no icon to reveal.
    case notRunning(BundleID)
    case needsGrant(GrantedFile)
    /// A move neighbour (or YeeHaw's own item) whose position key isn't in the table.
    case unresolvedNeighbor
    /// A preference file holds a value of the wrong type; YeeHaw won't overwrite it.
    case malformed(GrantedFile)
}

/// Joins the pure rules (Allow list, position table, reconciler) to the system through ports.
///
/// Journal invariant: the journal is always a superset of the apps YeeHaw switched off that may
/// still be off. So a switch-off is journaled and saved *before* the write, and a switch-on is
/// removed from the journal only *after* the write succeeds.
///
/// Every switch YeeHaw writes for a running app lists the app's running copies in its entry first
/// (`AllowAction.addLocation`): MenuBarAgent ignores the switch for a copy that isn't listed.
///
/// Public async methods run one at a time, in call order, through an internal FIFO gate.
@MainActor public final class MenuBarController {
    public static let allowKey = "trackedApplications"
    public static let positionsKey = "TrailingItemPreferredPositions"
    public static let honorTimeout: Double = 5.0
    public static let pollInterval: Double = 0.05
    /// While a reveal's per-app read is in doubt, one poll in this many is a full read.
    public static let fullReadEvery = 10

    public private(set) var state: HidingState
    /// Receives a line at each step of a reveal (positions and Allow written, item drawn), for
    /// the debug log's timing.
    public var revealTrace: ((String) -> Void)?
    /// What the store last held, so an unchanged state is never written again.
    private var stored: HidingState
    /// Last read, drawn only.
    public private(set) var items: [MenuBarItem] = []
    /// How many times YeeHaw has written either file, so a caller can tell the bar may have
    /// changed under something it started earlier (a screenshot of the bar).
    public private(set) var writeCount = 0
    /// Apps with an Allow-list entry as of YeeHaw's last read or write. Only these can be hidden;
    /// macOS adds an entry some time after an app first draws an icon.
    public var trackedApps: Set<BundleID> { Set(lastSnapshot.keys) }
    /// Apps switched off as of YeeHaw's last read or write, less one being revealed: they aren't
    /// drawn, whatever an earlier frame of theirs says.
    public var switchedOff: Set<BundleID> {
        var off = Set(lastSnapshot.filter { !$0.value }.keys)
        if let revealed = state.pendingReveal?.bundleID { off.remove(revealed) }
        return off
    }

    private let allowFile: PreferencesFile
    private let positionFile: PreferencesFile
    private let reader: MenuBarReading
    private let store: StateStoring
    private let sleeper: Sleeper
    /// The Allow values YeeHaw last read at launch or wrote itself, per app, so its own writes
    /// never count as external changes and other apps' changes are never swallowed.
    private var lastSnapshot: AllowSnapshot = [:]
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    public init(allowFile: PreferencesFile, positionFile: PreferencesFile, reader: MenuBarReading,
                store: StateStoring, sleeper: Sleeper) {
        self.allowFile = allowFile
        self.positionFile = positionFile
        self.reader = reader
        self.store = store
        self.sleeper = sleeper
        state = store.load()
        stored = state
    }

    // MARK: Lifecycle

    /// Reconciles crash leftovers in one Allow write (no per-app wait), then restores any
    /// reveal positions, even when the Allow write failed. Switched-on apps and `pendingReveal`
    /// stay saved until their own writes land.
    public func launch() async throws {
        try await gated {
            var locations: [BundleID: [AllowLocation]] = [:]
            for id in state.hidden { locations[id] = await runningLocations(of: id) }
            let allow = try readAllow().snapshot
            lastSnapshot = allow
            let r = Reconciler.onLaunch(state, allow: allow, locations: locations)
            var interim = r.state
            interim.journal.formUnion(Self.switchedOn(r.actions))
            interim.pendingReveal = state.pendingReveal
            save(interim)
            try finish(allow: r.actions, journal: r.state.journal, restoring: r.restorePositions)
            await reload()
        }
    }

    /// Switches everything in the journal back on in one write, without waiting, then clears it,
    /// and puts back the positions of a reveal that's still open (or still ending), so the app
    /// isn't left at the slot next to YeeHaw's icon. Synchronous and outside the gate: it runs as
    /// YeeHaw quits, whatever else is in flight.
    public func quit() throws {
        try guarded {
            let r = Reconciler.onQuit(state)
            try finish(allow: r.actions, journal: r.state.journal, restoring: r.restorePositions)
        }
    }

    /// Writes `actions`, then `restoring` (each attempted even if the other fails), and saves:
    /// the journal becomes `journal` only once the Allow write landed, and `pendingReveal` clears
    /// only once the positions did. Rethrows the first failure.
    private func finish(allow actions: [AllowAction], journal: Set<BundleID>,
                        restoring positions: [String: Double?]) throws {
        var next = state
        var failure: Error?
        do {
            if !actions.isEmpty { try writeAllow(actions) }
            next.journal = journal
        } catch {
            failure = error
        }
        do {
            if !positions.isEmpty { try writePositions(positions) }
            next.pendingReveal = nil
        } catch {
            failure = failure ?? error
        }
        save(next)
        if let failure { throw failure }
    }

    /// Reads `file` once through its grant: true when that works, which clears a `needsGrant`
    /// left by an earlier failure; false records it. Writes nothing to the file.
    public func verifyAccess(_ file: GrantedFile) async -> Bool {
        do {
            try await gated {
                switch file {
                case .allowList: _ = try readAllow()
                case .positions: _ = try readPositions()
                }
            }
            return true
        } catch ControllerError.needsGrant {
            return false
        } catch {
            // Read but malformed: access works, and the controller refuses to write it anyway.
            return true
        }
    }

    public func refresh() async {
        await enterGate()
        defer { leaveGate() }
        await reload()
    }

    // MARK: Hiding

    /// A hide that fails (the write, or macOS not honouring it in time) is undone: the app is
    /// switched back on and the state is what it was before (`rollBack`). With `waits` false it
    /// returns once written, for a caller that waits for several edits at once (the Layout
    /// window's Apply) and undoes the ones macOS didn't honour itself.
    public func hide(_ id: BundleID, waits: Bool = true) async throws {
        try await gated {
            let locations = await runningLocations(of: id)
            let allow = try readAllow().snapshot
            guard allow[id] != nil else { throw ControllerError.notTracked(id) }
            let r = Reconciler.hide(id, state, allow: allow, locations: locations)
            guard !r.actions.isEmpty else { return }
            let before = state
            save(r.state)
            do {
                try writeAllow(r.actions)
                if waits { try await waitIfRunning(id, drawn: false) }
            } catch {
                rollBack(id, allowed: true, to: before)
                throw error
            }
        }
    }

    /// Switches the app back on for good. Showing the app that's being revealed also ends the
    /// reveal here and now (its positions go back), so a Layout placement made right after isn't
    /// undone when the reveal would have ended. A show that fails is undone like a hide: the
    /// switch goes back to what it was and the app back into Hidden. `waits` as for `hide`.
    public func show(_ id: BundleID, waits: Bool = true) async throws {
        try await gated {
            let locations = await runningLocations(of: id)
            let wasAllowed = try readAllow().snapshot[id]
            let before = state
            let r = Reconciler.show(id, state, locations: locations)
            var interim = r.state
            interim.journal = state.journal
            save(interim)
            do {
                if !r.actions.isEmpty {
                    try writeAllow(r.actions)
                    var next = state
                    next.journal = r.state.journal
                    save(next)
                }
                if let pending = state.pendingReveal, pending.bundleID == id {
                    try writePositions(pending.originalPositions)
                    var next = state
                    next.pendingReveal = nil
                    save(next)
                }
                if waits, !r.actions.isEmpty { try await waitIfRunning(id, drawn: true) }
            } catch {
                rollBack(id, allowed: wasAllowed, to: before)
                throw error
            }
        }
    }

    /// Call when an app has launched. A hidden app opened from a copy its entry doesn't list
    /// would draw its icon, so the copy is listed and the app switched off again, in one write
    /// with no wait (it may not have drawn anything yet). Nothing is written for other apps, or
    /// when every copy is listed already.
    public func appLaunched(_ id: BundleID) async throws {
        try await gated {
            guard state.hidden.contains(id) else { return }
            let locations = await runningLocations(of: id)
            let allow = try readAllow().snapshot
            let actions = Reconciler.launched(id, state, allow: allow, locations: locations)
            guard !actions.isEmpty else { return }
            try writeAllow(actions)
        }
    }

    /// Whether the app is running, and so has icons to draw once it's switched on.
    public func isRunning(_ id: BundleID) async -> Bool {
        await reader.runningBundleIDs().contains(id)
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
        try await gated {
            let allow = try readAllow().snapshot
            save(Reconciler.adopt(ids.filter { allow[$0] == false }, state))
            await reload()
        }
    }

    /// Call when the Allow file changed on disk. Only changes since YeeHaw's own last write count.
    /// Cheap when nothing changed (a poll): no bar read and no save.
    public func allowListChanged() async throws {
        try await gated {
            let current = try readAllow().snapshot
            guard current != lastSnapshot else { return }
            save(Reconciler.externalChange(state, before: lastSnapshot, after: current))
            lastSnapshot = current
            await reload()
        }
    }

    // MARK: Ordering

    /// Places every key of `item` between its new neighbours; an item's keys, and a neighbour's,
    /// are found with the last read's items beside it (`PositionKey.keys(for:among:table:)`), so a
    /// slot named after an autosave name resolves too. An Apple item moves by its `module:`
    /// key (verified to move Apple icons on macOS 27.2) and throws `.unresolvedNeighbor` when it has none. A no-op for pinned items
    /// (macOS ignores their moves) and items with no known owner.
    public func move(_ item: MenuBarItem, leftNeighbor: MenuBarItem?, rightNeighbor: MenuBarItem?) throws {
        guard !item.isPinned, item.bundleID != nil || item.appleIdentifier != nil else { return }
        try guarded {
            let table = PositionTable(try readPositions())
            let keys = item.bundleID != nil
                ? PositionKey.keys(for: item, among: items, table: table) : [try neighborKey(item, table)]
            let left = try leftNeighbor.map { try neighborKey($0, table) }
            let right = try rightNeighbor.map { try neighborKey($0, table) }
            try writePositions(try table.placement(of: keys, leftNeighbor: left, rightNeighbor: right))
        }
    }

    /// Places an app's icons between two items, whether or not it's drawn yet: the app's icons
    /// (every existing key under any of its prefixes) get distinct values in the slot, in their
    /// existing order, else `Item-0` under the first (as a
    /// reveal does), so it works for an app that's just been switched on. A neighbour that isn't
    /// drawn yet (an app shown just before, placed already) is found by its app's own keys.
    public func place(_ id: BundleID, leftNeighbor: MenuBarItem?, rightNeighbor: MenuBarItem?) async throws {
        try await gated {
            // Asked before the read, so nothing suspends between reading the table and writing it.
            let prefixes = await reader.keyPrefixes(of: id)
            var undrawn: [BundleID: [String]] = [:]
            for neighbor in [leftNeighbor, rightNeighbor].compactMap(\.self) where neighbor.keyPrefixes.isEmpty {
                if let app = neighbor.bundleID { undrawn[app] = await reader.keyPrefixes(of: app) }
            }
            let table = PositionTable(try readPositions())
            let key = { @MainActor (neighbor: MenuBarItem) throws -> String in
                guard let app = neighbor.bundleID, let prefixes = undrawn[app] else {
                    return try self.neighborKey(neighbor, table)
                }
                guard let key = PositionKey.existingKeys(prefixes: prefixes, table: table).first else {
                    throw ControllerError.unresolvedNeighbor
                }
                return key
            }
            let left = try leftNeighbor.map(key)
            let right = try rightNeighbor.map(key)
            // One value per icon, in the app's own order, so a multi-icon app comes back as it was.
            let groups = table.groupedByValue(Self.revealKeys(prefixes: prefixes, table))
            try writePositions(try table.placement(ofGroups: groups, leftNeighbor: left, rightNeighbor: right))
        }
    }

    /// The ids of drawn items with an owner whose position key isn't in the table (the clock
    /// always has one). They can't anchor a move, and an Apple one can't be moved. Empty when the
    /// table can't be read: the edit itself then reports why.
    public func itemsWithoutPositions() -> Set<String> {
        guard let values = try? readPositions() else { return [] }
        let table = PositionTable(values)
        return Set(items.filter { item in
            (item.bundleID != nil || item.appleIdentifier != nil) && (try? neighborKey(item, table)) == nil
        }.map(\.id))
    }

    /// Places YeeHaw's own icon immediately left of Control Center (first run): every
    /// existing key of `id` under any of its prefixes gets `slotValue(leftOf: controlCenter)`,
    /// measured without those keys; with none, `status:<prefix>::<name>` is created under every
    /// prefix, and macOS uses the one it files the icon under when it's first drawn. Throws `.unresolvedNeighbor` when the table has no
    /// Control Center key, rather than guessing a place.
    public func placeOwnIcon(_ id: BundleID, name: String) async throws {
        try await gated {
            let prefixes = await reader.keyPrefixes(of: id)
            let values = try readPositions()
            guard values[PositionKey.controlCenter] != nil else { throw ControllerError.unresolvedNeighbor }
            var keys = PositionKey.existingKeys(prefixes: prefixes, table: PositionTable(values))
            // No key yet: one under every prefix, since which one macOS files YeeHaw under
            // depends on how the build is signed (an unused key is inert, as in revealKeys).
            if keys.isEmpty { keys = prefixes.map { "status:\($0)::\(name)" } }
            let others = PositionTable(values.filter { !keys.contains($0.key) })
            let slot = others.slotValue(leftOf: PositionKey.controlCenter)
            try writePositions(Dictionary(uniqueKeysWithValues: keys.map { ($0, slot) }))
        }
    }

    // MARK: Reveal

    /// Briefly draws a hidden app immediately left of YeeHaw's icon and returns its item (index 0
    /// when drawn). Only apps YeeHaw hid can be revealed; they stay in `hidden` and the journal.
    /// `pendingReveal` is saved before anything is written, and the reveal is undone if not honored.
    public func beginReveal(_ id: BundleID, nextTo yeehaw: MenuBarItem) async throws -> MenuBarItem {
        try await gated {
            guard state.hidden.contains(id), state.journal.contains(id) else {
                throw ControllerError.notTracked(id)
            }
            // Switching on an app that isn't running would draw nothing; nothing is written.
            guard await reader.runningBundleIDs().contains(id) else { throw ControllerError.notRunning(id) }
            if state.pendingReveal != nil { try await finishReveal() }
            // Asked before the read, so nothing suspends between reading the table and writing it.
            let prefixes = await reader.keyPrefixes(of: id)
            let locations = await runningLocations(of: id)
            // Everything drawn now is someone else's (the app is off), so the bar must grow by
            // the app's own items before a per-app read's matches can be them.
            let othersDrawn = await reader.drawnBar(owning: id).count
            let values = try readPositions()
            let table = PositionTable(values)
            let yeehawKey = try neighborKey(yeehaw, table)
            let keys = Self.revealKeys(prefixes: prefixes, table)

            state.pendingReveal = PendingReveal(
                bundleID: id, originalPositions: Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0]) }))
            save(state)

            let slot = table.slotValue(leftOf: yeehawKey)
            try writePositions(Dictionary(uniqueKeysWithValues: keys.map { ($0, slot) }))
            try writeAllow(locations.map { .addLocation(id, $0) } + [.switchOn(id)])
            revealTrace?("positions and Allow written")
            do {
                let polls = try await waitForReveal(id, drawn: true, othersDrawn: othersDrawn)
                revealTrace?("drawn after \(polls) poll(s)")
            } catch ControllerError.notHonored(let failed) where failed == id {
                try await finishReveal()
                throw ControllerError.notHonored(id)
            }
            let drawn = items.filter { $0.bundleID == id }
            guard let item = drawn.first(where: { $0.indexInApp == 0 }) ?? drawn.first else {
                throw ControllerError.notHonored(id)
            }
            return item
        }
    }

    /// Switches the revealed app off (unless it was shown meanwhile), waits until it's gone, then
    /// restores its positions.
    public func endReveal() async throws {
        try await gated { try await finishReveal() }
    }

    // MARK: Private

    /// Ungated: callers already hold the gate. The positions go back even when switching the app
    /// off fails. If the switch-off write itself failed, `pendingReveal` stays so a retry (or the
    /// next launch) switches it off; if only the wait ran out, the write landed and it clears.
    private func finishReveal() async throws {
        guard let pending = state.pendingReveal else { return }
        var writeFailure: Error?
        var waitFailure: Error?
        if state.journal.contains(pending.bundleID) {
            let id = pending.bundleID
            do {
                // The app's own items are the ones the last reads vouched for; the rest of the
                // bar is everyone else's, and stays when the app goes.
                let running = await reader.runningBundleIDs().contains(id)
                let othersDrawn = running
                    ? await reader.drawnBar(owning: id).count - items.filter { $0.bundleID == id }.count : 0
                // A copy opened during the reveal is listed too (`Reconciler.launched` leaves it here).
                let locations = await runningLocations(of: id)
                try writeAllow(locations.map { .addLocation(id, $0) } + [.switchOff(id)])
                do {
                    if running {
                        try await waitForReveal(id, drawn: false, othersDrawn: othersDrawn)
                    } else {
                        await reload()
                    }
                } catch {
                    waitFailure = error
                }
            } catch {
                writeFailure = error
            }
        }
        try writePositions(pending.originalPositions)
        if let writeFailure { throw writeFailure }
        var next = state
        next.pendingReveal = nil
        save(next)
        if let waitFailure { throw waitFailure }
    }

    /// Every existing key of the app under any of its prefixes (hiding is per app, so the whole
    /// app appears), else `Item-0` under the first prefix. The prefixes come from the reader, so
    /// they're known even while the app is hidden and not drawn.
    private static func revealKeys(prefixes: [String], _ table: PositionTable) -> [String] {
        let existing = PositionKey.existingKeys(prefixes: prefixes, table: table)
        return existing.isEmpty ? prefixes.prefix(1).map { "status:\($0)::Item-0" } : existing
    }

    /// The Allow-list locations of the app's running copies; empty when it isn't running.
    private func runningLocations(of id: BundleID) async -> [AllowLocation] {
        await reader.runningCopies(of: id).map(\.location)
    }

    /// Undoes a hide or show that failed: the switch goes back to `allowed` (written only if it
    /// differs from what the file holds now), and the state to `before`. The journal invariant
    /// holds throughout: switching back on, the state goes back only once that's written;
    /// switching back off, the app is journaled first. If the switch can't be put back, the state
    /// stays as it is, which matches the switch. Nil `allowed` (untracked): nothing was written.
    private func rollBack(_ id: BundleID, allowed: Bool?, to before: HidingState) {
        switch allowed {
        case true?:
            guard (try? writeAllow([.switchOn(id)])) != nil else { return }
            save(before)
        case false?:
            let after = state
            save(before)
            if (try? writeAllow([.switchOff(id)])) == nil { save(after) }
        case nil:
            save(before)
        }
    }

    private static func switchedOn(_ actions: [AllowAction]) -> [BundleID] {
        actions.compactMap { if case .switchOn(let id) = $0 { id } else { nil } }
    }

    /// Makes `next` the state, writing the store only when it differs from what the store holds.
    /// `needsGrant` always stays the live one: it's changed only by reads and writes as they
    /// happen, never by a state worked out before them.
    private func save(_ next: HidingState) {
        let flags = state.needsGrant
        state = next
        state.needsGrant = flags
        guard state != stored else { return }
        store.save(state)
        stored = state
    }

    /// A full read of the bar. Apps known to be off are named, so a stale frame of theirs never
    /// claims another app's icon; an app being revealed (on or off) is tried after the apps that
    /// are on and before those that are off.
    private func reload() async {
        items = await reader.items(offApps: switchedOff, revealed: state.pendingReveal?.bundleID)
    }

    private func neighborKey(_ item: MenuBarItem, _ table: PositionTable) throws -> String {
        let key: String?
        if item.bundleID != nil {
            key = PositionKey.keys(for: item, among: items, table: table).first
        } else if let apple = item.appleIdentifier {
            key = PositionKey.appleKey(appleIdentifier: apple, table: table)
        } else {
            key = nil
        }
        // The clock is 0 by definition, key or not (PositionTable counts a missing one as 0); any other key must exist or the placement would be a guess.
        guard let key, key == PositionKey.clock || table.values[key] != nil else {
            throw ControllerError.unresolvedNeighbor
        }
        return key
    }

    private func waitIfRunning(_ id: BundleID, drawn: Bool) async throws {
        if await reader.runningBundleIDs().contains(id) {
            try await waitUntil(id, drawn: drawn)
        } else {
            await reload()
        }
    }

    /// Polls every `pollInterval` until the app's item appears (or disappears), for at most
    /// `honorTimeout`, counted in polls rather than wall time. No retry: throws `.notHonored`.
    /// Returns how many polls it took. Every poll is a full read.
    @discardableResult
    private func waitUntil(_ id: BundleID, drawn: Bool) async throws -> Int {
        try await poll(id) {
            await reload()
            return items.contains { $0.bundleID == id } == drawn
        }
    }

    /// A reveal's wait for the app to be drawn (or gone), which is on screen or holds up the next
    /// click, so it polls the per-app read and patches the app's items into `items`; other items
    /// keep their last read positions until the next full read. Matches the bar can't hold beside
    /// `othersDrawn` aren't the app's (`ItemMatcher.ownItems`): an app keeps reporting its last
    /// frame, so once it's off that frame can be the icon that slid into its place. While the
    /// read is in doubt, every `fullReadEvery`th poll is a full read instead, which settles it
    /// even when another icon came or went meanwhile.
    @discardableResult
    private func waitForReveal(_ id: BundleID, drawn: Bool, othersDrawn: Int) async throws -> Int {
        var inDoubt = false
        var count = 0
        return try await poll(id) {
            count += 1
            if inDoubt && count % Self.fullReadEvery == 0 {
                await reload()
            } else {
                let read = await reader.drawnBar(owning: id)
                let own = ItemMatcher.ownItems(in: read, of: id, othersDrawn: othersDrawn, lastRead: items)
                inDoubt = own.inDoubt
                items = (items.filter { $0.bundleID != id } + own.items).sorted { $0.x < $1.x }
            }
            return items.contains { $0.bundleID == id } == drawn
        }
    }

    /// Runs `done` every `pollInterval` until it's true, for at most `honorTimeout`.
    private func poll(_ id: BundleID, until done: () async -> Bool) async throws -> Int {
        let polls = Int((Self.honorTimeout / Self.pollInterval).rounded())
        var slept = 0
        while true {
            if await done() { return slept + 1 }
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

    /// Reads fresh, applies every action to entries that exist, and writes the list back once,
    /// only if something changed (so a missing `trackedApplications` key is never created). A
    /// location added to an entry is a change even when no switch flips, and the write carries
    /// the entry's switch as it is. `lastSnapshot` is updated only for the apps written.
    private func writeAllow(_ actions: [AllowAction]) throws {
        var list = try readAllow()
        let before = list.snapshot
        var written: AllowSnapshot = [:]
        var listed = false
        for action in actions {
            let (id, allowed): (BundleID, Bool)
            switch action {
            case .switchOn(let target): (id, allowed) = (target, true)
            case .switchOff(let target): (id, allowed) = (target, false)
            case .addLocation(let target, let location):
                if list.addLocation(location, for: target) { listed = true }
                continue
            }
            guard let current = before[id] else { continue }
            written[id] = allowed
            if current != allowed { list.setAllowed(allowed, for: id) }
        }
        if listed || written.contains(where: { before[$0.key] != $0.value }) {
            try allowFile.write(Self.allowKey, try list.encoded())
            writeCount += 1
        }
        lastSnapshot.merge(written) { _, new in new }
    }

    private func readPositions() throws -> [String: Double] {
        let value = try positionFile.read(Self.positionsKey)
        markGranted(.positions)
        guard let value else { return [:] }
        guard let dictionary = value as? [String: Double] else { throw ControllerError.malformed(.positions) }
        return dictionary
    }

    /// Reads fresh, applies the changes (nil removes a key), and writes the whole dictionary back
    /// only if something changed.
    private func writePositions(_ changes: [String: Double?]) throws {
        let before = try readPositions()
        var values = before
        for (key, value) in changes { values[key] = value }
        guard values != before else { return }
        try positionFile.write(Self.positionsKey, values)
        writeCount += 1
    }

    private func writePositions(_ changes: [String: Double]) throws {
        try writePositions(changes.mapValues { Optional($0) })
    }

    private func markGranted(_ file: GrantedFile) {
        if state.needsGrant.contains(file) {
            state.needsGrant.remove(file)
            save(state)
        }
    }

    // MARK: Gate and grant handling

    private func enterGate() async {
        guard gateBusy else {
            gateBusy = true
            return
        }
        await withCheckedContinuation { gateWaiters.append($0) }
    }

    /// Hands the gate straight to the next waiter (FIFO), so nobody can cut in.
    private func leaveGate() {
        if gateWaiters.isEmpty {
            gateBusy = false
        } else {
            gateWaiters.removeFirst().resume()
        }
    }

    private func gated<T>(_ body: () async throws -> T) async throws -> T {
        await enterGate()
        defer { leaveGate() }
        return try await guarded(body)
    }

    private func recordGrantFailure(_ error: Error) -> Error {
        guard case GrantError.needsGrant(let file) = error else { return error }
        state.needsGrant.insert(file)
        save(state)
        return ControllerError.needsGrant(file)
    }

    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch { throw recordGrantFailure(error) }
    }

    private func guarded<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw recordGrantFailure(error) }
    }
}
