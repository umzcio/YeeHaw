import Testing
@testable import YeeHawCore

@Suite struct ItemMatcherTests {
    @Test func matchesByXAndWidth() {
        let drawn = [DrawnItem(x: 1579, width: 36, label: "DigUp"), DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [
            AppExtra(bundleID: "com.example.digup", indexInApp: 2, x: 1579, width: 36, identifier: "digup-id"),
            AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 1550, width: 31),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.map(\.bundleID) == ["com.example.fiddle", "com.example.digup"])
        #expect(items.map(\.label) == ["Flame", "DigUp"])
        #expect(items.map(\.id) == ["com.example.fiddle#0", "com.example.digup#2"])
        #expect(items[1].keyNames == ["digup-id"])
        #expect(items[1].indexInApp == 2)
    }

    @Test func staleOverlappingFrameIsDropped() {
        let drawn = [DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [
            AppExtra(bundleID: "com.malwarebytes.mbam", indexInApp: 0, x: 1564, width: 24),
            AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 1550, width: 31),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 1)
        #expect(items[0].bundleID == "com.example.fiddle")
        #expect(items.allSatisfy { $0.bundleID != "com.malwarebytes.mbam" })
    }

    @Test func parkedFrameIsDropped() {
        let drawn = [DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [AppExtra(bundleID: "com.google.drivefs", indexInApp: 0, x: -1, width: 34)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.bundleID != "com.google.drivefs" })
    }

    @Test func unlabelledItemsGetOwner() {
        let drawn = [DrawnItem(x: 1795, width: 24, label: "")]
        let extras = [AppExtra(bundleID: "io.tailscale.ipn.macsys", indexInApp: 0, x: 1795, width: 24)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 1)
        #expect(items[0].bundleID == "io.tailscale.ipn.macsys")
        #expect(items[0].label == "")
    }

    @Test func eachDrawnCopyKeepsItsHeight() {
        let extras = [AppExtra(bundleID: "com.example.a", indexInApp: 0, x: 100, width: 20)]
        let third = ItemMatcher.match(drawn: [DrawnItem(x: 100, width: 20, label: "A", y: -900)], extras: extras)
        #expect(third[0].y == -900)
        let apple = ItemMatcher.match(
            drawn: [DrawnItem(x: 100, width: 20, label: "W", appleIdentifier: "com.apple.menuextra.wifi", y: -900)],
            extras: [])
        #expect(apple[0].y == -900)
    }

    @Test func theSameCopyIsTheNearestOnTheSameBar() {
        func copy(x: Double, y: Double) -> MenuBarItem {
            MenuBarItem(id: "com.example.a#0", bundleID: "com.example.a", appleIdentifier: nil, indexInApp: 0,
                        label: "", keyNames: [], keyPrefixes: [], x: x, width: 20, isPinned: false, y: y)
        }
        let read = [copy(x: 60, y: 0), copy(x: 1572, y: 0), copy(x: 62, y: -900)]
        let found = ItemMatcher.sameCopy(of: copy(x: 61, y: 0), in: read)
        #expect(found?.x == 60)
        #expect(found?.y == 0)
        let other = MenuBarItem(id: "com.example.zzz#0", bundleID: "com.example.zzz", appleIdentifier: nil, indexInApp: 0,
                                label: "", keyNames: [], keyPrefixes: [], x: 61, width: 20, isPinned: false)
        #expect(ItemMatcher.sameCopy(of: other, in: read) == nil)
    }

    @Test func appleItemsArePinnedWhenClockOrControlCenter() {
        let drawn = [
            DrawnItem(x: 100, width: 20, label: "Clock", appleIdentifier: "com.apple.menuextra.clock"),
            DrawnItem(x: 200, width: 20, label: "Control Center", appleIdentifier: "com.apple.menuextra.controlcenter"),
            DrawnItem(x: 300, width: 20, label: "Wi-Fi", appleIdentifier: "com.apple.menuextra.wifi"),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: [])
        #expect(items.map(\.isPinned) == [true, true, false])
        #expect(items.allSatisfy { $0.bundleID == nil && $0.keyNames.isEmpty && $0.indexInApp == 0 })
        #expect(items.map(\.id) == ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter", "com.apple.menuextra.wifi"])
    }

