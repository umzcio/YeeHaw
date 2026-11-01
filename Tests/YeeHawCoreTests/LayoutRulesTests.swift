import Testing
@testable import YeeHawCore

@Suite struct LayoutRulesTests {
    static let own = "com.zapps.yeehaw"
    static let a = "com.example.A"
    static let b = "com.example.B"
    static let c = "com.example.C"

    static func app(_ id: BundleID, index: Int = 0, x: Double) -> MenuBarItem {
        MenuBarItem(id: "\(id)#\(index)", bundleID: id, appleIdentifier: nil, indexInApp: index, axIdentifier: "",
                    label: id, keyNames: [], keyPrefixes: [id], x: x, width: 20, isPinned: false)
    }

    static func apple(_ name: String, x: Double, pinned: Bool = false) -> MenuBarItem {
        let id = "com.apple.menuextra.\(name)"
        return MenuBarItem(id: id, bundleID: nil, appleIdentifier: id, indexInApp: 0, axIdentifier: "", label: name,
                           keyNames: [], keyPrefixes: [], x: x, width: 20, isPinned: pinned)
    }

    static func unknown(x: Double) -> MenuBarItem {
        MenuBarItem(id: "unknown@\(Int(x))", bundleID: nil, appleIdentifier: nil, indexInApp: 0, axIdentifier: "",
                    label: "", keyNames: [], keyPrefixes: [], x: x, width: 20, isPinned: false)
    }

    /// own, A#0, A#1, Wi-Fi, B, Control Center, Clock
    static let bar: [MenuBarItem] = [
        app(own, x: 10), app(a, x: 40), app(a, index: 1, x: 70), apple("wifi", x: 100), app(b, x: 130),
        apple("controlcenter", x: 160, pinned: true), apple("clock", x: 190, pinned: true),
    ]

    // MARK: capability

