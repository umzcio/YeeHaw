import Testing
@testable import YeeHawCore

@Suite struct PositionKeyTests {
    @Test func keysPrefersExistingDuplicates() {
        let table = PositionTable([
            "status:com.google.drivefs::Google Drive": 577,
            "status:com.google.drivefs::Item-0": 577,
        ])
        let keys = PositionKey.keys(bundleID: "com.google.drivefs", axIdentifier: "", indexInApp: 0, table: table)
        #expect(keys == ["status:com.google.drivefs::Item-0"])
    }

    @Test func keysUsesIdentifier() {
        let key = "status:com.malwarebytes.mbam.frontend.agent::statusBar.icon.alert"
        let table = PositionTable([key: 536])
        let keys = PositionKey.keys(
            bundleID: "com.malwarebytes.mbam.frontend.agent",
            axIdentifier: "statusBar.icon.alert", indexInApp: 0, table: table)
        #expect(keys == [key])
    }

    @Test func keysNewWhenMissing() {
        let keys = PositionKey.keys(bundleID: "com.zapps.yeehaw", axIdentifier: "", indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::Item-0"])
    }

    @Test func keysNewUsesIdentifierWhenPresent() {
        let keys = PositionKey.keys(bundleID: "a.b", axIdentifier: "id", indexInApp: 2, table: PositionTable([:]))
        #expect(keys == ["status:a.b::id"])
    }

    @Test func constants() {
        #expect(PositionKey.clock == "module:Clock")
        #expect(PositionKey.controlCenter == "module:BentoBox-0")
    }
}
