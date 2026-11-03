import AppKit
import Foundation
import Testing
@testable import YeeHaw
import YeeHawCore

/// A bar behind the two preference files, enough to drive `LayoutModel` through a real
/// `MenuBarController`. Apps are drawn while they're switched on, left to right by their saved
/// positions (larger further left), so moves and hides show up on the next read. Files can be
/// made to refuse access, and an app can be made to ignore its switch.
private final class StubBar: MenuBarReading, PreferencesFile, StateStoring, Sleeper, @unchecked Sendable {
    private let lock = NSLock()
    private var allowBlob: Data
    private var positions: [String: Double] = [:]
    private var state: HidingState
    private var _refusing = false
    private var _running: Set<BundleID> = []
    private var _stuck: Set<BundleID> = []
    private var icons: [BundleID: Int]
    private var _log: [String] = []

    /// `apps` left to right, `hidden` ones switched off by YeeHaw; `icons`: how many icons each
    /// app draws (one unless given).
    init(apps: [BundleID], hidden: [BundleID] = [], icons: [BundleID: Int] = [:]) throws {
        var entries: [Any] = []
        for id in apps {
            entries.append(["bundle": ["_0": id]])
            entries.append(["location": ["bundle": ["_0": id]], "isAllowed": !hidden.contains(id)] as [String: Any])
        }
        allowBlob = try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
        state = HidingState(hidden: hidden, journal: Set(hidden))
        self.icons = icons
        for (slot, id) in apps.enumerated() {
            for icon in 0..<(icons[id] ?? 1) {
                positions["status:\(id)::Item-\(icon)"] = Double(1000 - 100 * slot - icon)
            }
        }
        positions[PositionKey.clock] = 0
    }

    /// Reads and writes of the Allow list fail as if the grant were lost.
    var refusing: Bool {
        get { lock.withLock { _refusing } }
        set { lock.withLock { _refusing = newValue } }
    }

    /// Apps running, so YeeHaw waits for their switches to show.
    var running: Set<BundleID> {
        get { lock.withLock { _running } }
        set { lock.withLock { _running = newValue } }
    }

    /// Apps that stay drawn whatever their switch says.
    var stuck: Set<BundleID> {
        get { lock.withLock { _stuck } }
        set { lock.withLock { _stuck = newValue } }
    }

    /// Every write, in order: "allow" or "positions" (and whatever a test appends).
    var log: [String] { lock.withLock { _log } }
    func append(_ event: String) { lock.withLock { _log.append(event) } }

    var allow: AllowSnapshot { lock.withLock { (try? AllowList(data: allowBlob))?.snapshot ?? [:] } }

    /// A new app starts drawing an icon at `position` (macOS adds its entry).
    func launch(_ id: BundleID, position: Double) throws {
        try lock.withLock {
            let items = try #require(PropertyListSerialization.propertyList(from: allowBlob, options: [], format: nil) as? [Any])
            let entry: [Any] = [["bundle": ["_0": id]], ["location": ["bundle": ["_0": id]], "isAllowed": true] as [String: Any]]
            allowBlob = try PropertyListSerialization.data(fromPropertyList: items + entry, format: .binary, options: 0)
            positions["status:\(id)::Item-0"] = position
        }
    }

    /// The bar is rearranged outside YeeHaw.
    func setPosition(_ id: BundleID, _ value: Double) { lock.withLock { positions["status:\(id)::Item-0"] = value } }

    /// macOS hasn't saved a position for the app's icon (it's drawn at the right end).
    func removePosition(_ id: BundleID) { lock.withLock { positions["status:\(id)::Item-0"] = nil } }

    // PreferencesFile: one object stands for both files, told apart by key.
    func read(_ key: String) throws -> Any? {
        try lock.withLock {
            switch key {
            case MenuBarController.allowKey:
                if _refusing { throw GrantError.needsGrant(.allowList) }
                return allowBlob
            case MenuBarController.positionsKey: return positions
            default: return nil
            }
        }
    }

    func write(_ key: String, _ value: Any) throws {
        try lock.withLock {
            switch key {
            case MenuBarController.allowKey:
                if _refusing { throw GrantError.needsGrant(.allowList) }
                allowBlob = try #require(value as? Data)
                _log.append("allow")
            case MenuBarController.positionsKey:
                positions = try #require(value as? [String: Double])
                _log.append("positions")
            default: break
            }
        }
    }

