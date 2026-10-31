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

    @Test func malformedThrows() {
        #expect(throws: AllowListError.malformed) {
            try AllowList(data: Data("x".utf8))
        }
    }
}
