import Testing
@testable import YeeHawCore

@Suite struct PositionTableTests {
    static let digUp = "status:com.abdurrahim.DigUp::Item-0"
    static let fiddle = "status:edu.umontana.fiddle::Item-0"
    static let chrome = "status:com.google.Chrome::Item-0"

    static let real = PositionTable([
        digUp: 375.5,
        fiddle: 409.5,
        chrome: 248,
        "status:com.google.drivefs::Google Drive": 577,
        "status:com.google.drivefs::Item-0": 577,
        "status:com.malwarebytes.mbam.frontend.agent::statusBar.icon.alert": 536,
        "module:Clock": 0,
        "module:BentoBox-0": 125.5,
    ])

    @Test func placesBetweenNeighbors() {
        let result = Self.real.placement(of: [Self.digUp], leftNeighbor: Self.fiddle, rightNeighbor: Self.chrome)
        #expect(result == [Self.digUp: 328.75])
        #expect(result[Self.fiddle] == nil)
    }

    @Test func farLeftUsesMaxPlus20() {
        let result = Self.real.placement(of: [Self.digUp], leftNeighbor: nil, rightNeighbor: "status:com.google.drivefs::Item-0")
        // L = max (577) + 20 = 597; R = 577; midpoint 587.
        #expect(result == [Self.digUp: 587])
    }

    @Test func nilRightNeighborSitsLeftOfClock() {
        let table = PositionTable([PositionKey.clock: 0, "a": 50, "b": 80])
        #expect(table.placement(of: ["c"], leftNeighbor: "a", rightNeighbor: nil) == ["c": 25])
    }

    @Test func tightGapCascades() {
        let table = PositionTable(["right": 10.0, "left": 10.5, "other": 11.2, "moved": 40])
        let result = table.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["moved": 11.0, "left": 12.0, "other": 13.0])
    }

    @Test func cascadeStopsAtFirstRoomyEntry() {
        let table = PositionTable(["right": 10.0, "left": 10.5, "far": 30, "moved": 40])
        let result = table.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["moved": 11.0, "left": 12.0])
    }

    @Test func movedKeysAreExcludedFromLookups() {
        // The second moved key sits between the neighbors; it must not take part in the cascade.
        let table = PositionTable(["right": 10.0, "left": 10.5, "m1": 10.7, "m2": 10.8])
        let result = table.placement(of: ["m1", "m2"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["m1": 11.0, "m2": 11.0, "left": 12.0])
    }

    @Test func preservesForeignAndStaleKeys() {
        let result = Self.real.placement(of: [Self.digUp], leftNeighbor: Self.fiddle, rightNeighbor: Self.chrome)
        #expect(Set(result.keys) == [Self.digUp])
        let tight = PositionTable(["right": 10.0, "left": 10.5, "stale:x::Item-9": 900, "moved": 40])
        let tightResult = tight.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(tightResult["stale:x::Item-9"] == nil)
    }

    @Test func slotLeftOfYeeHaw() {
        let table = PositionTable(["yeehaw": 130, "next": 144, "lower": 100])
        #expect(table.slotValue(leftOf: "yeehaw") == 137)
        #expect(PositionTable(["yeehaw": 130, "lower": 100]).slotValue(leftOf: "yeehaw") == 150)
    }

    @Test func slotForAbsentKeyTreatsValueAsZero() {
        let table = PositionTable([PositionKey.clock: 0, "a": 10])
        #expect(table.slotValue(leftOf: "missing") == 5)
    }
}
