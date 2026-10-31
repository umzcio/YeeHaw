public enum PositionKey {
    public static let controlCenter = "module:BentoBox-0"
    public static let clock = "module:Clock"

    /// All table keys for one item. macOS may name a slot after the item's identifier, AX
    /// description or title, or `Item-<indexInApp>`, so every candidate that exists in `table` is
    /// returned (in candidate order) and all of them get the same value. If none exist, one new
    /// key is returned, named after the first non-empty name, else `Item-<indexInApp>`.
    public static func keys(bundleID: BundleID, names: [String], indexInApp: Int, table: PositionTable) -> [String] {
        let itemName = "Item-\(indexInApp)"
        var candidates: [String] = []
        for name in names + [itemName] where !name.isEmpty && !candidates.contains(name) {
            candidates.append(name)
        }
        let all = candidates.map { "status:\(bundleID)::\($0)" }
        let existing = all.filter { table.values[$0] != nil }
        if !existing.isEmpty { return existing }
        let first = names.first { !$0.isEmpty } ?? itemName
        return ["status:\(bundleID)::\(first)"]
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
