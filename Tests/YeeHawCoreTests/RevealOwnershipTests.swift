import Foundation
import Testing
@testable import YeeHawCore

/// A bar read the way `AXMenuBarReader` reads it: macOS draws `layout(allow)` for the Allow list it
/// has caught up with (`lag` reads after a change), and every running app's extras report the frame
/// its icon has while drawn and keep reporting the last one once it isn't (a stale frame), so
/// matching has to tell them apart. Files come from `system`.
final class MatchedBar: MenuBarReading, @unchecked Sendable {
    let system: FakeSystem
    private let lock = NSLock()
    private let layout: @Sendable (AllowSnapshot) -> [(BundleID, Double)]
    /// The order apps are asked for their extras (the running-apps order).
    private let appOrder: [BundleID]
    private var lastX: [BundleID: Double]
    private var drawnAllow: AllowSnapshot
    private var liveSeen: AllowSnapshot
    private var countdown = 0
    private var quit: Set<BundleID> = []
    private var _fullReads: [(off: Set<BundleID>, revealed: BundleID?)] = []
    /// Reads before the bar draws a change to the Allow list.
    var lag = 0
    /// Apps that quit at the moment the bar catches up with the next change.
    var quitOnCatchUp: Set<BundleID> = []

    static let width: Double = 20

    init(system: FakeSystem, appOrder: [BundleID], staleX: [BundleID: Double],
         layout: @escaping @Sendable (AllowSnapshot) -> [(BundleID, Double)]) {
        self.system = system
        self.appOrder = appOrder
        self.layout = layout
        lastX = staleX
        drawnAllow = system.allowSnapshot
        liveSeen = drawnAllow
    }

    /// What's drawn now, without counting as a read.
    func isDrawn(_ id: BundleID) -> Bool {
        lock.withLock { layout(drawnAllow).contains { $0.0 == id } && !quit.contains(id) }
    }

    var fullReads: [(off: Set<BundleID>, revealed: BundleID?)] { lock.withLock { _fullReads } }

    /// One look at the bar: catches up with the Allow list when the lag has run out, then returns
    /// what's drawn and every running app's extras.
    private func look() -> ([DrawnItem], [AppExtra]) {
        let live = system.allowSnapshot
        return lock.withLock {
            if live != liveSeen {
                liveSeen = live
                countdown = lag
            }
            if countdown > 0 {
                countdown -= 1
            } else if drawnAllow != live {
                drawnAllow = live
                quit.formUnion(quitOnCatchUp)
                quitOnCatchUp = []
            }
            let placed = layout(drawnAllow).filter { !quit.contains($0.0) }
            for (id, x) in placed { lastX[id] = x }
            let drawn = placed.map { DrawnItem(x: $0.1, width: Self.width, label: $0.0) }
                .sorted { $0.x < $1.x }
            let extras = appOrder.filter { !quit.contains($0) }.map { id in
                AppExtra(bundleID: id, indexInApp: 0, x: lastX[id] ?? -1, width: Self.width)
            }
            return (drawn, extras)
        }
    }

    func items() async -> [MenuBarItem] {
        let (drawn, extras) = look()
        return ItemMatcher.match(drawn: drawn, extras: extras)
    }

    func items(offApps: Set<BundleID>, revealed: BundleID?) async -> [MenuBarItem] {
        let (drawn, extras) = look()
        lock.withLock { _fullReads.append((offApps, revealed)) }
        return ItemMatcher.match(drawn: drawn, extras: extras, offApps: offApps, revealed: revealed)
    }

    func drawnBar(owning id: BundleID) async -> [MenuBarItem] {
        let (drawn, extras) = look()
        return ItemMatcher.match(drawn: drawn, extras: extras.filter { $0.bundleID == id })
    }

    func runningBundleIDs() async -> Set<BundleID> {
        lock.withLock { Set(appOrder).subtracting(quit) }
    }

    /// No copies to list: these tests are about which icon is whose.
    func runningCopies(of id: BundleID) async -> [RunningCopy] { [] }

    func keyPrefixes(of id: BundleID) async -> [String] { [id] }
}

@MainActor @Suite struct RevealOwnershipTests {
    nonisolated static let x = "com.example.X"
    nonisolated static let w = "com.example.W"
    nonisolated static let z = "com.example.Z"
    nonisolated static let yeehaw = "com.zapps.yeehaw"

    struct Rig {
        let bar: MatchedBar
        let store: FakeStore
        let sleeper = FakeSleeper()

        @MainActor func controller() -> MenuBarController {
            MenuBarController(
                allowFile: FakeFile(system: bar.system, file: .allowList),
                positionFile: FakeFile(system: bar.system, file: .positions),
                reader: bar, store: store, sleeper: sleeper)
        }
    }

