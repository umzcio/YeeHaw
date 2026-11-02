import Testing
@testable import YeeHawCore

@Suite struct LayoutDraftTests {
    static func item(_ id: String, owned: Bool = true, pinned: Bool = false) -> MenuBarItem {
        MenuBarItem(id: "\(id)#0", bundleID: owned && !pinned ? id : nil, appleIdentifier: pinned ? id : nil,
                    indexInApp: 0, label: id, keyNames: [], keyPrefixes: owned ? [id] : [],
                    x: 0, width: 20, isPinned: pinned)
    }

    /// A tile for a hidden app being shown: it isn't drawn, so it has no frame or keys yet.
    static func placeholder(_ id: BundleID, index: Int = 0) -> MenuBarItem {
        MenuBarItem(id: "\(id)#\(index)", bundleID: id, appleIdentifier: nil, indexInApp: index, label: id,
                    keyNames: [], keyPrefixes: [], x: 0, width: 0, isPinned: false)
    }

    static let a = item("A"), b = item("B"), c = item("C"), d = item("D")
    static let clock = item("clock", pinned: true)

    static func draft(_ bar: [MenuBarItem] = [a, b, c, d], hidden: [BundleID] = []) -> LayoutDraft {
        LayoutDraft(bar: bar, hidden: hidden)
    }

    // MARK: Moves

    @Test func aMoveIsPlacedBetweenItsNewNeighbours() {
        var draft = Self.draft()
        draft.move(from: 0, to: 3)
        #expect(draft.bar == [Self.b, Self.c, Self.a, Self.d])
        #expect(draft.isDirty)
        let changes = draft.changes()
        #expect(changes.moves == [.init(item: Self.a, left: Self.c, right: Self.d)])
        #expect(changes.shows.isEmpty && changes.hides.isEmpty && changes.hiddenOrder == nil)
    }

    @Test func movingAnIconBackLeavesTheDraftClean() {
        var draft = Self.draft()
        draft.move(from: 0, to: 3)
        draft.move(from: 2, to: 0)
        #expect(!draft.isDirty)
        #expect(draft.changes().isEmpty)
    }

