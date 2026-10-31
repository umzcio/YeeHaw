import Foundation

public typealias AllowSnapshot = [BundleID: Bool]

public enum AllowListError: Error { case malformed }

/// Apple's per-app "Allow in the Menu Bar" list: the `trackedApplications` blob is a binary plist
/// holding a flat array of alternating keys and values. Only `isAllowed` is ever modified; every
/// other field is carried through untouched.
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

    private static func bundleID(of key: Any) -> BundleID? {
        ((key as? [String: Any])?["bundle"] as? [String: Any])?["_0"] as? String
    }
}
