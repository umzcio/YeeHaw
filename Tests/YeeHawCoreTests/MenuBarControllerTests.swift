import Foundation
import Testing
@testable import YeeHawCore

// MARK: - Fakes

/// The whole system YeeHaw talks to: both preference files, the drawn bar and the running apps.
/// `items()` derives what's drawn from the Allow list, so a flip shows up on the next poll.
final class FakeSystem: MenuBarReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _allowBlob: Data
    private var _positions: [String: Double]
    private var _running: Set<BundleID>
    private var _drawn: [BundleID: [MenuBarItem]]
    private let prefixes: [BundleID: [String]]
    private var _appleItems: [MenuBarItem]
    private var _frozenAllow: AllowSnapshot?
    private var _failing: Set<GrantedFile> = []
    private var _failingWrites: Set<GrantedFile> = []
    private var _log: [String] = []
    private var _allowWrites = 0
    private var _positionWrites = 0
    private var _itemReads = 0

    init(allow: [(BundleID, Bool)], positions: [String: Double] = [:], running: Set<BundleID>? = nil,
         drawn: [BundleID: [MenuBarItem]] = [:], appleItems: [MenuBarItem] = [],
         prefixes: [BundleID: [String]] = [:]) throws {
        _allowBlob = try Self.blob(allow)
        self.prefixes = prefixes
        _positions = positions
        _running = running ?? Set(allow.map(\.0))
        var defaults = Dictionary(uniqueKeysWithValues: allow.map { ($0.0, [Self.item($0.0, prefixes: prefixes[$0.0])]) })
        defaults.merge(drawn) { _, new in new }
        _drawn = defaults
        _appleItems = appleItems
    }

    private func locked<R>(_ body: (FakeSystem) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    static func item(_ id: BundleID, index: Int = 0, names: [String] = [], x: Double = 100,
                     prefixes: [String]? = nil) -> MenuBarItem {
        MenuBarItem(id: "\(id)#\(index)", bundleID: id, appleIdentifier: nil, indexInApp: index,
                    axIdentifier: names.first ?? "", label: id, keyNames: names, keyPrefixes: prefixes ?? [id],
                    x: x, width: 20, isPinned: false)
    }

    static func appleItem(_ identifier: String, x: Double = 900) -> MenuBarItem {
        MenuBarItem(id: identifier, bundleID: nil, appleIdentifier: identifier, indexInApp: 0,
                    axIdentifier: "", label: identifier, keyNames: [], keyPrefixes: [], x: x, width: 20, isPinned: false)
    }

    static func blob(_ entries: [(BundleID, Bool)]) throws -> Data {
        var items: [Any] = []
        for (id, allowed) in entries {
            items.append(["bundle": ["_0": id]])
            items.append(["location": ["bundle": ["_0": id]], "isAllowed": allowed] as [String: Any])
        }
        return try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    }

    // Observations and knobs for tests.
    var allowSnapshot: AllowSnapshot { locked { (try? AllowList(data: $0._allowBlob))?.snapshot ?? [:] } }
    var positions: [String: Double] { locked { $0._positions } }
    var allowWrites: Int { locked { $0._allowWrites } }
    var positionWrites: Int { locked { $0._positionWrites } }
    /// How many times the bar was read (`items()`).
    var itemReads: Int { locked { $0._itemReads } }
    var log: [String] { locked { $0._log } }

    /// `honorsWrites = false`: the bar keeps drawing what it drew before.
    var honorsWrites: Bool {
        get { locked { $0._frozenAllow == nil } }
        set {
            let snapshot = allowSnapshot
            locked { $0._frozenAllow = newValue ? nil : snapshot }
        }
    }

    func fail(_ file: GrantedFile) { locked { _ = $0._failing.insert(file) } }
    /// Reads still work; writes to `file` throw `WriteFailed`.
    func failWrites(_ file: GrantedFile) { locked { _ = $0._failingWrites.insert(file) } }
    func append(_ event: String) { locked { $0._log.append(event) } }

    /// A change made outside YeeHaw, e.g. in System Settings.
    func setExternally(_ id: BundleID, allowed: Bool) throws {
        try locked {
            var list = try AllowList(data: $0._allowBlob)
            list.setAllowed(allowed, for: id)
            $0._allowBlob = try list.encoded()
        }
    }

    // PreferencesFile backing.
    func read(_ file: GrantedFile, _ key: String) throws -> Any? {
        try locked {
            if $0._failing.contains(file) { throw GrantError.needsGrant(file) }
            switch (file, key) {
            case (.allowList, "trackedApplications"): return $0._allowBlob
            case (.positions, "TrailingItemPreferredPositions"): return $0._positions
            default: return nil
            }
        }
    }

    func write(_ file: GrantedFile, _ key: String, _ value: Any) throws {
        try locked {
            if $0._failing.contains(file) { throw GrantError.needsGrant(file) }
            if $0._failingWrites.contains(file) { throw WriteFailed() }
            switch (file, key) {
            case (.allowList, "trackedApplications"):
                $0._allowBlob = try #require(value as? Data)
                $0._allowWrites += 1
                $0._log.append("write:allow")
            case (.positions, "TrailingItemPreferredPositions"):
                $0._positions = try #require(value as? [String: Double])
                $0._positionWrites += 1
                $0._log.append("write:positions")
            default:
                Issue.record("unexpected write to \(file) key \(key)")
            }
        }
    }

    // MenuBarReading.
    func items() async -> [MenuBarItem] {
        let live = allowSnapshot
        return locked { s in
            s._itemReads += 1
            let allow = s._frozenAllow ?? live
            let thirdParty = s._drawn
                .filter { s._running.contains($0.key) && allow[$0.key] == true }
                .flatMap(\.value)
            return (thirdParty + s._appleItems).sorted { $0.x < $1.x }
        }
    }

    func runningBundleIDs() async -> Set<BundleID> { locked { $0._running } }

    func keyPrefixes(of id: BundleID) async -> [String] { prefixes[id] ?? [id] }
}

