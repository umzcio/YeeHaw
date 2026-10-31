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
        #expect(items[1].axIdentifier == "digup-id")
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
}
