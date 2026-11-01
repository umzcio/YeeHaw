import AppKit
import Foundation
import Testing
@testable import YeeHaw
import YeeHawCore

/// A bar that draws a fixed set of third-party items, behind preference files that can be made to
/// refuse access. Enough to drive `LayoutModel`'s edits through a real `MenuBarController`.
private final class StubBar: MenuBarReading, PreferencesFile, StateStoring, Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var allowBlob: Data
    private var state = HidingState.empty
    private var _refusing = false
    let drawn: [MenuBarItem]

    /// `icons`: how many icons each app draws (one unless given).
    init(apps: [BundleID], icons: [BundleID: Int] = [:]) throws {
        var entries: [Any] = []
        for id in apps {
            entries.append(["bundle": ["_0": id]])
            entries.append(["location": ["bundle": ["_0": id]], "isAllowed": true] as [String: Any])
        }
        allowBlob = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        drawn = apps.flatMap { id in (0..<(icons[id] ?? 1)).map { (id, $0) } }.enumerated().map { slot, icon in
            MenuBarItem(id: "\(icon.0)#\(icon.1)", bundleID: icon.0, appleIdentifier: nil, indexInApp: icon.1,
                        axIdentifier: "", label: icon.0, keyNames: [], keyPrefixes: [icon.0],
                        x: Double(100 + 40 * slot), width: 20, isPinned: false)
        }
    }

    /// Reads and writes of the Allow list fail as if the grant were lost.
    var refusing: Bool {
        get { lock.withLock { _refusing } }
        set { lock.withLock { _refusing = newValue } }
    }

    // PreferencesFile (the Allow list; the positions file isn't touched by these tests).
    func read(_ key: String) throws -> Any? {
        try lock.withLock {
            if _refusing { throw GrantError.needsGrant(.allowList) }
            return key == "trackedApplications" ? allowBlob : nil
        }
    }

    func write(_ key: String, _ value: Any) throws {
        try lock.withLock {
            if _refusing { throw GrantError.needsGrant(.allowList) }
            if key == "trackedApplications", let data = value as? Data { allowBlob = data }
        }
    }

    // MenuBarReading: nothing is running, so the controller never waits for a flip.
    func items() async -> [MenuBarItem] { drawn }
    func runningBundleIDs() async -> Set<BundleID> { [] }
    func keyPrefixes(of id: BundleID) async -> [String] { [id] }

    // StateStoring and Sleeper.
    func load() -> HidingState { lock.withLock { state } }
    func save(_ s: HidingState) { lock.withLock { state = s } }
    func sleep(seconds: Double) async {}
}

@MainActor @Suite struct LayoutModelEditTests {
    static let a = "com.example.A"
    static let b = "com.example.B"

    fileprivate static func model(icons: [BundleID: Int] = [:]) async throws -> (LayoutModel, StubBar, URL) {
        let bar = try StubBar(apps: [a, b], icons: icons)
        let controller = MenuBarController(allowFile: bar, positionFile: bar, reader: bar, store: bar, sleeper: bar)
        try await controller.launch()
        let directory = FileManager.default.temporaryDirectory.appending(path: "YeeHawTests-\(UUID().uuidString)")
        let model = LayoutModel(controller: controller, images: IconImageProvider(directory: directory, capturesScreen: false))
        return (model, bar, directory)
    }

    @Test func anEditInProgressBlocksEveryOtherEdit() async throws {
        let (model, _, directory) = try await Self.model()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(model.bar.map(\.item.bundleID) == [Self.a, Self.b])
        let hide = try #require(model.hide(from: 0, at: 0))
        #expect(model.busy)
        #expect(model.hidden.map(\.id) == [Self.a])
        // Nothing else starts until the first edit's rows are back.
        #expect(model.hide(from: 0, at: 1) == nil)
        #expect(model.show(Self.a, at: 0) == nil)
        model.reorderHidden(Self.a, at: 1)
        await hide.value
        #expect(!model.busy)
        #expect(model.hidden.map(\.id) == [Self.a])
        #expect(model.bar.map(\.item.bundleID) == [Self.b])
    }

    @Test func aSpacingApplyBlocksEveryEdit() async throws {
        // Apps quit and reopen during Apply; a move of one mid-restart would time out.
        let (model, _, directory) = try await Self.model()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.spacingBusy = true
        #expect(model.editsLocked)
        #expect(model.move(from: 0, to: 2) == nil)
        #expect(model.hide(from: 0, at: 0) == nil)
        #expect(model.hidden.isEmpty)
        model.spacingBusy = false
        let hide = try #require(model.hide(from: 0, at: 0))
        #expect(model.editsLocked)
        await hide.value
        #expect(!model.editsLocked)
    }

    @Test func aFailedEditSnapsBackAndOffersToFixTheGrant() async throws {
        let (model, bar, directory) = try await Self.model()
        defer { try? FileManager.default.removeItem(at: directory) }
        bar.refusing = true
        let hide = try #require(model.hide(from: 0, at: 0))
        await hide.value
        #expect(!model.busy)
        #expect(model.hidden.isEmpty)
        #expect(model.bar.map(\.item.bundleID) == [Self.a, Self.b])
        #expect(model.message?.grant == .allowList)
        #expect(model.message?.offersFix == true)
    }

