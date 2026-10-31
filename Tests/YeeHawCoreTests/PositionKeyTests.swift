import Testing
@testable import YeeHawCore

@Suite struct PositionKeyTests {
    static let drivefs = PositionTable([
        "status:com.google.drivefs::Google Drive": 577,
        "status:com.google.drivefs::Item-0": 577,
    ])

    @Test func keysPrefersExistingDuplicates() {
        let keys = PositionKey.keys(bundleID: "com.google.drivefs", names: ["Google Drive"], indexInApp: 0, table: Self.drivefs)
        #expect(keys == ["status:com.google.drivefs::Google Drive", "status:com.google.drivefs::Item-0"])
    }

    @Test func keysItemIndexOnly() {
        let keys = PositionKey.keys(bundleID: "com.google.drivefs", names: [], indexInApp: 0, table: Self.drivefs)
        #expect(keys == ["status:com.google.drivefs::Item-0"])
    }

    @Test func keysUsesIdentifier() {
        let key = "status:com.malwarebytes.mbam.frontend.agent::statusBar.icon.alert"
        let table = PositionTable([key: 536])
        let keys = PositionKey.keys(
            bundleID: "com.malwarebytes.mbam.frontend.agent",
            names: ["statusBar.icon.alert"], indexInApp: 0, table: table)
        #expect(keys == [key])
    }

    @Test func keysNewWhenMissing() {
        let keys = PositionKey.keys(bundleID: "com.zapps.yeehaw", names: [], indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::Item-0"])
    }

    @Test func keysNewUsesFirstName() {
        let keys = PositionKey.keys(bundleID: "com.zapps.yeehaw", names: ["YeeHawStatusItem"], indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::YeeHawStatusItem"])
    }

    @Test func constants() {
        #expect(PositionKey.clock == "module:Clock")
        #expect(PositionKey.controlCenter == "module:BentoBox-0")
    }

    @Test func appleKeyPinnedItems() {
        let table = PositionTable([:])
        #expect(PositionKey.appleKey(appleIdentifier: "com.apple.menuextra.controlcenter", table: table) == "module:BentoBox-0")
        #expect(PositionKey.appleKey(appleIdentifier: "com.apple.menuextra.clock", table: table) == "module:Clock")
    }

    @Test func appleKeyMatchesModuleCaseInsensitively() {
        let table = PositionTable(["module:WiFi": 50, "module:Battery": 30, "status:com.x::wifi": 9])
        #expect(PositionKey.appleKey(appleIdentifier: "com.apple.menuextra.wifi", table: table) == "module:WiFi")
        #expect(PositionKey.appleKey(appleIdentifier: "com.apple.menuextra.battery", table: table) == "module:Battery")
    }

    @Test func appleKeyUnknownIsNil() {
        let table = PositionTable(["module:WiFi": 50])
        #expect(PositionKey.appleKey(appleIdentifier: "com.apple.menuextra.sound", table: table) == nil)
        #expect(PositionKey.appleKey(appleIdentifier: "com.other.thing", table: table) == nil)
    }
}