    // MenuBarReading.
    func items() async -> [MenuBarItem] {
        let allow = self.allow
        return lock.withLock {
            let drawn = allow.keys.filter { allow[$0] == true || _stuck.contains($0) }.flatMap { id in
                (0..<(icons[id] ?? 1)).map { icon in
                    (MenuBarItem(id: "\(id)#\(icon)", bundleID: id, appleIdentifier: nil, indexInApp: icon, label: id,
                                 keyNames: [], keyPrefixes: [id], x: 0, width: 20, isPinned: false),
                     positions["status:\(id)::Item-\(icon)"] ?? 0)
                }
            }
            return drawn.sorted { $0.1 > $1.1 }.enumerated().map { slot, entry in
                var item = entry.0
                item.x = Double(100 + 40 * slot)
                return item
            }
        }
    }

    func runningBundleIDs() async -> Set<BundleID> { running }
    func runningCopies(of id: BundleID) async -> [RunningCopy] { [] }
    func keyPrefixes(of id: BundleID) async -> [String] { [id] }

    // StateStoring and Sleeper.
    func load() -> HidingState { lock.withLock { state } }
    func save(_ s: HidingState) { lock.withLock { state = s } }
    func sleep(seconds: Double) async {}
}

@MainActor @Suite struct LayoutModelEditTests {
    static let a = "com.example.A"
    static let b = "com.example.B"
    static let c = "com.example.C"
    static let h = "com.example.H"

    fileprivate static func model(_ bar: StubBar) async throws -> (LayoutModel, URL) {
        let controller = MenuBarController(allowFile: bar, positionFile: bar, reader: bar, store: bar, sleeper: bar)
        try await controller.launch()
        let directory = FileManager.default.temporaryDirectory.appending(path: "YeeHawTests-\(UUID().uuidString)")
        let model = LayoutModel(controller: controller, images: IconImageProvider(directory: directory, capturesScreen: false))
        model.applyTimeout = .milliseconds(100)
        return (model, directory)
    }

    static func apps(_ model: LayoutModel) -> [BundleID?] { model.bar.map(\.item.bundleID) }

