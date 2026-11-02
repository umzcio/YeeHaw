import Testing
@testable import YeeHawCore

/// Whether a photograph of a drawn item can be stored as that app's icon.
@Suite struct GlyphProofTests {
    static func item(_ id: String, x: Double, width: Double, apple: Bool = false) -> MenuBarItem {
        MenuBarItem(id: apple ? id : "\(id)#0", bundleID: apple ? nil : id, appleIdentifier: apple ? id : nil,
                    indexInApp: 0, label: id, keyNames: [], keyPrefixes: [], x: x, width: width, isPinned: false)
    }

    static let fiddle = item("edu.umontana.fiddle", x: 1591, width: 31)
    static let digup = item("com.abdurrahim.DigUp", x: 1557, width: 36)

    // MARK: Contested frames

    @Test func aFrameTwoAppsReportIsContested() {
        // Before YeeHaw's launch nothing is known to be off: an app switched on a moment ago still
        // reports its old frame, which another app's icon may be drawn at.
        let drawn = [DrawnItem(x: 1557, width: 36, label: "DigUp")]
        let extras = [AppExtra(bundleID: "com.abdurrahim.DigUp", indexInApp: 0, x: 1557, width: 36),
                      AppExtra(bundleID: "edu.umontana.fiddle", indexInApp: 0, x: 1557, width: 36)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.map(\.bundleID) == ["com.abdurrahim.DigUp"])
        #expect(items.map(\.contested) == [true])
    }

    @Test func anAppKnownToBeOffDoesntContestAnAppThatsOn() {
        let drawn = [DrawnItem(x: 1557, width: 36, label: "DigUp")]
        let extras = [AppExtra(bundleID: "edu.umontana.fiddle", indexInApp: 0, x: 1557, width: 36),
                      AppExtra(bundleID: "com.abdurrahim.DigUp", indexInApp: 0, x: 1557, width: 36)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras, offApps: ["edu.umontana.fiddle"])
        #expect(items.map(\.bundleID) == ["com.abdurrahim.DigUp"])
        #expect(items.map(\.contested) == [false])
    }

    // MARK: Photographs

    @Test func anItemAloneInTheSamePlaceBothTimesIsProven() {
        let bar = [Self.digup, Self.fiddle]
        #expect(ItemMatcher.photographable(bar, reread: bar, offApps: []) == [Self.digup.id, Self.fiddle.id])
    }

    @Test func anItemThatMovedOrWentIsNotProven() {
        var moved = Self.fiddle
        moved.x = 1600
        #expect(ItemMatcher.photographable([Self.fiddle], reread: [moved], offApps: []).isEmpty)
        #expect(ItemMatcher.photographable([Self.fiddle], reread: [], offApps: []).isEmpty)
    }

    @Test func anItemOverlappingAnotherIsNotProven() {
        // The owner's Mac on 27.2, right after launch hid Fiddle: MenuBarAgent still listed Fiddle
        // at 1591 (31 wide) with YeeHaw's icon drawn at 1590 (24 wide), and the shot of Fiddle's
        // column was YeeHaw's hat.
        let yeehaw = Self.item("com.zapps.yeehaw", x: 1590, width: 24)
        let bar = [Self.digup, yeehaw, Self.fiddle]
        #expect(ItemMatcher.photographable(bar, reread: bar, offApps: []) == [Self.digup.id])
        // Neighbours' frames reach 2 pt into each other (DigUp's into Fiddle's above); that's no overlap.
        let next = Self.item("com.example.next", x: 1620, width: 20)
        #expect(ItemMatcher.photographable([Self.fiddle, next], reread: [Self.fiddle, next], offApps: [])
            == [Self.fiddle.id, next.id])
    }

    @Test func aContestedItemIsNotProven() {
        var contested = Self.digup
        contested.contested = true
        #expect(ItemMatcher.photographable([contested], reread: [Self.digup], offApps: []).isEmpty)
        #expect(ItemMatcher.photographable([Self.digup], reread: [contested], offApps: []).isEmpty)
    }

    @Test func anAppThatsSwitchedOffIsNotProven() {
        // Its item is still listed for a moment after it's switched off; what's drawn there isn't it.
        #expect(ItemMatcher.photographable([Self.fiddle], reread: [Self.fiddle], offApps: ["edu.umontana.fiddle"]).isEmpty)
    }

    @Test func appleItemsAreProvenTheSameWay() {
        let wifi = Self.item("com.apple.menuextra.wifi", x: 1629, width: 22, apple: true)
        #expect(ItemMatcher.photographable([wifi], reread: [wifi], offApps: []) == [wifi.id])
    }
}
