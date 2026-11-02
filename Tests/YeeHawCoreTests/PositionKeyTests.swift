import Testing
@testable import YeeHawCore

@Suite struct PositionKeyTests {
    static let drivefs = PositionTable([
        "status:com.google.drivefs::Google Drive": 577,
        "status:com.google.drivefs::Item-0": 577,
    ])

    @Test func keysPrefersExistingDuplicates() {
        let keys = PositionKey.keys(prefixes: ["com.google.drivefs"], names: ["Google Drive"], indexInApp: 0, table: Self.drivefs)
        #expect(keys == ["status:com.google.drivefs::Google Drive", "status:com.google.drivefs::Item-0"])
    }

    @Test func keysItemIndexOnly() {
        let keys = PositionKey.keys(prefixes: ["com.google.drivefs"], names: [], indexInApp: 0, table: Self.drivefs)
        #expect(keys == ["status:com.google.drivefs::Item-0"])
    }

    @Test func keysUsesIdentifier() {
        let key = "status:com.malwarebytes.mbam.frontend.agent::statusBar.icon.alert"
        let table = PositionTable([key: 536])
        let keys = PositionKey.keys(prefixes: ["com.malwarebytes.mbam.frontend.agent"],
            names: ["statusBar.icon.alert"], indexInApp: 0, table: table)
        #expect(keys == [key])
    }

    @Test func keysNewWhenMissing() {
        let keys = PositionKey.keys(prefixes: ["com.zapps.yeehaw"], names: [], indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::Item-0"])
    }

    @Test func keysNewUsesFirstName() {
        let keys = PositionKey.keys(prefixes: ["com.zapps.yeehaw"], names: ["YeeHawStatusItem"], indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::YeeHawStatusItem"])
    }

    // Apps that aren't notarized are keyed by executable name (owner's table: status:YeeHaw::YeeHaw).
    @Test func keysResolvesExecutableNamePrefix() {
        let table = PositionTable(["status:YeeHaw::YeeHaw": 10])
        let keys = PositionKey.keys(prefixes: ["com.zapps.yeehaw", "YeeHaw"], names: ["YeeHaw"], indexInApp: 0, table: table)
        #expect(keys == ["status:YeeHaw::YeeHaw"])
    }

    @Test func keysReturnsEveryPrefixBundleFirst() {
        let table = PositionTable([
            "status:zMeet::zMeetStatusItem": 40,
            "status:edu.umontana.zmeet::zMeetStatusItem": 40,
            "status:zMeet::Item-0": 40,
        ])
        let keys = PositionKey.keys(
            prefixes: ["edu.umontana.zmeet", "zMeet"], names: ["zMeetStatusItem"], indexInApp: 0, table: table)
        #expect(keys == [
            "status:edu.umontana.zmeet::zMeetStatusItem", "status:zMeet::zMeetStatusItem", "status:zMeet::Item-0",
        ])
    }

    @Test func keysNewUsesFirstPrefix() {
        let keys = PositionKey.keys(prefixes: ["com.zapps.yeehaw", "YeeHaw"], names: ["YeeHaw"], indexInApp: 0, table: PositionTable([:]))
        #expect(keys == ["status:com.zapps.yeehaw::YeeHaw"])
    }

    @Test func prefixesAreBundleThenExecutableDeduped() {
        #expect(PositionKey.prefixes(bundleID: "edu.umontana.zmeet", executableName: "zMeet") == ["edu.umontana.zmeet", "zMeet"])
        #expect(PositionKey.prefixes(bundleID: "Nora", executableName: "Nora") == ["Nora"])
        #expect(PositionKey.prefixes(bundleID: "com.example.a", executableName: nil) == ["com.example.a"])
        #expect(PositionKey.prefixes(bundleID: "com.example.a", executableName: "") == ["com.example.a"])
    }

    @Test func aCopyThatIsntNotarizedPutsItsExecutableNameFirst() {
        // MenuBarAgent files such a copy's items under the executable name, so a new key goes there.
        #expect(PositionKey.prefixes(bundleID: "edu.umontana.fiddle", executableName: "Fiddle", notarized: false)
            == ["Fiddle", "edu.umontana.fiddle"])
        #expect(PositionKey.prefixes(bundleID: "edu.umontana.fiddle", executableName: "Fiddle", notarized: true)
            == ["edu.umontana.fiddle", "Fiddle"])
        #expect(PositionKey.prefixes(bundleID: "Nora", executableName: "Nora", notarized: false) == ["Nora"])
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

    @Test func existingKeysAreEveryKeyUnderAnyPrefixSorted() {
        let table = PositionTable([
            "status:com.example.a::Item-1": 3, "status:com.example.a::Item-0": 2,
            "status:A::Item-0": 1, "status:com.example.ab::Item-0": 9, "module:Clock": 0,
        ])
        let keys = PositionKey.existingKeys(prefixes: ["com.example.a", "A"], table: table)
        #expect(keys == ["status:A::Item-0", "status:com.example.a::Item-0", "status:com.example.a::Item-1"])
        #expect(PositionKey.existingKeys(prefixes: [], table: table).isEmpty)
    }
}