    @Test func editsChangeOnlyTheDraft() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b, Self.c, Self.h], hidden: [Self.h])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!model.isDirty)
        #expect(model.apply() == nil)
        #expect(model.hide(from: 0, at: 0))
        #expect(model.move(from: 1, to: 0))
        #expect(model.show(Self.h, at: 1))
        #expect(Self.apps(model) == [Self.c, Self.h, Self.b])
        #expect(model.hidden.map(\.id) == [Self.a])
        #expect(model.isDirty)
        #expect(!model.applying)
        #expect(!model.editsLocked)
        // Nothing is written until Apply.
        #expect(bar.log.isEmpty)
        #expect(model.summary == "3 changes")
    }

    @Test func applyWritesShowsHidesMovesThenSpacing() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b, Self.c, Self.h], hidden: [Self.h])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mac = FakeSpacingMac()
        let spacing = SpacingModel(applier: SpacingApplier(system: mac.system))
        spacing.onApplyingChange = { if $0 { bar.append("spacing") } }
        model.spacing = spacing
        model.move(from: 2, to: 0)        // C A B
        model.hide(from: 1, at: 1)        // C B; Hidden H A
        model.show(Self.h, at: 1)         // C H B
        spacing.value = 8
        #expect(model.summary == "4 changes")
        let applying = try #require(model.apply())
        #expect(model.applying)
        #expect(model.editsLocked)
        #expect(!model.move(from: 0, to: 2))
        let failures = await applying.value
        #expect(failures.isEmpty)
        // Show H, hide A, move C, then place H once its neighbours are final; spacing last.
        #expect(bar.log == ["allow", "allow", "positions", "positions", "spacing"])
        #expect(Self.apps(model) == [Self.c, Self.h, Self.b])
        #expect(model.hidden.map(\.id) == [Self.a])
        #expect(model.controller.state.hidden == [Self.a])
        #expect(spacing.current == 8)
        #expect(!model.isDirty)
        #expect(!model.applying)
        #expect(model.message == nil)
    }

    @Test func spacingAppliesWhatTheFooterShowedWhenApplyWasClicked() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mac = FakeSpacingMac()
        let spacing = SpacingModel(applier: SpacingApplier(system: mac.system))
        model.spacing = spacing
        spacing.setApps([SpacingModelTests.app("DigUp")])
        spacing.value = 8
        let applying = try #require(model.apply())
        // The window's re-read and a close land before the spacing part starts.
        spacing.setApps([SpacingModelTests.app("DigUp"), SpacingModelTests.app("Flame")])
        spacing.windowClosed()
        _ = await applying.value
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"])
        #expect(spacing.current == 8)
        #expect(spacing.value == 8)
        #expect(!model.applying)
    }

    @Test func aFailedEditGoesBackAndTheOthersStand() async throws {
        // A ignores its switch: the hide never shows, so it's undone after the wait.
        let bar = try StubBar(apps: [Self.a, Self.b, Self.c])
        bar.running = [Self.a]
        bar.stuck = [Self.a]
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.hide(from: 0, at: 0)
        model.move(from: 1, to: 0)        // C B
        let failures = try #require(await model.apply()?.value)
        #expect(failures.count == 1)
        #expect(bar.allow[Self.a] == true)
        #expect(model.controller.state.hidden.isEmpty)
        #expect(model.hidden.isEmpty)
        #expect(Self.apps(model) == [Self.a, Self.c, Self.b])
        #expect(model.message?.text == "macOS didn’t update \(AppIdentity.name(of: Self.a)) in time. Try again in a moment.")
        #expect(!model.isDirty)
    }

    @Test func anIconPutNextToOneWithNoSavedPositionIsNamedIfItDidntLandThere() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b, Self.c])
        bar.removePosition(Self.b)
        bar.setPosition(Self.c, 500)
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(Self.apps(model) == [Self.a, Self.c, Self.b])
        // A between C and B: placed after C, the nearest anchor, it lands there.
        model.move(from: 0, to: 2)
        _ = await model.apply()?.value
        #expect(Self.apps(model) == [Self.c, Self.a, Self.b])
        #expect(model.message == nil)
        // A after B: B can't anchor, so A is placed after C again, and can't get past B.
        model.move(from: 1, to: 3)
        _ = await model.apply()?.value
        #expect(Self.apps(model) == [Self.c, Self.a, Self.b])
        #expect(model.message?.text == LayoutModel.message(for: ControllerError.unresolvedNeighbor).text)
    }

    @Test func aFailedEditOffersToFixTheGrant() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        bar.refusing = true
        model.hide(from: 0, at: 0)
        _ = await model.apply()?.value
        #expect(model.hidden.isEmpty)
        #expect(Self.apps(model) == [Self.a, Self.b])
        #expect(model.message?.grant == .allowList)
        #expect(model.message?.offersFix == true)
    }

    @Test func revertPutsTheDraftBack() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b, Self.h], hidden: [Self.h])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.hide(from: 0, at: 0)
        model.show(Self.h, at: nil)
        model.revert()
        #expect(!model.isDirty)
        #expect(Self.apps(model) == [Self.a, Self.b])
        #expect(model.hidden.map(\.id) == [Self.h])
    }

    @Test func aShowFromTheKeyboardGoesToTheRowsRightEnd() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b, Self.h], hidden: [Self.h])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.show(Self.h, at: nil)
        #expect(Self.apps(model) == [Self.a, Self.b, Self.h])
        #expect(model.summary == "Show \(AppIdentity.name(of: Self.h))")
    }

    @Test func theBarChangingUnderADraftKeepsItsEdits() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.move(from: 0, to: 2)        // B A
        try bar.launch(Self.c, position: 2000)
        await model.refresh()
        #expect(Self.apps(model) == [Self.c, Self.b, Self.a])
        #expect(model.isDirty)
    }

    @Test func aCleanDraftFollowsTheBar() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        bar.setPosition(Self.b, 5000)
        await model.refresh()
        #expect(Self.apps(model) == [Self.b, Self.a])
        #expect(!model.isDirty)
    }

    @Test func aSpacingApplyBlocksEveryEdit() async throws {
        // Apps quit and reopen during Apply; a move of one mid-restart would time out.
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.spacingBusy = true
        #expect(model.editsLocked)
        #expect(!model.move(from: 0, to: 2))
        #expect(!model.hide(from: 0, at: 0))
        #expect(model.hidden.isEmpty)
        model.spacingBusy = false
        #expect(model.hide(from: 0, at: 0))
    }

    @Test func rowsDontChangeUnderADragUntilItEnds() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.isDragging = true
        bar.setPosition(Self.b, 5000)
        await model.refresh()
        #expect(Self.apps(model) == [Self.a, Self.b])
        model.isDragging = false
        await model.refresh()
        #expect(Self.apps(model) == [Self.b, Self.a])
    }

    @Test func aHiddenGroupHasATilePerIconTheAppDrew() async throws {
        let bar = try StubBar(apps: [Self.a, Self.b], icons: [Self.a: 3])
        let (model, directory) = try await Self.model(bar)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Hiding from any one of A's three tiles takes the whole group, a tile per icon.
        #expect(model.hide(from: 1, at: 0))
        #expect(Self.apps(model) == [Self.b])
        #expect(model.hidden.first?.icons.map(\.id) == ["\(Self.a)#0", "\(Self.a)#1", "\(Self.a)#2"])
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