struct WriteFailed: Error {}

struct FakeFile: PreferencesFile {
    let system: FakeSystem
    let file: GrantedFile
    func read(_ key: String) throws -> Any? { try system.read(file, key) }
    func write(_ key: String, _ value: Any) throws { try system.write(file, key, value) }
}

final class FakeStore: StateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let system: FakeSystem
    private var _saved: [HidingState]

    init(_ initial: HidingState = .empty, system: FakeSystem) {
        self.system = system
        _saved = [initial]
    }

    var saved: [HidingState] { lock.withLock { _saved } }
    var saveCount: Int { lock.withLock { _saved.count - 1 } }

    func load() -> HidingState { lock.withLock { _saved.last! } }
    func save(_ s: HidingState) {
        lock.withLock { _saved.append(s) }
        system.append("save")
    }
}

final class FakeSleeper: Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var _total: Double = 0
    private var _count = 0
    var total: Double { lock.withLock { _total } }
    var count: Int { lock.withLock { _count } }
    func sleep(seconds: Double) async { lock.withLock { _total += seconds; _count += 1 } }
}

// MARK: - Tests

@MainActor @Suite struct MenuBarControllerTests {
    static let a = "com.example.A"
    static let b = "com.example.B"
    static let yeehaw = "com.zapps.yeehaw"

    struct Rig {
        let system: FakeSystem
        let store: FakeStore
        let sleeper = FakeSleeper()

        @MainActor func controller() -> MenuBarController {
            MenuBarController(
                allowFile: FakeFile(system: system, file: .allowList),
                positionFile: FakeFile(system: system, file: .positions),
                reader: system, store: store, sleeper: sleeper)
        }
    }

    static func rig(_ system: FakeSystem, state: HidingState = .empty) -> Rig {
        Rig(system: system, store: FakeStore(state, system: system))
    }

    static func revealSystem() throws -> FakeSystem {
        try FakeSystem(
            allow: [(a, false), (b, true), (yeehaw, true)],
            positions: [
                "status:\(a)::Item-0": 300,
                "status:\(b)::Item-0": 100,
                "status:\(yeehaw)::Item-0": 10,
                PositionKey.controlCenter: 5,
                PositionKey.clock: 0,
            ])
    }

    // MARK: hide / show

