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

    @Test func placesBetweenNeighbors() throws {
        let result = try Self.real.placement(of: [Self.digUp], leftNeighbor: Self.fiddle, rightNeighbor: Self.chrome)
        #expect(result == [Self.digUp: 328.75])
        #expect(result[Self.fiddle] == nil)
    }

    @Test func farLeftUsesMidpointWithMaxPlus20() throws {
        let result = try Self.real.placement(of: [Self.digUp], leftNeighbor: nil, rightNeighbor: "status:com.google.drivefs::Item-0")
        // L = max (577) + 20 = 597; R = 577; midpoint 587.
        #expect(result == [Self.digUp: 587])
    }

    @Test func nilRightNeighborSitsLeftOfClock() throws {
        let table = PositionTable([PositionKey.clock: 0, "a": 50, "b": 80])
        #expect(try table.placement(of: ["c"], leftNeighbor: "a", rightNeighbor: nil) == ["c": 25])
    }

    @Test func tightGapCascades() throws {
        let table = PositionTable(["right": 10.0, "left": 10.5, "other": 11.2, "moved": 40])
        let result = try table.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["moved": 11.0, "left": 12.0, "other": 13.0])
    }

    @Test func cascadeStopsAtFirstRoomyEntry() throws {
        let table = PositionTable(["right": 10.0, "left": 10.5, "far": 30, "moved": 40])
        let result = try table.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["moved": 11.0, "left": 12.0])
    }

    @Test func movedKeysAreExcludedFromLookups() throws {
        // The second moved key sits between the neighbors; it must not take part in the cascade.
        let table = PositionTable(["right": 10.0, "left": 10.5, "m1": 10.7, "m2": 10.8])
        let result = try table.placement(of: ["m1", "m2"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["m1": 11.0, "m2": 11.0, "left": 12.0])
    }

    @Test func cascadeKeepsTiedKeysTogether() throws {
        let left = "status:com.google.drivefs::Item-0"
        let sibling = "status:com.google.drivefs::Google Drive"
        let table = PositionTable(["right": 10.0, left: 10.5, sibling: 10.5, "moved": 40])
        let result = try table.placement(of: ["moved"], leftNeighbor: left, rightNeighbor: "right")
        #expect(result == ["moved": 11.0, left: 12.0, sibling: 12.0])
    }

    @Test func duplicateMovedKeysDoNotCrash() throws {
        let result = try Self.real.placement(of: [Self.digUp, Self.digUp], leftNeighbor: Self.fiddle, rightNeighbor: Self.chrome)
        #expect(result == [Self.digUp: 328.75])
    }

    @Test func preservesForeignAndStaleKeys() throws {
        let result = try Self.real.placement(of: [Self.digUp], leftNeighbor: Self.fiddle, rightNeighbor: Self.chrome)
        #expect(Set(result.keys) == [Self.digUp])
        let tight = PositionTable(["right": 10.0, "left": 10.5, "stale:x::Item-9": 900, "moved": 40])
        let tightResult = try tight.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(tightResult["stale:x::Item-9"] == nil)
    }

    @Test func neverLandsOnAnotherKey() throws {
        let table = PositionTable(["left": 400, "hidden": 300, "right": 200, "moved": 50])
        // The old midpoint, 300, was the hidden key's value.
        #expect(try table.placement(of: ["moved"], leftNeighbor: "left", rightNeighbor: "right") == ["moved": 350])
    }

    @Test func aTightCascadeNeverCollides() throws {
        let table = PositionTable(["right": 10, "h": 11, "left": 11.5, "m": 40])
        let result = try table.placement(of: ["m"], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["m": 11, "h": 12, "left": 13])
    }

    @Test func aLeftNeighbourRightOfTheRightOneThrows() throws {
        let table = PositionTable(["left": 100, "right": 200])
        #expect(throws: ControllerError.unresolvedNeighbor) {
            try table.placement(of: ["m"], leftNeighbor: "left", rightNeighbor: "right")
        }
        let tie = PositionTable(["left": 100, "right": 100])
        #expect(throws: ControllerError.unresolvedNeighbor) {
            try tie.placement(of: ["m"], leftNeighbor: "left", rightNeighbor: "right")
        }
    }

    @Test func aMissingClockCountsAsZero() throws {
        let table = PositionTable(["a": 50])
        #expect(try table.placement(of: ["m"], leftNeighbor: "a", rightNeighbor: PositionKey.clock) == ["m": 25])
        // Nothing can sit right of the clock; this used to land left of "a", the opposite end of the bar.
        #expect(throws: ControllerError.unresolvedNeighbor) {
            try table.placement(of: ["m"], leftNeighbor: PositionKey.clock, rightNeighbor: nil)
        }
    }

    @Test func iconsGetDistinctValuesInOrder() throws {
        let table = PositionTable(["left": 400, "right": 100])
        let result = try table.placement(ofGroups: [["x0"], ["x1a", "x1b"]], leftNeighbor: "left", rightNeighbor: "right")
        #expect(result == ["x0": 300, "x1a": 200, "x1b": 200])
    }

    @Test func groupingByValueSeparatesIconsAndKeepsAliases() {
        let table = PositionTable(["a::Item-0": 500, "a::Name": 500, "a::Item-1": 490])
        #expect(table.groupedByValue(["a::Item-1", "a::Name", "a::Item-0", "a::New"])
                == [["a::Item-0", "a::Name"], ["a::Item-1"], ["a::New"]])
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
