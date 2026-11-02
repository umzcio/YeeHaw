import Foundation

public typealias AllowSnapshot = [BundleID: Bool]

public enum AllowListError: Error { case malformed }

/// A copy of an app as an Allow-list entry's `menuItemLocations` lists it. MenuBarAgent applies
/// `isAllowed` only to items of a copy that's listed there: a notarized copy by its bundle ID, any
/// other by its executable's file URL (`RunningCopy.location`).
public enum AllowLocation: Equatable, Sendable {
    case bundle(BundleID)
    /// The executable's file URL, as a string (`file:///…/Contents/MacOS/App`).
    case adhocBinary(String)

    /// MenuBarAgent's form: `{bundle: {_0: id}}` or `{adhocBinary: {_0: {relative: url}}}`.
    public var plist: [String: Any] {
        switch self {
        case .bundle(let id): ["bundle": ["_0": id]]
        case .adhocBinary(let url): ["adhocBinary": ["_0": ["relative": url]]]
        }
    }

    /// Nil for a form YeeHaw doesn't know.
    public init?(plist: Any) {
        let dictionary = plist as? [String: Any]
        if let id = (dictionary?["bundle"] as? [String: Any])?["_0"] as? String {
            self = .bundle(id)
        } else if let url = ((dictionary?["adhocBinary"] as? [String: Any])?["_0"] as? [String: Any])?["relative"] as? String {
            self = .adhocBinary(url)
        } else {
            return nil
        }
    }
}

/// Apple's per-app "Allow in the Menu Bar" list: the `trackedApplications` blob is a binary plist
/// holding a flat array of alternating keys and values. Only `isAllowed` is ever changed, and
/// `menuItemLocations` only appended to; every other field is carried through untouched.
public struct AllowList {
    private var items: [Any]

    public init(data: Data) throws {
        guard let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let array = decoded as? [Any],
              array.count.isMultiple(of: 2)
        else { throw AllowListError.malformed }
        items = array
    }

    public func encoded() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: items, format: .binary, options: 0)
    }

    public var snapshot: AllowSnapshot {
        var result: AllowSnapshot = [:]
        for index in stride(from: 0, to: items.count, by: 2) {
            guard let id = Self.bundleID(of: items[index]),
                  let value = items[index + 1] as? [String: Any],
                  let allowed = value["isAllowed"] as? Bool
            else { continue }
            result[id] = allowed
        }
        return result
    }

    /// Returns false when `id` is not a tracked bundle entry.
    @discardableResult
    public mutating func setAllowed(_ allowed: Bool, for id: BundleID) -> Bool {
        for index in stride(from: 0, to: items.count, by: 2) {
            guard Self.bundleID(of: items[index]) == id,
                  var value = items[index + 1] as? [String: Any],
                  value["isAllowed"] is Bool
            else { continue }
            value["isAllowed"] = allowed
            items[index + 1] = value
            return true
        }
        return false
    }

    /// The copies `id`'s entry lists, in order; forms YeeHaw doesn't know are left out.
    public func locations(for id: BundleID) -> [AllowLocation] {
        guard let index = entryIndex(of: id),
              let listed = (items[index + 1] as? [String: Any])?["menuItemLocations"] as? [Any] else { return [] }
        return listed.compactMap(AllowLocation.init(plist:))
    }

    /// Appends `location` to the entry's `menuItemLocations` (starting the list if it has none),
    /// unless it's listed already. Returns false when nothing changed or `id` isn't tracked.
    @discardableResult
    public mutating func addLocation(_ location: AllowLocation, for id: BundleID) -> Bool {
        guard let index = entryIndex(of: id), var value = items[index + 1] as? [String: Any] else { return false }
        var listed = value["menuItemLocations"] as? [Any] ?? []
        let form = location.plist as NSDictionary
        guard !listed.contains(where: { ($0 as? NSDictionary) == form }) else { return false }
        listed.append(location.plist)
        value["menuItemLocations"] = listed
        items[index + 1] = value
        return true
    }

    private func entryIndex(of id: BundleID) -> Int? {
        stride(from: 0, to: items.count, by: 2).first { Self.bundleID(of: items[$0]) == id }
    }

    private static func bundleID(of key: Any) -> BundleID? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}
