public enum PositionKey {
    public static let controlCenter = "module:BentoBox-0"
    public static let clock = "module:Clock"

    /// The table key for one item. An item's key is `status:<bundleID>::<name>` where name is the
    /// AX identifier, or `Item-<indexInApp>` when there is none. The name match is exact, so the
    /// existing key and the would-be new key are the same string; `table` is accepted so callers
    /// stay unchanged if matching ever widens.
    public static func keys(bundleID: BundleID, axIdentifier: String, indexInApp: Int, table: PositionTable) -> [String] {
        let name = axIdentifier.isEmpty ? "Item-\(indexInApp)" : axIdentifier
        return ["status:\(bundleID)::\(name)"]
    }
}