    @Test func pinnedAndUnownedItemsAreFixed() {
        let tracked: Set<BundleID> = [Self.a, Self.b]
        #expect(LayoutRules.capability(of: Self.apple("clock", x: 0, pinned: true), own: Self.own, tracked: tracked)
            == .fixed(.pinned))
        #expect(LayoutRules.capability(of: Self.unknown(x: 0), own: Self.own, tracked: tracked) == .fixed(.unknownOwner))
    }

    @Test func appleOwnAndUntrackedItemsReorderButCannotHide() {
        let tracked: Set<BundleID> = [Self.a, Self.own]
        #expect(LayoutRules.capability(of: Self.apple("wifi", x: 0), own: Self.own, tracked: tracked)
            == .reorderOnly(.apple))
        #expect(LayoutRules.capability(of: Self.app(Self.own, x: 0), own: Self.own, tracked: tracked)
            == .reorderOnly(.own))
        #expect(LayoutRules.capability(of: Self.app(Self.b, x: 0), own: Self.own, tracked: tracked)
            == .reorderOnly(.notTrackedYet))
        #expect(LayoutRules.capability(of: Self.app(Self.a, x: 0), own: Self.own, tracked: tracked) == .hideable)
    }

    @Test func appleItemsAreFixedWhenModuleWritesDontWork() {
        #expect(LayoutRules.capability(of: Self.apple("wifi", x: 0), own: Self.own, tracked: [], appleMovable: false)
            == .fixed(.pinned))
    }

    @Test func capabilityAnswersWhatADragMayDo() {
        #expect(!TileCapability.fixed(.pinned).canDrag)
        #expect(TileCapability.reorderOnly(.apple).canDrag)
        #expect(!TileCapability.reorderOnly(.apple).canHide)
        #expect(TileCapability.reorderOnly(.apple).hideRefusal == .apple)
        #expect(TileCapability.hideable.canHide)
        #expect(TileCapability.hideable.hideRefusal == nil)
    }

    // MARK: insertion

    @Test func insertionIndexCountsMidpointsLeftOfThePointer() {
        let mids: [Double] = [10, 40, 70]
        #expect(LayoutRules.insertionIndex(forX: 0, midpoints: mids) == 0)
        #expect(LayoutRules.insertionIndex(forX: 25, midpoints: mids) == 1)
        #expect(LayoutRules.insertionIndex(forX: 69, midpoints: mids) == 2)
        #expect(LayoutRules.insertionIndex(forX: 500, midpoints: mids) == 3)
        #expect(LayoutRules.insertionIndex(forX: 5, midpoints: []) == 0)
    }

    @Test func nothingDropsRightOfThePinnedItems() {
        #expect(LayoutRules.allowedInsertions(in: Self.bar) == 0...5)
        #expect(LayoutRules.clampedInsertion(7, in: Self.bar) == 5)
        #expect(LayoutRules.clampedInsertion(6, in: Self.bar) == 5)
        #expect(LayoutRules.clampedInsertion(-1, in: Self.bar) == 0)
        #expect(LayoutRules.allowedInsertions(in: [Self.app(Self.a, x: 0)]) == 0...1)
        #expect(LayoutRules.allowedInsertions(in: []) == 0...0)
    }

    // MARK: menu bar moves

    @Test func moveNeighboursComeFromTheRowWithoutTheMovedItem() throws {
        // Wi-Fi (3) dropped before A#0 (insertion 1): between own and A#0.
        let n = try #require(LayoutRules.moveNeighbors(from: 3, to: 1, in: Self.bar))
        #expect(n.left?.id == "\(Self.own)#0")
        #expect(n.right?.id == "\(Self.a)#0")
        // own (0) dropped before Control Center (insertion 5): between B and Control Center.
        let m = try #require(LayoutRules.moveNeighbors(from: 0, to: 5, in: Self.bar))
        #expect(m.left?.id == "\(Self.b)#0")
        #expect(m.right?.id == "com.apple.menuextra.controlcenter")
    }

    @Test func droppingAnItemBesideItselfIsNoMove() {
        #expect(LayoutRules.moveNeighbors(from: 2, to: 2, in: Self.bar) == nil)
        #expect(LayoutRules.moveNeighbors(from: 2, to: 3, in: Self.bar) == nil)
    }

    @Test func farLeftHasNoLeftNeighbour() throws {
        let n = try #require(LayoutRules.moveNeighbors(from: 4, to: 0, in: Self.bar))
        #expect(n.left == nil)
        #expect(n.right?.id == "\(Self.own)#0")
    }

    @Test func unownedItemsAreSkippedAsNeighbours() throws {
        let row = [Self.app(Self.a, x: 0), Self.unknown(x: 30), Self.app(Self.b, x: 60), Self.app(Self.c, x: 90)]
        // C dropped between the unknown item and B: the unknown item can't anchor a move.
        let n = try #require(LayoutRules.moveNeighbors(from: 3, to: 2, in: row))
        #expect(n.left?.id == "\(Self.a)#0")
        #expect(n.right?.id == "\(Self.b)#0")
    }

    @Test func movedPreviewReordersTheRow() {
        let ids = LayoutRules.moved(Self.bar, from: 3, to: 1).map(\.id)
        #expect(ids == ["\(Self.own)#0", "com.apple.menuextra.wifi", "\(Self.a)#0", "\(Self.a)#1", "\(Self.b)#0",
                        "com.apple.menuextra.controlcenter", "com.apple.menuextra.clock"])
        #expect(LayoutRules.moved(Self.bar, from: 0, to: 5).map(\.id).prefix(5)
            == ["\(Self.a)#0", "\(Self.a)#1", "com.apple.menuextra.wifi", "\(Self.b)#0", "\(Self.own)#0"])
        #expect(LayoutRules.moved(Self.bar, from: 2, to: 3) == Self.bar)
    }

    // MARK: showing at a slot

    @Test func showNeighboursAreTheTilesEitherSideOfTheDrop() {
        let n = LayoutRules.showNeighbors(at: 4, in: Self.bar)
        #expect(n.left?.id == "com.apple.menuextra.wifi")
        #expect(n.right?.id == "\(Self.b)#0")
        let far = LayoutRules.showNeighbors(at: 0, in: Self.bar)
        #expect(far.left == nil)
        #expect(far.right?.id == "\(Self.own)#0")
    }

    @Test func anAppIsPlacedWhenOnlyItsItemsSitBetweenTheNeighbours() {
        let wifi = Self.bar[3], b = Self.bar[4], own = Self.bar[0]
        #expect(LayoutRules.isPlaced(Self.a, between: own, and: wifi, in: Self.bar))
        #expect(!LayoutRules.isPlaced(Self.a, between: wifi, and: b, in: Self.bar))
        // Another item between them too: not placed.
        #expect(!LayoutRules.isPlaced(Self.a, between: own, and: b, in: Self.bar))
        // Not drawn at all: not placed.
        #expect(!LayoutRules.isPlaced(Self.c, between: own, and: wifi, in: Self.bar))
        #expect(LayoutRules.isPlaced(Self.own, between: nil, and: Self.bar[1], in: Self.bar))
    }

    // MARK: hidden row

    @Test func hidingAnAppInsertsItsWholeGroupAtTheDrop() {
        #expect(LayoutRules.hiddenOrder([Self.b, Self.c], placing: Self.a, at: 1) == [Self.b, Self.a, Self.c])
        #expect(LayoutRules.hiddenOrder([Self.b, Self.c], placing: Self.a, at: 9) == [Self.b, Self.c, Self.a])
        #expect(LayoutRules.hiddenOrder([], placing: Self.a, at: 0) == [Self.a])
    }

    @Test func reorderingTheHiddenRowAccountsForTheRemovedGroup() {
        let order = [Self.a, Self.b, Self.c]
        #expect(LayoutRules.hiddenOrder(order, placing: Self.a, at: 3) == [Self.b, Self.c, Self.a])
        #expect(LayoutRules.hiddenOrder(order, placing: Self.c, at: 0) == [Self.c, Self.a, Self.b])
        #expect(LayoutRules.hiddenOrder(order, placing: Self.b, at: 1) == order)
        #expect(LayoutRules.hiddenOrder(order, placing: Self.b, at: 2) == order)
    }

    @Test func displayCopiesAreListedOnce() {
        let copies = [Self.app(Self.a, x: 10), Self.apple("wifi", x: 40), Self.app(Self.a, x: 1500),
                      Self.apple("wifi", x: 1530)]
        #expect(LayoutRules.deduplicated(copies).map(\.x) == [10, 40])
    }
}