    @Test func hideFlipsAndWaits() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        #expect(!c.items.contains { $0.bundleID == Self.a })
        #expect(c.items.contains { $0.bundleID == Self.b })
        #expect(c.state.hidden == [Self.a])
        #expect(c.state.journal == [Self.a])
        #expect(rig.system.allowSnapshot[Self.a] == false)
        #expect(rig.store.load() == c.state)
    }

    @Test func hideNotHonoredThrowsWithoutRetry() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        rig.system.honorsWrites = false
        let c = rig.controller()
        await #expect(throws: ControllerError.notHonored(Self.a)) { try await c.hide(Self.a) }
        #expect(rig.system.allowWrites == 1)
        #expect(rig.sleeper.count == 100)
        #expect(abs(rig.sleeper.total - MenuBarController.honorTimeout) < 1e-9)
    }

    @Test func hideSkipsWaitWhenAppNotRunning() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)], running: []))
        rig.system.honorsWrites = false
        let c = rig.controller()
        try await c.hide(Self.a)
        #expect(rig.system.allowWrites == 1)
        #expect(rig.system.allowSnapshot[Self.a] == false)
        #expect(rig.sleeper.count == 0)
    }

    @Test func stateSavedBeforeFlip() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        let log = rig.system.log
        let firstWrite = try #require(log.firstIndex(of: "write:allow"))
        let savesBefore = log[..<firstWrite].filter { $0 == "save" }.count
        #expect(savesBefore >= 1)
        // The state on disk at the moment of the flip already journals A.
        #expect(rig.store.saved[savesBefore].journal == [Self.a])
    }

    @Test func hideUntrackedAppThrows() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.b, true)]))
        let c = rig.controller()
        await #expect(throws: ControllerError.notTracked(Self.a)) { try await c.hide(Self.a) }
        #expect(rig.system.allowWrites == 0)
    }

    @Test func hideAlreadyOffIsNoOp() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, false)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        #expect(rig.system.allowWrites == 0)
        #expect(rig.store.saveCount == 0)
        #expect(c.state.hidden.isEmpty)
    }

    @Test func showFlipsOnAndWaits() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        try await c.show(Self.a)
        #expect(c.items.contains { $0.bundleID == Self.a })
        #expect(c.state.hidden.isEmpty)
        #expect(c.state.journal.isEmpty)
        #expect(rig.system.allowSnapshot[Self.a] == true)
        #expect(rig.system.allowWrites == 2)
    }

    // MARK: journal invariant (switch-on writes land before the journal forgets)

    @Test func failedShowWriteKeepsAppJournaled() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        rig.system.failWrites(.allowList)
        await #expect(throws: WriteFailed.self) { try await c.show(Self.a) }
        #expect(rig.store.load().journal == [Self.a])
        #expect(c.state.journal == [Self.a])
        #expect(rig.system.allowSnapshot[Self.a] == false)
    }

    @Test func failedQuitWriteKeepsJournal() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        rig.system.failWrites(.allowList)
        #expect(throws: WriteFailed.self) { try c.quit() }
        #expect(rig.store.load().journal == [Self.a])
        #expect(c.state.journal == [Self.a])
    }

    @Test func failedLaunchWriteKeepsSwitchOnsJournaled() async throws {
        let rig = Self.rig(
            try FakeSystem(allow: [(Self.a, true), (Self.b, false)]),
            state: HidingState(hidden: [Self.a], journal: [Self.b]))
        rig.system.failWrites(.allowList)
        let c = rig.controller()
        await #expect(throws: WriteFailed.self) { try await c.launch() }
        // The switch-off of A was journaled before the write; B stays journaled until its write lands.
        #expect(rig.store.load().journal == [Self.a, Self.b])
        #expect(rig.store.load().hidden == [Self.a])
    }

    // MARK: grants

    @Test func grantFailureMarksNeedsGrant() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        rig.system.fail(.allowList)
        let c = rig.controller()
        await #expect(throws: ControllerError.needsGrant(.allowList)) { try await c.hide(Self.a) }
        #expect(c.state.needsGrant == [.allowList])
        #expect(rig.store.load().needsGrant == [.allowList])
        #expect(rig.system.allowWrites == 0)
        #expect(rig.system.positionWrites == 0)
    }

    @Test func successfulReadClearsNeedsGrant() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, false)]), state: HidingState(needsGrant: [.allowList]))
        let c = rig.controller()
        _ = try c.userOwnedOff()
        #expect(c.state.needsGrant.isEmpty)
        #expect(rig.store.load().needsGrant.isEmpty)
    }

    // MARK: move

    @Test func moveWritesAllKeysOfItem() throws {
        let rig = Self.rig(try FakeSystem(
            allow: [(Self.a, true), (Self.b, true)],
            positions: [
                "status:\(Self.a)::Google Drive": 300,
                "status:\(Self.a)::Item-0": 290,
                "status:\(Self.b)::Item-0": 200,
                "module:WiFi": 100,
                PositionKey.clock: 0,
            ]))
        let c = rig.controller()
        let item = FakeSystem.item(Self.a, names: ["Google Drive"])
        try c.move(item, leftNeighbor: FakeSystem.item(Self.b),
                   rightNeighbor: FakeSystem.appleItem("com.apple.menuextra.wifi"))
        let p = rig.system.positions
        #expect(p["status:\(Self.a)::Google Drive"] == 150)
        #expect(p["status:\(Self.a)::Item-0"] == 150)
        #expect(p["status:\(Self.b)::Item-0"] == 200)
        #expect(p["module:WiFi"] == 100)
        #expect(rig.system.positionWrites == 1)
    }

    @Test func appleNeighborResolvesModuleKey() throws {
        let rig = Self.rig(try FakeSystem(
            allow: [(Self.a, true), (Self.b, true)],
            positions: [
                "status:\(Self.a)::Item-0": 20,
                "status:\(Self.b)::Item-0": 200,
                "module:WiFi": 50,
                "module:Battery": 30,
                PositionKey.clock: 0,
            ]))
        let c = rig.controller()
        try c.move(FakeSystem.item(Self.a), leftNeighbor: FakeSystem.item(Self.b),
                   rightNeighbor: FakeSystem.appleItem("com.apple.menuextra.wifi"))
        #expect(rig.system.positions["status:\(Self.a)::Item-0"] == 125)
    }

    @Test func unresolvableNeighborThrows() throws {
        let rig = Self.rig(try FakeSystem(
            allow: [(Self.a, true)],
            positions: ["status:\(Self.a)::Item-0": 20, PositionKey.clock: 0]))
        let c = rig.controller()
        #expect(throws: ControllerError.unresolvedNeighbor) {
            try c.move(FakeSystem.item(Self.a), leftNeighbor: FakeSystem.appleItem("com.apple.menuextra.mystery"),
                       rightNeighbor: nil)
        }
        #expect(throws: ControllerError.unresolvedNeighbor) {
            try c.move(FakeSystem.item(Self.a), leftNeighbor: FakeSystem.item(Self.b), rightNeighbor: nil)
        }
        #expect(rig.system.positionWrites == 0)
    }

    @Test func moveOfAppleItemIsNoOp() throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)], positions: ["module:WiFi": 50]))
        let c = rig.controller()
        try c.move(FakeSystem.appleItem("com.apple.menuextra.wifi"), leftNeighbor: FakeSystem.item(Self.a),
                   rightNeighbor: nil)
        #expect(rig.system.positionWrites == 0)
    }

    // MARK: reveal

    @Test func revealUsesSlotLeftOfYeeHawAndRestores() async throws {
        let system = try Self.revealSystem()
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        let yeehawItem = FakeSystem.item(Self.yeehaw)

        let drawn = try await c.beginReveal(Self.a, nextTo: yeehawItem)
        #expect(drawn.bundleID == Self.a)
        // Immediately left of YeeHaw (10): midpoint to the next larger value, B at 100.
        #expect(system.positions["status:\(Self.a)::Item-0"] == 55)
        #expect(c.state.pendingReveal == PendingReveal(
            bundleID: Self.a, originalPositions: ["status:\(Self.a)::Item-0": 300]))
        #expect(c.state.hidden == [Self.a])
        #expect(c.state.journal == [Self.a])

        try await c.endReveal()
        #expect(system.positions == original)
        #expect(system.allowSnapshot[Self.a] == false)
        #expect(!c.items.contains { $0.bundleID == Self.a })
        #expect(c.state.pendingReveal == nil)
        #expect(rig.store.load().pendingReveal == nil)
    }

    @Test func revealSavesPendingBeforeWriting() async throws {
        let system = try Self.revealSystem()
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        let log = system.log
        let firstWrite = try #require(log.firstIndex { $0.hasPrefix("write:") })
        let savesBefore = log[..<firstWrite].filter { $0 == "save" }.count
        #expect(savesBefore >= 1)
        #expect(rig.store.saved[savesBefore].pendingReveal?.bundleID == Self.a)
    }

    @Test func revealOfNewKeyRestoresByRemoving() async throws {
        let system = try FakeSystem(
            allow: [(Self.a, false), (Self.yeehaw, true)],
            positions: ["status:\(Self.yeehaw)::Item-0": 10, PositionKey.clock: 0])
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        #expect(c.state.pendingReveal?.originalPositions == ["status:\(Self.a)::Item-0": Double?.none])
        #expect(system.positions["status:\(Self.a)::Item-0"] == 30)
        try await c.endReveal()
        #expect(system.positions == original)
        #expect(system.allowSnapshot[Self.a] == false)
    }

    @Test func secondRevealFinishesTheFirst() async throws {
        let system = try Self.revealSystem()
        try system.setExternally(Self.b, allowed: false)
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a, Self.b], journal: [Self.a, Self.b]))
        let c = rig.controller()
        let yeehawItem = FakeSystem.item(Self.yeehaw)
        _ = try await c.beginReveal(Self.a, nextTo: yeehawItem)
        _ = try await c.beginReveal(Self.b, nextTo: yeehawItem)
        #expect(system.allowSnapshot[Self.a] == false)
        #expect(system.positions["status:\(Self.a)::Item-0"] == original["status:\(Self.a)::Item-0"])
        #expect(c.state.pendingReveal?.bundleID == Self.b)
        try await c.endReveal()
        #expect(system.positions == original)
    }

    @Test func endRevealWithoutPendingDoesNothing() async throws {
        let rig = Self.rig(try Self.revealSystem())
        let c = rig.controller()
        try await c.endReveal()
        #expect(rig.system.allowWrites == 0)
        #expect(rig.system.positionWrites == 0)
        #expect(rig.store.saveCount == 0)
    }

    @Test func revealRefusesUserOwnedOffApp() async throws {
        let system = try Self.revealSystem()
        let rig = Self.rig(system)
        let c = rig.controller()
        await #expect(throws: ControllerError.notTracked(Self.a)) {
            _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        }
        #expect(system.allowWrites == 0)
        #expect(system.positionWrites == 0)
        #expect(rig.store.saveCount == 0)
    }

    @Test func showDuringRevealLeavesAppOn() async throws {
        let system = try Self.revealSystem()
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        try await c.show(Self.a)
        try await c.endReveal()
        #expect(system.allowSnapshot[Self.a] == true)
        #expect(system.positions == original)
        #expect(c.state.hidden.isEmpty)
        #expect(c.state.journal.isEmpty)
        #expect(c.state.pendingReveal == nil)
    }

    @Test func revealAfterRelaunchUsesExistingNamedKeys() async throws {
        let nord = "com.nordvpn.macos"
        let nordKey = "status:\(nord)::nordMenuBarItem"
        let system = try FakeSystem(
            allow: [(nord, false), (Self.yeehaw, true)],
            positions: [nordKey: 400, "status:\(Self.yeehaw)::Item-0": 10, PositionKey.clock: 0])
        let original = system.positions
        let store = FakeStore(HidingState(hidden: [nord], journal: [nord]), system: system)
        let fresh = Rig(system: system, store: store).controller()
        _ = try await fresh.beginReveal(nord, nextTo: FakeSystem.item(Self.yeehaw))
        #expect(system.positions[nordKey] == 205)
        #expect(system.positions["status:\(nord)::Item-0"] == nil)
        try await fresh.endReveal()
        #expect(system.positions == original)
    }

    @Test func revealMovesEveryKeyOfTheApp() async throws {
        let system = try FakeSystem(
            allow: [(Self.a, false), (Self.yeehaw, true)],
            positions: ["status:\(Self.a)::Google Drive": 300, "status:\(Self.a)::Item-0": 290,
                        "status:\(Self.yeehaw)::Item-0": 10, PositionKey.clock: 0])
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        // Midpoint between YeeHaw (10) and the next larger value (290).
        #expect(system.positions["status:\(Self.a)::Google Drive"] == 150)
        #expect(system.positions["status:\(Self.a)::Item-0"] == 150)
        try await c.endReveal()
        #expect(system.positions == original)
    }

    // The owner's bug: YeeHaw isn't notarized, so its only key is under its executable name.
    @Test func revealResolvesYeeHawByExecutableName() async throws {
        let system = try FakeSystem(
            allow: [(Self.a, false), (Self.yeehaw, true)],
            positions: ["status:\(Self.a)::Item-0": 300, "status:YeeHaw::YeeHaw": 10, PositionKey.clock: 0],
            prefixes: [Self.yeehaw: [Self.yeehaw, "YeeHaw"]])
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        let yeehawItem = FakeSystem.item(Self.yeehaw, names: ["YeeHaw"], prefixes: [Self.yeehaw, "YeeHaw"])
        _ = try await c.beginReveal(Self.a, nextTo: yeehawItem)
        #expect(system.positions["status:\(Self.a)::Item-0"] == 155)
        try await c.endReveal()
        #expect(system.positions == original)
    }

    @Test func revealMovesAndRestoresKeysUnderBothPrefixes() async throws {
        let zmeet = "edu.umontana.zmeet"
        let system = try FakeSystem(
            allow: [(zmeet, false), (Self.yeehaw, true)],
            positions: ["status:\(zmeet)::zMeetStatusItem": 300, "status:zMeet::zMeetStatusItem": 280,
                        "status:\(Self.yeehaw)::Item-0": 10, PositionKey.clock: 0],
            prefixes: [zmeet: [zmeet, "zMeet"]])
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [zmeet], journal: [zmeet]))
        let c = rig.controller()
        _ = try await c.beginReveal(zmeet, nextTo: FakeSystem.item(Self.yeehaw))
        #expect(system.positions["status:\(zmeet)::zMeetStatusItem"] == 145)
        #expect(system.positions["status:zMeet::zMeetStatusItem"] == 145)
        #expect(c.state.pendingReveal?.originalPositions ==
                ["status:\(zmeet)::zMeetStatusItem": 300, "status:zMeet::zMeetStatusItem": 280])
        try await c.endReveal()
        #expect(system.positions == original)
    }

    @Test func revealAfterRelaunchUsesExecutablePrefixWhileHidden() async throws {
        let nora = "com.example.nora"
        let system = try FakeSystem(
            allow: [(nora, false), (Self.yeehaw, true)],
            positions: ["status:Nora::Item-0": 400, "status:\(Self.yeehaw)::Item-0": 10, PositionKey.clock: 0],
            prefixes: [nora: [nora, "Nora"]])
        let original = system.positions
        let store = FakeStore(HidingState(hidden: [nora], journal: [nora]), system: system)
        let fresh = Rig(system: system, store: store).controller()
        _ = try await fresh.beginReveal(nora, nextTo: FakeSystem.item(Self.yeehaw))
        #expect(system.positions["status:Nora::Item-0"] == 205)
        #expect(system.positions["status:\(nora)::Item-0"] == nil)
        try await fresh.endReveal()
        #expect(system.positions == original)
    }

    @Test func moveWritesKeysUnderEveryPrefix() throws {
        let zmeet = "edu.umontana.zmeet"
        let rig = Self.rig(try FakeSystem(
            allow: [(zmeet, true), (Self.b, true)],
            positions: ["status:\(zmeet)::zMeetStatusItem": 300, "status:zMeet::zMeetStatusItem": 300,
                        "status:\(Self.b)::Item-0": 200, PositionKey.clock: 0]))
        let item = FakeSystem.item(zmeet, names: ["zMeetStatusItem"], prefixes: [zmeet, "zMeet"])
        try rig.controller().move(item, leftNeighbor: FakeSystem.item(Self.b), rightNeighbor: nil)
        #expect(rig.system.positions["status:\(zmeet)::zMeetStatusItem"] == 100)
        #expect(rig.system.positions["status:zMeet::zMeetStatusItem"] == 100)
    }

    @Test func revealReturnsIndexZeroItem() async throws {
        let system = try FakeSystem(
            allow: [(Self.a, false), (Self.yeehaw, true)],
            positions: ["status:\(Self.yeehaw)::Item-0": 10],
            drawn: [Self.a: [FakeSystem.item(Self.a, index: 1, x: 50), FakeSystem.item(Self.a, index: 0, x: 80)]])
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        let drawn = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        #expect(drawn.indexInApp == 0)
    }

    @Test func revealRequiresYeeHawKey() async throws {
        let system = try FakeSystem(allow: [(Self.a, false)], positions: ["status:\(Self.a)::Item-0": 300])
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        await #expect(throws: ControllerError.unresolvedNeighbor) {
            _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        }
        #expect(system.allowWrites == 0)
        #expect(system.positionWrites == 0)
        #expect(c.state.pendingReveal == nil)
    }

    @Test func revealNotHonoredIsUndone() async throws {
        let system = try Self.revealSystem()
        let original = system.positions
        system.honorsWrites = false
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        await #expect(throws: ControllerError.notHonored(Self.a)) {
            _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        }
        #expect(system.positions == original)
        #expect(system.allowSnapshot[Self.a] == false)
        #expect(c.state.pendingReveal == nil)
        #expect(rig.store.load().pendingReveal == nil)
    }

    @Test func overlappingRevealsKeepOriginalPositions() async throws {
        let system = try Self.revealSystem()
        try system.setExternally(Self.b, allowed: false)
        let original = system.positions
        let rig = Self.rig(system, state: HidingState(hidden: [Self.a, Self.b], journal: [Self.a, Self.b]))
        let c = rig.controller()
        let yeehawItem = FakeSystem.item(Self.yeehaw)
        _ = try await c.beginReveal(Self.a, nextTo: yeehawItem)

        async let first = c.beginReveal(Self.b, nextTo: yeehawItem)
        async let second = c.beginReveal(Self.a, nextTo: yeehawItem)
        _ = try await (first, second)

        // Either call may run last; exactly one app is pending, with its true original positions.
        let pending = try #require(c.state.pendingReveal)
        let other = pending.bundleID == Self.a ? Self.b : Self.a
        let key = "status:\(pending.bundleID)::Item-0"
        #expect(pending.originalPositions == [key: original[key]])
        #expect(system.allowSnapshot[pending.bundleID] == true)
        #expect(system.allowSnapshot[other] == false)
        #expect(system.positions["status:\(other)::Item-0"] == original["status:\(other)::Item-0"])
        try await c.endReveal()
        #expect(system.positions == original)
        #expect(system.allowSnapshot == [Self.a: false, Self.b: false, Self.yeehaw: true])
    }

    @Test func crashMidRevealRecoveredOnLaunch() async throws {
        let system = try Self.revealSystem()
        let original = system.positions
        let store = FakeStore(HidingState(hidden: [Self.a], journal: [Self.a]), system: system)
        let rig = Rig(system: system, store: store)
        do {
            let c = rig.controller()
            _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
            #expect(system.allowSnapshot[Self.a] == true)
        }
        let fresh = rig.controller()
        #expect(fresh.state.pendingReveal != nil)
        try await fresh.launch()
        #expect(system.positions == original)
        #expect(system.allowSnapshot[Self.a] == false)
        #expect(fresh.state.pendingReveal == nil)
        #expect(fresh.state.hidden == [Self.a])
        #expect(fresh.state.journal == [Self.a])
        #expect(store.load().pendingReveal == nil)
    }

    // MARK: launch / quit / external changes

    @Test func launchWritesAllActionsOnceWithoutWaiting() async throws {
        let rig = Self.rig(
            try FakeSystem(allow: [(Self.a, true), (Self.b, false)]),
            state: HidingState(hidden: [Self.a], journal: [Self.b]))
        rig.system.honorsWrites = false
        let c = rig.controller()
        try await c.launch()
        #expect(rig.system.allowWrites == 1)
        #expect(rig.system.allowSnapshot == [Self.a: false, Self.b: true])
        #expect(rig.sleeper.count == 0)
        #expect(c.state.journal == [Self.a])
    }

    @Test func quitSwitchesJournalOnInOneWrite() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        try await c.hide(Self.b)
        rig.system.honorsWrites = false
        let sleepsBefore = rig.sleeper.count
        try c.quit()
        #expect(rig.system.allowWrites == 3)
        #expect(rig.system.allowSnapshot == [Self.a: true, Self.b: true])
        #expect(c.state.journal.isEmpty)
        #expect(rig.store.load().journal.isEmpty)
        #expect(rig.sleeper.count == sleepsBefore)
    }

    @Test func ownWriteIsNotExternalChange() async throws {
        let system = try Self.revealSystem()
        try system.setExternally(Self.a, allowed: true)
        let rig = Self.rig(system)
        let c = rig.controller()
        try await c.launch()
        try await c.hide(Self.a)
        try await c.allowListChanged()
        #expect(c.state.hidden == [Self.a])
        #expect(c.state.journal == [Self.a])
        // A reveal switches A on while it stays journaled; that own write must not release it.
        _ = try await c.beginReveal(Self.a, nextTo: FakeSystem.item(Self.yeehaw))
        try await c.allowListChanged()
        #expect(c.state.hidden == [Self.a])
        #expect(c.state.journal == [Self.a])
    }

    @Test func externalSwitchOnReleasesApp() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        try rig.system.setExternally(Self.a, allowed: true)
        try await c.allowListChanged()
        #expect(c.state.hidden.isEmpty)
        #expect(c.state.journal.isEmpty)
        #expect(c.items.contains { $0.bundleID == Self.a })
        #expect(rig.store.load() == c.state)
    }

    @Test func unchangedAllowListReadsNothingElseAndSavesNothing() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.launch()
        try await c.hide(Self.a)
        let reads = rig.system.itemReads
        let saves = rig.store.saveCount
        try await c.allowListChanged()
        try await c.allowListChanged()
        #expect(rig.system.itemReads == reads)
        #expect(rig.store.saveCount == saves)
        #expect(c.state.hidden == [Self.a])
    }

    @Test func changedAllowListStillReconciles() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.launch()
        try await c.hide(Self.a)
        try await c.allowListChanged() // unchanged: skipped
        try rig.system.setExternally(Self.a, allowed: true)
        let reads = rig.system.itemReads
        try await c.allowListChanged()
        #expect(c.state.hidden.isEmpty)
        #expect(c.state.journal.isEmpty)
        #expect(rig.system.itemReads == reads + 1)
        #expect(rig.store.load() == c.state)
    }

    @Test func anUnchangedStateIsNotSavedAgain() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]),
                           state: HidingState(hidden: [Self.a], journal: [Self.a]))
        let c = rig.controller()
        try await c.launch()
        let saves = rig.store.saveCount
        // The user switches B off: the list changed, but YeeHaw's state didn't, so it isn't saved.
        try rig.system.setExternally(Self.b, allowed: false)
        let reads = rig.system.itemReads
        try await c.allowListChanged()
        #expect(rig.system.itemReads == reads + 1)
        #expect(rig.store.saveCount == saves)
        #expect(c.state == HidingState(hidden: [Self.a], journal: [Self.a]))
    }

    @Test func externalSwitchOnSurvivesUnrelatedWrite() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        try rig.system.setExternally(Self.a, allowed: true)
        try await c.hide(Self.b)
        try await c.allowListChanged()
        #expect(c.state.hidden == [Self.b])
        #expect(c.state.journal == [Self.b])
    }

    @Test func unchangedWritesAreSkipped() async throws {
        let rig = Self.rig(
            try FakeSystem(allow: [(Self.a, true)], positions: ["status:\(Self.a)::Item-0": 50]),
            state: HidingState(journal: [Self.a]))
        let c = rig.controller()
        // A journaled app that's already on: the switch-on changes nothing, so nothing is written.
        try await c.show(Self.a)
        #expect(c.state.journal.isEmpty)
        try c.quit()
        try c.move(FakeSystem.item(Self.a), leftNeighbor: nil, rightNeighbor: nil)
        let positionWrites = rig.system.positionWrites
        try c.move(FakeSystem.item(Self.a), leftNeighbor: nil, rightNeighbor: nil)
        #expect(rig.system.positionWrites == positionWrites)
        #expect(rig.system.allowWrites == 0)
    }

    @Test func missingAllowKeyIsNeverCreated() async throws {
        let rig = Self.rig(try FakeSystem(allow: []), state: HidingState(journal: [Self.a]))
        let c = rig.controller()
        try await c.launch()
        try c.quit()
        #expect(rig.system.allowWrites == 0)
    }

    // MARK: strip order, user-owned, adopt

    @Test func reorderHiddenPersistsOrder() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, true), (Self.b, true)]))
        let c = rig.controller()
        try await c.hide(Self.a)
        try await c.hide(Self.b)
        c.reorderHidden([Self.b, Self.a])
        #expect(c.state.hidden == [Self.b, Self.a])
        #expect(rig.store.load().hidden == [Self.b, Self.a])
    }

    @Test func userOwnedOffAndAdopt() async throws {
        let rig = Self.rig(try FakeSystem(allow: [(Self.a, false), (Self.b, false)]))
        let c = rig.controller()
        #expect(try c.userOwnedOff() == [Self.a, Self.b])
        try await c.adopt([Self.b])
        #expect(c.state.hidden == [Self.b])
        #expect(c.state.journal == [Self.b])
        #expect(try c.userOwnedOff() == [Self.a])
        #expect(rig.system.allowWrites == 0)
    }
}