    /// YeeHaw at 300; X, when on, at the reveal slot 270 left of it; then W and Z, each 30 further
    /// left. X was last drawn at 270, so while it's off it reports W's frame.
    static func rig(withZ: Bool = false) throws -> Rig {
        let (x, w, z, yeehaw) = (Self.x, Self.w, Self.z, Self.yeehaw)
        var allow: [(BundleID, Bool)] = [(x, false), (w, true), (yeehaw, true)]
        var positions: [String: Double] = [
            "status:\(x)::Item-0": 300, "status:\(w)::Item-0": 100, "status:\(yeehaw)::Item-0": 10,
            PositionKey.controlCenter: 5, PositionKey.clock: 0,
        ]
        if withZ {
            allow.append((z, true))
            positions["status:\(z)::Item-0"] = 200
        }
        let system = try FakeSystem(allow: allow, positions: positions)
        let bar = MatchedBar(system: system, appOrder: [x, w, z, yeehaw].filter { withZ || $0 != z },
                             staleX: [x: 270]) { allow in
            var placed: [(BundleID, Double)] = [(yeehaw, 300)]
            var next = 270.0
            for id in [x, w, z] where allow[id] == true {
                placed.append((id, next))
                next -= 30
            }
            return placed
        }
        return Rig(bar: bar, store: FakeStore(HidingState(hidden: [x], journal: [x]), system: system))
    }

    static var yeehawItem: MenuBarItem { FakeSystem.item(yeehaw) }

    @Test func aStaleFrameOnTheNeighbourDoesNotEndTheRevealWaitEarly() async throws {
        let rig = try Self.rig()
        rig.bar.lag = 3
        let c = rig.controller()
        try await c.launch()
        #expect(c.items.contains { $0.bundleID == Self.w && $0.x == 270 })

        let item = try await c.beginReveal(Self.x, nextTo: Self.yeehawItem)
        // X reported 270 all along, which is W's place until X is drawn there.
        #expect(rig.bar.isDrawn(Self.x))
        #expect(item.bundleID == Self.x)
        #expect(item.x == 270)
    }

    @Test func aRevealedAppReportingTheNeighboursFrameAfterSwitchOffEndsPromptly() async throws {
        let rig = try Self.rig()
        let c = rig.controller()
        try await c.launch()
        _ = try await c.beginReveal(Self.x, nextTo: Self.yeehawItem)
        let sleepsBefore = rig.sleeper.count
        // X stays drawn for three more looks after the switch-off; the wait must see it go.
        rig.bar.lag = 3

        try await c.endReveal()
        // W slid back into 270, where X still says it is.
        #expect(!rig.bar.isDrawn(Self.x))
        #expect(rig.sleeper.count - sleepsBefore <= 4)
        #expect(!c.items.contains { $0.bundleID == Self.x })
        #expect(c.items.contains { $0.bundleID == Self.w && $0.x == 270 })
        #expect(c.state.pendingReveal == nil)
        #expect(rig.bar.system.allowSnapshot[Self.x] == false)
    }

    @Test func anAmbiguousBarIsSettledByAFullRead() async throws {
        // Z quits just as X appears, so the bar holds as many items as before and X's real
        // frame is where W was. The per-app read can't vouch for X; a full read can.
        let rig = try Self.rig(withZ: true)
        rig.bar.lag = 2
        rig.bar.quitOnCatchUp = [Self.z]
        let c = rig.controller()
        try await c.launch()

        let item = try await c.beginReveal(Self.x, nextTo: Self.yeehawItem)
        #expect(rig.bar.isDrawn(Self.x))
        #expect(item.x == 270)
        #expect(rig.sleeper.count < 20)
        // That full read tried X after the apps that are on, not with the apps that are off.
        let settling = try #require(rig.bar.fullReads.last)
        #expect(settling.revealed == Self.x)
        #expect(!settling.off.contains(Self.x))
    }

    @Test func anEndingRevealIsSeenGoneEvenWhenTheAppNeverDrew() async throws {
        // The bar never drew X (its reveal timed out): nothing it shows is X's, so the stale
        // match on W can't keep the end waiting.
        let rig = try Self.rig()
        rig.bar.lag = 1_000
        let c = rig.controller()
        try await c.launch()
        await #expect(throws: ControllerError.notHonored(Self.x)) {
            _ = try await c.beginReveal(Self.x, nextTo: Self.yeehawItem)
        }
        let sleeps = rig.sleeper.count
        #expect(sleeps <= 101)
        #expect(c.state.pendingReveal == nil)
        #expect(!c.items.contains { $0.bundleID == Self.x })
    }
}