    @Test func keyPrefixesAreBundleThenExecutableName() {
        let drawn = [DrawnItem(x: 10, width: 20, label: "zMeet"), DrawnItem(x: 40, width: 20, label: "A"),
                     DrawnItem(x: 70, width: 20, label: "Wi-Fi", appleIdentifier: "com.apple.menuextra.wifi")]
        let extras = [
            AppExtra(bundleID: "edu.umontana.zmeet", indexInApp: 0, x: 10, width: 20, executableName: "zMeet"),
            AppExtra(bundleID: "com.example.a", indexInApp: 0, x: 40, width: 20),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.map(\.keyPrefixes) == [["edu.umontana.zmeet", "zMeet"], ["com.example.a"], []])
    }

    @Test func aCopyThatIsntNotarizedIsKeyedByExecutableNameFirst() {
        let drawn = [DrawnItem(x: 10, width: 20, label: "Fiddle")]
        let extras = [AppExtra(bundleID: "edu.umontana.fiddle", indexInApp: 0, x: 10, width: 20,
                               executableName: "Fiddle", notarized: false)]
        #expect(ItemMatcher.match(drawn: drawn, extras: extras).map(\.keyPrefixes) == [["Fiddle", "edu.umontana.fiddle"]])
    }

    @Test func keyNamesCollectsNonEmptyIdentifierTitleDescription() {
        let drawn = [DrawnItem(x: 10, width: 20, label: "Flame")]
        let extras = [AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 10, width: 20,
                               identifier: "", title: "Flame", description: "Fiddle")]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items[0].keyNames == ["Flame", "Fiddle"])
    }

    @Test func unmatchedDrawnItemKeptWithUnknownOwner() {
        let drawn = [DrawnItem(x: 1234.7, width: 24, label: "Mystery")]
        let items = ItemMatcher.match(drawn: drawn, extras: [])
        #expect(items.count == 1)
        #expect(items[0].bundleID == nil)
        #expect(items[0].appleIdentifier == nil)
        #expect(items[0].id == "unknown@1234")
        #expect(items[0].label == "Mystery")
    }

    @Test func sameXDifferentWidthIsDropped() {
        let drawn = [DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 1550, width: 24)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 1)
        #expect(items[0].bundleID == nil)
        #expect(items[0].id == "unknown@1550")
    }

    @Test func toleranceBoundary() {
        let drawn = [DrawnItem(x: 100, width: 20, label: "A")]
        let near = ItemMatcher.match(drawn: drawn, extras: [AppExtra(bundleID: "a", indexInApp: 0, x: 100.4, width: 20)])
        #expect(near[0].bundleID == "a")
        let far = ItemMatcher.match(drawn: drawn, extras: [AppExtra(bundleID: "a", indexInApp: 0, x: 100.6, width: 20)])
        #expect(far[0].bundleID == nil)
        let farWidth = ItemMatcher.match(drawn: drawn, extras: [AppExtra(bundleID: "a", indexInApp: 0, x: 100, width: 20.6)])
        #expect(farWidth[0].bundleID == nil)
    }

    @Test func eachExtraMatchesOnce() {
        let drawn = [DrawnItem(x: 50, width: 20, label: "A"), DrawnItem(x: 50, width: 20, label: "B")]
        let extras = [AppExtra(bundleID: "a", indexInApp: 0, x: 50, width: 20)]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 2)
        #expect(items.filter { $0.bundleID == "a" }.count == 1)
        #expect(items.filter { $0.id == "unknown@50" }.count == 1)
    }

    @Test func keyNamesOrderIsIdentifierTitleDescription() {
        let drawn = [DrawnItem(x: 10, width: 20, label: "")]
        let extras = [AppExtra(bundleID: "a", indexInApp: 0, x: 10, width: 20,
                               identifier: "Id", title: "Title", description: "Desc")]
        #expect(ItemMatcher.match(drawn: drawn, extras: extras)[0].keyNames == ["Id", "Title", "Desc"])
    }

    @Test func anOffAppsStaleFrameNeverTakesAnAllowedAppsIcon() {
        // R was removed and L slid into exactly R's old frame. R still reports that frame and
        // comes first in the app list, but it's off, so the drawn icon is L's.
        let drawn = [DrawnItem(x: 1500, width: 24, label: "")]
        let extras = [
            AppExtra(bundleID: "r", indexInApp: 0, x: 1500, width: 24),
            AppExtra(bundleID: "l", indexInApp: 0, x: 1500, width: 24),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras, offApps: ["r"])
        #expect(items.map(\.bundleID) == ["l"])
    }

    @Test func anOffAppStillMatchesWhenNothingElseDoes() {
        let drawn = [DrawnItem(x: 1500, width: 24, label: "")]
        let extras = [AppExtra(bundleID: "r", indexInApp: 0, x: 1500, width: 24)]
        #expect(ItemMatcher.match(drawn: drawn, extras: extras, offApps: ["r"]).map(\.bundleID) == ["r"])
    }

    // MARK: Revealed app

    @Test func theRevealedAppComesAfterAppsThatAreOnAndBeforeAppsThatAreOff() {
        // x (revealed) and o (off) both still report 1500, where w (on) is drawn; then 1470 is
        // where both x and o could be: x, the one being revealed, gets it.
        let drawn = [DrawnItem(x: 1470, width: 24, label: ""), DrawnItem(x: 1500, width: 24, label: "")]
        let extras = [
            AppExtra(bundleID: "o", indexInApp: 0, x: 1470, width: 24),
            AppExtra(bundleID: "x", indexInApp: 0, x: 1500, width: 24),
            AppExtra(bundleID: "x", indexInApp: 1, x: 1470, width: 24),
            AppExtra(bundleID: "w", indexInApp: 0, x: 1500, width: 24),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras, offApps: ["o"], revealed: "x")
        #expect(items.map(\.id) == ["x#1", "w#0"])
    }

    // MARK: Own items from a per-app read

    static func item(_ owner: BundleID?, x: Double, width: Double = 24) -> MenuBarItem {
        MenuBarItem(id: owner.map { "\($0)#0" } ?? "unknown@\(Int(x))", bundleID: owner, appleIdentifier: nil,
                    indexInApp: 0, label: "", keyNames: [], keyPrefixes: [], x: x, width: width, isPinned: false)
    }

    @Test func ownItemsAreTrustedWhenTheBarGrewByThem() {
        // Two items were drawn for others; now three, one of them the app's.
        let bar = [Self.item(nil, x: 1440), Self.item("x", x: 1470), Self.item(nil, x: 1500)]
        let lastRead = [Self.item("a", x: 1470), Self.item("w", x: 1500)]
        let result = ItemMatcher.ownItems(in: bar, of: "x", othersDrawn: 2, lastRead: lastRead)
        #expect(result.items.map(\.x) == [1470])
        #expect(!result.inDoubt)
    }

    @Test func aStaleMatchOnAnotherAppsIconIsDropped() {
        // Nothing new is drawn: x's frame is w's icon, as the last full read had it.
        let bar = [Self.item(nil, x: 1470), Self.item("x", x: 1500)]
        let lastRead = [Self.item("a", x: 1470), Self.item("w", x: 1500)]
        let result = ItemMatcher.ownItems(in: bar, of: "x", othersDrawn: 2, lastRead: lastRead)
        #expect(result.items.isEmpty)
        #expect(result.inDoubt)
    }

    @Test func onlyTheMatchesTheBarCantHoldAreDropped() {
        // x has two items: one really drawn at 1440 (the bar grew by one) and one stale on w.
        let bar = [Self.item("x", x: 1440), Self.item(nil, x: 1470), Self.item("x", x: 1500)]
        let lastRead = [Self.item("a", x: 1470), Self.item("w", x: 1500)]
        let result = ItemMatcher.ownItems(in: bar, of: "x", othersDrawn: 2, lastRead: lastRead)
        #expect(result.items.map(\.x) == [1440])
        #expect(result.inDoubt)
    }

    @Test func aBarThatShrankHoldsNoneOfTheApp() {
        let bar = [Self.item("x", x: 1500)]
        let result = ItemMatcher.ownItems(in: bar, of: "x", othersDrawn: 2, lastRead: [])
        #expect(result.items.isEmpty)
        #expect(result.inDoubt)
    }
}