    @Test func iconsMovedNextToEachOtherArePlacedLeftToRight() {
        var draft = Self.draft()
        draft.move(from: 2, to: 0)
        draft.move(from: 3, to: 1)
        #expect(draft.bar == [Self.c, Self.d, Self.a, Self.b])
        // C first, before A; then D between C (placed by then) and A.
        #expect(draft.changes().moves == [.init(item: Self.c, left: nil, right: Self.a),
                                          .init(item: Self.d, left: Self.c, right: Self.a)])
    }

    @Test func anIconMovedAndThenPassedByAnotherNeedsNoMoveOfItsOwn() {
        var draft = Self.draft()
        draft.move(from: 0, to: 2)   // B A C D
        draft.move(from: 0, to: 4)   // A C D B: A is back in order, only B moved
        #expect(draft.changes().moves == [.init(item: Self.b, left: Self.d, right: nil)])
    }

    @Test func onlyAnchorsCanBeNeighbours() {
        let unknown = Self.item("unknown", owned: false)
        var draft = Self.draft([unknown, Self.a, Self.b, Self.clock])
        draft.move(from: 2, to: 0)
        #expect(draft.changes().moves == [.init(item: Self.b, left: nil, right: Self.a)])
        // An anchor the caller rules out (no saved position) is skipped too.
        #expect(draft.changes(anchors: { LayoutRules.isOwned($0) && $0 != Self.a }).moves == [.init(item: Self.b, left: nil, right: Self.clock)])
    }

    @Test func anIconsNeighboursAreWhereverTheUserPutIt() {
        let unknown = Self.item("unknown", owned: false)
        var draft = Self.draft([Self.a, unknown, Self.b, Self.c], hidden: ["H"])
        draft.move(from: 3, to: 2)                                    // A U C B
        draft.show("H", placeholders: [Self.placeholder("H")], at: 3)  // A U C H B
        // Placed between the anchors A and B, but it belongs right of U and left of B.
        #expect(draft.changes().moves == [.init(item: Self.c, left: Self.a, right: Self.b)])
        let neighbours = draft.neighbours(of: Self.c)
        #expect(neighbours.left == unknown && neighbours.right == Self.b)
    }

    // MARK: Hiding and showing

    @Test func aHideTakesTheAppOutOfTheBar() {
        var draft = Self.draft(hidden: ["H"])
        draft.hide("B", at: 0)
        #expect(draft.bar == [Self.a, Self.c, Self.d])
        #expect(draft.hidden == ["B", "H"])
        let changes = draft.changes()
        #expect(changes.hides == ["B"])
        // Hiding appends; the draft put B first.
        #expect(changes.hiddenOrder == ["B", "H"])
        #expect(changes.moves.isEmpty)
    }

    @Test func hidingAndShowingTheSameAppLeavesTheDraftClean() {
        var draft = Self.draft()
        draft.hide("B", at: 0)
        draft.show("B", placeholders: [Self.placeholder("B")], at: 1)
        #expect(draft.bar == [Self.a, Self.b, Self.c, Self.d])
        #expect(!draft.isDirty)
        #expect(draft.changes().isEmpty)
    }

    @Test func showingAHiddenAppPlacesItWhereItWasDropped() {
        var draft = Self.draft(hidden: ["H", "J"])
        draft.show("H", placeholders: [Self.placeholder("H"), Self.placeholder("H", index: 1)], at: 1)
        #expect(draft.bar.map(\.id) == ["A#0", "H#0", "H#1", "B#0", "C#0", "D#0"])
        #expect(draft.hidden == ["J"])
        let changes = draft.changes()
        #expect(changes.shows == [.init(id: "H", left: Self.a, right: Self.b)])
        #expect(changes.hiddenOrder == nil)
        // Hidden again, in its old place: nothing to do.
        draft.hide("H", at: 0)
        #expect(!draft.isDirty)
    }

    @Test func iconsMovedNextToAShownAppSkipItAsANeighbour() {
        var draft = Self.draft(hidden: ["H"])
        draft.show("H", placeholders: [Self.placeholder("H")], at: 0)
        draft.move(from: 3, to: 1)   // H C A B D
        let changes = draft.changes()
        #expect(changes.shows == [.init(id: "H", left: nil, right: Self.c)])
        // H isn't drawn when the moves are written, so it can't anchor one.
        #expect(changes.moves == [.init(item: Self.c, left: nil, right: Self.a)])
    }

    @Test func editsCombine() {
        var draft = Self.draft([Self.a, Self.b, Self.c, Self.d, Self.clock], hidden: ["H", "J"])
        draft.hide("C", at: 2)
        draft.move(from: 2, to: 0)                                     // D A B clock
        draft.show("H", placeholders: [Self.placeholder("H")], at: 3)   // D A B H clock
        draft.reorderHidden("J", at: 0)
        let changes = draft.changes()
        #expect(changes.shows == [.init(id: "H", left: Self.b, right: Self.clock)])
        #expect(changes.hides == ["C"])
        #expect(changes.moves == [.init(item: Self.d, left: nil, right: Self.a)])
        #expect(draft.hidden == ["J", "C"])
        #expect(changes.hiddenOrder == nil)
        draft.reorderHidden("C", at: 0)
        #expect(draft.changes().hiddenOrder == ["C", "J"])
    }

    @Test func revertPutsEverythingBack() {
        var draft = Self.draft(hidden: ["H"])
        draft.hide("A", at: 1)
        draft.show("H", placeholders: [Self.placeholder("H")], at: 0)
        draft.move(from: 1, to: 3)
        draft.revert()
        #expect(draft == Self.draft(hidden: ["H"]))
    }

    // MARK: The bar changing underneath

    @Test func reconcilingDropsAVanishedIconAndKeepsTheOtherEdits() {
        var draft = Self.draft(hidden: ["H"])
        draft.move(from: 0, to: 4)   // B C D A
        draft.hide("B", at: 1)       // C D A; hidden H B
        let e = Self.item("E")
        // C quit; E launched between D and A's old place.
        draft.reconcile(bar: [Self.a, Self.b, Self.d, e], hidden: ["H"])
        #expect(draft.bar == [Self.d, e, Self.a])
        #expect(draft.hidden == ["H", "B"])
        let changes = draft.changes()
        #expect(changes.hides == ["B"])
        #expect(changes.moves == [.init(item: Self.a, left: e, right: nil)])
    }

    @Test func reconcilingFollowsTheBarsLatestFrames() {
        var draft = Self.draft()
        draft.move(from: 0, to: 2)
        var moved = Self.a
        moved.x = 300
        draft.reconcile(bar: [moved, Self.b, Self.c, Self.d], hidden: [])
        #expect(draft.bar.map(\.x) == [0, 300, 0, 0])
    }

    @Test func reconcilingDropsAShowOfAnAppNoLongerHidden() {
        var draft = Self.draft(hidden: ["H", "J"])
        draft.show("H", placeholders: [Self.placeholder("H")], at: 0)
        // H was switched on in System Settings, and isn't drawn (not running).
        draft.reconcile(bar: [Self.a, Self.b, Self.c, Self.d], hidden: ["J"])
        #expect(draft.bar == [Self.a, Self.b, Self.c, Self.d])
        #expect(!draft.isDirty)
    }

    @Test func reconcilingKeepsAHiddenAppTheUserStillHasHidden() {
        var draft = Self.draft(hidden: ["H"])
        draft.move(from: 0, to: 2)
        // Another app was hidden meanwhile (by the strip): it joins the Hidden row.
        draft.reconcile(bar: [Self.a, Self.b, Self.c, Self.d], hidden: ["H", "K"])
        #expect(draft.hidden == ["H", "K"])
        #expect(draft.changes().hides.isEmpty)
    }

    // MARK: Summary

    @Test func theSummaryNamesTheChangesWhileTheyFit() {
        #expect(LayoutDraft.summary(["Hide Fiddle", "Move zWhisper"], maxLength: 40) == "Hide Fiddle, move zWhisper")
        #expect(LayoutDraft.summary(["Show DigUp"], maxLength: 40) == "Show DigUp")
        #expect(LayoutDraft.summary(["Hide Fiddle", "Move zWhisper", "Show Google Drive"], maxLength: 40) == "3 changes")
        #expect(LayoutDraft.summary(["Move A very long app name indeed"], maxLength: 10) == "1 change")
        #expect(LayoutDraft.summary([], maxLength: 40) == "")
    }

    @Test func phrasesFollowApplysOrderAndNameEachAppOnce() {
        var draft = Self.draft([Self.a, Self.item("A2"), Self.b], hidden: ["H", "J"])
        draft.move(from: 0, to: 3)
        draft.hide("B", at: 0)
        draft.show("H", placeholders: [Self.placeholder("H")], at: 0)
        let phrases = draft.changes().phrases(itemName: { $0.label }, appName: { "app \($0)" })
        #expect(phrases == ["Show app H", "Hide app B", "Move A", "Reorder Hidden"])
    }
}
