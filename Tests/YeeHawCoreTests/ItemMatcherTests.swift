import Testing
@testable import YeeHawCore

@Suite struct ItemMatcherTests {
    @Test func matchesByXAndWidth() {
        let drawn = [DrawnItem(x: 1579, width: 36, label: "DigUp"), DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [
            AppExtra(bundleID: "com.example.digup", indexInApp: 0, x: 1579, width: 36),
            AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 1550, width: 31),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.map(\.bundleID) == ["com.example.fiddle", "com.example.digup"])
        #expect(items.map(\.label) == ["Flame", "DigUp"])
        #expect(items.map(\.id) == ["com.example.fiddle#0", "com.example.digup#0"])
    }

    @Test func staleOverlappingFrameIsDropped() {
        let drawn = [DrawnItem(x: 1550, width: 31, label: "Flame")]
        let extras = [
            AppExtra(bundleID: "com.example.fiddle", indexInApp: 0, x: 1550, width: 31),
            AppExtra(bundleID: "com.malwarebytes.mbam", indexInApp: 0, x: 1564, width: 24),
        ]
        let items = ItemMatcher.match(drawn: drawn, extras: extras)
        #expect(items.count == 1)
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
}
