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

    /// An app listed more than once counts as allowed only when every entry says so: which entry MenuBarAgent honours isn't known, so YeeHaw never takes an app for shown while one entry hides it.
    public var snapshot: AllowSnapshot {
        var result: AllowSnapshot = [:]
        for index in stride(from: 0, to: items.count, by: 2) {
            guard let id = Self.bundleID(of: items[index]),
                  let value = items[index + 1] as? [String: Any],
                  let allowed = value["isAllowed"] as? Bool
            else { continue }
            result[id] = (result[id] ?? true) && allowed
        }
        return result
    }

    /// Sets every entry of `id`. Returns true when an entry changed; false when all already said
    /// so or `id` isn't tracked.
    @discardableResult
    public mutating func setAllowed(_ allowed: Bool, for id: BundleID) -> Bool {
        var changed = false
        for index in entryIndices(of: id) {
            guard var value = items[index + 1] as? [String: Any], let current = value["isAllowed"] as? Bool,
                  current != allowed else { continue }
            value["isAllowed"] = allowed
            items[index + 1] = value
            changed = true
        }
        return changed
    }

    /// The copies every entry of `id` lists, in order and without repeats; forms YeeHaw doesn't
    /// know are left out.
    public func locations(for id: BundleID) -> [AllowLocation] {
        var result: [AllowLocation] = []
        for index in entryIndices(of: id) {
            guard let listed = (items[index + 1] as? [String: Any])?["menuItemLocations"] as? [Any] else { continue }
            for location in listed.compactMap(AllowLocation.init(plist:)) where !result.contains(location) {
                result.append(location)
            }
        }
        return result
    }

    /// Appends `location` to every entry's `menuItemLocations` that doesn't list it (starting the
    /// list if it has none). Returns false when nothing changed or `id` isn't tracked.
    @discardableResult
    public mutating func addLocation(_ location: AllowLocation, for id: BundleID) -> Bool {
        var changed = false
        let form = location.plist as NSDictionary
        for index in entryIndices(of: id) {
            guard var value = items[index + 1] as? [String: Any] else { continue }
            var listed = value["menuItemLocations"] as? [Any] ?? []
            guard !listed.contains(where: { ($0 as? NSDictionary) == form }) else { continue }
            listed.append(location.plist)
            value["menuItemLocations"] = listed
            items[index + 1] = value
            changed = true
        }
        return changed
    }

    private func entryIndices(of id: BundleID) -> [Int] {
        stride(from: 0, to: items.count, by: 2).filter { Self.bundleID(of: items[$0]) == id }
    }

    private static func bundleID(of key: Any) -> BundleID? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}