    @Test func rowsDontChangeUnderADragUntilItEnds() async throws {
        let (model, bar, directory) = try await Self.model()
        defer { try? FileManager.default.removeItem(at: directory) }
        bar.refusing = true
        let hide = try #require(model.hide(from: 0, at: 0))
        model.isDragging = true
        await hide.value
        // The failed hide would put A back in the bar, but a drag is live: the rows wait.
        #expect(!model.busy)
        #expect(model.hidden.map(\.id) == [Self.a])
        model.dragEnded()
        #expect(model.hidden.isEmpty)
        #expect(model.bar.map(\.item.bundleID) == [Self.a, Self.b])
    }

    @Test func aHiddenGroupHasATilePerIconTheAppDrew() async throws {
        let (model, _, directory) = try await Self.model(icons: [Self.a: 3])
        defer { try? FileManager.default.removeItem(at: directory) }
        // Hiding from any one of A's three tiles takes the whole group, a tile per icon.
        let hide = try #require(model.hide(from: 1, at: 0))
        #expect(model.bar.map(\.item.bundleID) == [Self.b])
        #expect(model.hidden.first?.icons.map(\.id) == ["\(Self.a)#0", "\(Self.a)#1", "\(Self.a)#2"])
        await hide.value
    }
}

@Suite struct LayoutGeometryTests {
    /// Three tiles 30 wide, 6 apart, from x 10.
    static let spans: [(minX: CGFloat, maxX: CGFloat)] = [(10, 40), (46, 76), (82, 112)]

    @Test func aSlotFromAnotherRowOpensAtTheInsertion() {
        #expect(LayoutGeometry.slotMinX(insertion: 1, from: nil, spans: Self.spans, width: 50, spacing: 6, rowStart: 7) == 46)
        #expect(LayoutGeometry.slotMinX(insertion: 3, from: nil, spans: Self.spans, width: 50, spacing: 6, rowStart: 7) == 118)
        #expect(LayoutGeometry.slotMinX(insertion: 0, from: nil, spans: [], width: 50, spacing: 6, rowStart: 7) == 7)
    }

    @Test func aSlotInTheTilesOwnRowOpensWhereItLands() {
        // Tile 2 held before tile 0: the slot opens at tile 0's place.
        #expect(LayoutGeometry.slotMinX(insertion: 0, from: 2, spans: Self.spans, width: 30, spacing: 6, rowStart: 7) == 10)
        // Tile 0 held at the end: tiles 1 and 2 close up; the slot ends where tile 2 ended.
        #expect(LayoutGeometry.slotMinX(insertion: 3, from: 0, spans: Self.spans, width: 30, spacing: 6, rowStart: 7) == 82)
    }
}

@Suite struct LayoutMetricsHeadroomTests {
    /// Bar tiles 40 and 120 wide (natural 40 + 6 + 120 + 14 = 180); one hidden group 80 wide
    /// (natural 94). A group shown into the bar takes 70; an app hidden from the bar takes 46.
    @Test func theRowsLeaveRoomForOneIncomingSlotInEitherRow() {
        // The bar with the widest group shown into it: 180 + 70 + 6 = 256, under the minimum.
        #expect(LayoutMetrics.rowWidthWithHeadroom(bar: [40, 120], hidden: [80], barIncoming: [70, 30],
                                                   hiddenIncoming: [46], minimum: 200) == 256)
        // Nothing incoming fits under the minimum: the minimum wins.
        #expect(LayoutMetrics.rowWidthWithHeadroom(bar: [40, 120], hidden: [80], barIncoming: [70],
                                                   hiddenIncoming: [46], minimum: 300) == 300)
    }

    @Test func theHiddenRowCanBeTheOneThatNeedsTheRoom() {
        // Hidden natural 4 × 100 + 3 × 6 + 14 = 432, plus the widest app (120) and spacing: 558.
        #expect(LayoutMetrics.rowWidthWithHeadroom(bar: [40], hidden: [100, 100, 100, 100], barIncoming: [30],
                                                   hiddenIncoming: [46, 120], minimum: 200) == 558)
    }

    @Test func aRowWithNothingThatCanComeInGetsNoHeadroom() {
        // No hidden groups to show and no app that can be hidden: just the natural widths.
        #expect(LayoutMetrics.rowWidthWithHeadroom(bar: [40, 120], hidden: [], barIncoming: [],
                                                   hiddenIncoming: [], minimum: 100) == 180)
    }
}

@Suite struct LayoutMetricsGroupWidthTests {
    @Test func aLoneTileHasNoBackingAndSeveralShareOne() {
        #expect(LayoutMetrics.groupWidth([40]) == 40)
        // 40 + 2 + 30, plus the backing's inset either side.
        #expect(LayoutMetrics.groupWidth([40, 30]) == 78)
    }
}
