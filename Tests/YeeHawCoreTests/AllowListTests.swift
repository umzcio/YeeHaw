import Foundation
import Testing
@testable import YeeHawCore

@Suite struct AllowListTests {
    static func bundleKey(_ id: String) -> [String: Any] {
        ["bundle": ["_0": id]]
    }

    static func bundleValue(_ id: String, allowed: Bool) -> [String: Any] {
        [
            "location": ["bundle": ["_0": id]],
            "menuItemLocations": [["bundle": ["_0": id]]],
            "isAllowed": allowed,
        ]
    }

    static func adhocKey() -> [String: Any] {
        [
        "adhocBinary": ["_0": ["relative": "file:///path/to/App.app/Contents/MacOS/App"]]
        ]
    }

    static func blob(includeAdhoc: Bool = false) throws -> Data {
        var items: [Any] = [
            bundleKey("com.google.drivefs"), bundleValue("com.google.drivefs", allowed: false),
            bundleKey("com.abdurrahim.DigUp"), bundleValue("com.abdurrahim.DigUp", allowed: true),
        ]
        if includeAdhoc {
            items += [adhocKey(), bundleValue("com.adhoc.App", allowed: true)]
        }
        return try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> NSArray {
        try #require(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSArray)
    }

    @Test func snapshotReadsBundleKeys() throws {
        let list = try AllowList(data: Self.blob())
        #expect(list.snapshot == ["com.google.drivefs": false, "com.abdurrahim.DigUp": true])
    }

    @Test func adhocBinaryKeysAreSkippedButPreserved() throws {
        let data = try Self.blob(includeAdhoc: true)
        let list = try AllowList(data: data)
        #expect(list.snapshot.count == 2)
        let reencoded = try list.encoded()
        // Binary plist key order isn't stable across producers, so compare decoded content.
        #expect(try Self.decode(reencoded) == Self.decode(data))
    }

    @Test func setAllowedFlipsOnlyThatEntry() throws {
        var list = try AllowList(data: Self.blob())
        let flipped = list.setAllowed(false, for: "com.abdurrahim.DigUp")
        #expect(flipped)
        let again = try AllowList(data: list.encoded())
        #expect(again.snapshot == ["com.google.drivefs": false, "com.abdurrahim.DigUp": false])
        let items = try #require(
            PropertyListSerialization.propertyList(from: list.encoded(), options: [], format: nil) as? [Any])
        let value = try #require(items[3] as? [String: Any])
        #expect(value["location"] != nil)
        #expect(value["menuItemLocations"] != nil)
    }

    @Test func setAllowedOnUntrackedReturnsFalse() throws {
        let data = try Self.blob()
        var list = try AllowList(data: data)
        let flipped = list.setAllowed(true, for: "com.nope")
        #expect(flipped == false)
        #expect(try Self.decode(list.encoded()) == Self.decode(data))
    }

    // MARK: Locations

    static let fiddle = "edu.umontana.fiddle"
    static let debugFiddle = URL(fileURLWithPath: "/Users/me/fiddle/Debug/Fiddle.app/Contents/MacOS/Fiddle")

    /// The owner's Fiddle entry: listed only under a debug build's executable.
    static func fiddleBlob(locations: [[String: Any]]?) throws -> Data {
        var value: [String: Any] = ["location": ["bundle": ["_0": fiddle]], "isAllowed": false, "extra": 7]
        if let locations { value["menuItemLocations"] = locations }
        return try PropertyListSerialization.data(fromPropertyList: [bundleKey(fiddle), value], format: .binary, options: 0)
    }

    static func value(_ list: AllowList) throws -> [String: Any] {
        let items = try #require(PropertyListSerialization.propertyList(from: list.encoded(), options: [], format: nil) as? [Any])
        return try #require(items[1] as? [String: Any])
    }

    @Test func aNotarizedCopyIsListedByBundleAndAnyOtherByItsExecutable() {
        #expect(RunningCopy(bundleID: Self.fiddle, executableURL: Self.debugFiddle, notarized: true).location
            == .bundle(Self.fiddle))
        #expect(RunningCopy(bundleID: Self.fiddle, executableURL: Self.debugFiddle, notarized: false).location
            == .adhocBinary("file:///Users/me/fiddle/Debug/Fiddle.app/Contents/MacOS/Fiddle"))
    }

    @Test func locationsUseMenuBarAgentsForms() throws {
        let bundle = AllowLocation.bundle(Self.fiddle).plist as NSDictionary
        #expect(bundle == ["bundle": ["_0": Self.fiddle]] as NSDictionary)
        let adhoc = AllowLocation.adhocBinary("file:///x/Fiddle").plist as NSDictionary
        #expect(adhoc == ["adhocBinary": ["_0": ["relative": "file:///x/Fiddle"]]] as NSDictionary)
        #expect(AllowLocation(plist: bundle) == .bundle(Self.fiddle))
        #expect(AllowLocation(plist: adhoc) == .adhocBinary("file:///x/Fiddle"))
        #expect(AllowLocation(plist: ["somethingElse": 1]) == nil)
    }

    @Test func addLocationAppendsTheRunningCopyAndKeepsTheRest() throws {
        let debug = AllowLocation.adhocBinary(Self.debugFiddle.absoluteString)
        var list = try AllowList(data: Self.fiddleBlob(locations: [debug.plist]))
        let added = list.addLocation(.bundle(Self.fiddle), for: Self.fiddle)
        #expect(added)
        #expect(list.locations(for: Self.fiddle) == [debug, .bundle(Self.fiddle)])
        let value = try Self.value(list)
        #expect(value["isAllowed"] as? Bool == false)
        #expect(value["extra"] as? Int == 7)
        #expect((value["location"] as? NSDictionary) == ["bundle": ["_0": Self.fiddle]] as NSDictionary)
    }

    @Test func addLocationNeverDuplicates() throws {
        var list = try AllowList(data: Self.fiddleBlob(locations: [AllowLocation.bundle(Self.fiddle).plist]))
        let before = try list.encoded()
        let added = list.addLocation(.bundle(Self.fiddle), for: Self.fiddle)
        #expect(!added)
        #expect(try Self.decode(list.encoded()) == Self.decode(before))
    }

    @Test func addLocationStartsTheListWhenTheEntryHasNone() throws {
        var list = try AllowList(data: Self.fiddleBlob(locations: nil))
        let added = list.addLocation(.bundle(Self.fiddle), for: Self.fiddle)
        #expect(added)
        #expect(list.locations(for: Self.fiddle) == [.bundle(Self.fiddle)])
    }

    @Test func addLocationOnUntrackedChangesNothing() throws {
        let data = try Self.blob()
        var list = try AllowList(data: data)
        let added = list.addLocation(.bundle("com.nope"), for: "com.nope")
        #expect(!added)
        #expect(try Self.decode(list.encoded()) == Self.decode(data))
    }

    @Test func malformedThrows() {
        #expect(throws: AllowListError.malformed) {
            try AllowList(data: Data("x".utf8))
        }
    }
}
