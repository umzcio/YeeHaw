public enum PositionKey {
    public static let controlCenter = "module:BentoBox-0"
    public static let clock = "module:Clock"

    /// The key prefixes MenuBarAgent may file an app's items under: the bundle ID, and for copies
    /// that aren't notarized (Allow-list location `adhocBinary`) the executable name. Both are
    /// kept, since an earlier copy may have left keys under the other; the running copy's own
    /// prefix comes first, so a new key goes there (`notarized` is that copy's, the same check
    /// as `RunningCopy.location`). Empty and duplicate names are dropped.
    public static func prefixes(bundleID: BundleID, executableName: String?, notarized: Bool = true) -> [String] {
        guard let executableName, !executableName.isEmpty, executableName != bundleID else { return [bundleID] }
        return notarized ? [bundleID, executableName] : [executableName, bundleID]
    }

    /// Every key in `table` under any of `prefixes` (`status:<prefix>::…`), sorted: all of an
    /// app's slots, whatever macOS named them.
    public static func existingKeys(prefixes: [String], table: PositionTable) -> [String] {
        let starts = prefixes.map { "status:\($0)::" }
        return table.values.keys.filter { key in starts.contains { key.hasPrefix($0) } }.sorted()
    }

    /// All table keys for one item. macOS may name a slot after the item's identifier, AX
    /// description or title, or `Item-<indexInApp>`, under any of the app's prefixes, so every
    /// candidate that exists in `table` is returned (prefixes in order, names in candidate order
    /// within each) and all of them get the same value. If none exist, one new key is returned:
    /// the first prefix with the first non-empty name, else `Item-<indexInApp>`.
    public static func keys(prefixes: [String], names: [String], indexInApp: Int, table: PositionTable) -> [String] {
        guard let first = prefixes.first else { return [] }
        let itemName = "Item-\(indexInApp)"
        var candidates: [String] = []
        for name in names + [itemName] where !name.isEmpty && !candidates.contains(name) {
            candidates.append(name)
        }
        var existing: [String] = []
        for prefix in prefixes {
            for name in candidates {
                let key = "status:\(prefix)::\(name)"
                if table.values[key] != nil, !existing.contains(key) { existing.append(key) }
            }
        }
        if !existing.isEmpty { return existing }
        return ["status:\(first)::\(names.first { !$0.isEmpty } ?? itemName)"]
    }

    /// `keys(prefixes:names:indexInApp:table:)` for a drawn item.
    public static func keys(for item: MenuBarItem, table: PositionTable) -> [String] {
        keys(prefixes: item.keyPrefixes, names: item.keyNames, indexInApp: item.indexInApp, table: table)
    }

    /// The table key of an Apple item, or nil when it can't be resolved. Control Center and the
    /// clock map to their fixed keys; anything else must match an existing `module:<Name>` key
    /// whose Name equals the identifier's suffix, ignoring case (`...menuextra.wifi` → `module:WiFi`).
    public static func appleKey(appleIdentifier: String, table: PositionTable) -> String? {
        switch appleIdentifier {
        case "com.apple.menuextra.controlcenter": return controlCenter
        case "com.apple.menuextra.clock": return clock
        default:
            let prefix = "com.apple.menuextra."
            guard appleIdentifier.hasPrefix(prefix) else { return nil }
            let target = "module:" + appleIdentifier.dropFirst(prefix.count).lowercased()
            return table.values.keys.filter { $0.lowercased() == target }.sorted().first
        }
    }
}
