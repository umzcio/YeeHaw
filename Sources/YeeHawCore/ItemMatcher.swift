public struct DrawnItem: Equatable, Sendable {
    public var x, width: Double
    public var label: String
    public var appleIdentifier: String?

    public init(x: Double, width: Double, label: String, appleIdentifier: String? = nil) {
        self.x = x
        self.width = width
        self.label = label
        self.appleIdentifier = appleIdentifier
    }
}

public struct AppExtra: Equatable, Sendable {
    public var bundleID: BundleID
    public var indexInApp: Int
    public var x, width: Double
    public var identifier, title, description: String
    /// The owning app's executable name, a second key prefix for apps that aren't notarized.
    public var executableName: String

    public init(bundleID: BundleID, indexInApp: Int, x: Double, width: Double,
                identifier: String = "", title: String = "", description: String = "",
                executableName: String = "") {
        self.bundleID = bundleID
        self.indexInApp = indexInApp
        self.x = x
        self.width = width
        self.identifier = identifier
        self.title = title
        self.description = description
        self.executableName = executableName
    }
}

public struct MenuBarItem: Equatable, Identifiable, Sendable {
    public var id: String            // "<bundleID>#<indexInApp>", appleIdentifier, or "unknown@<x>"
    public var bundleID: BundleID?   // nil for Apple items and items with unknown owner
    public var appleIdentifier: String?
    public var indexInApp: Int
    public var label: String
    public var keyNames: [String]    // non-empty identifier, title, description, in that order
    public var keyPrefixes: [String] // PositionKey.prefixes of the owner; empty with no owning app
    public var x, width: Double
    public var isPinned: Bool        // clock, control center

    public init(id: String, bundleID: BundleID?, appleIdentifier: String?, indexInApp: Int,
                label: String, keyNames: [String], keyPrefixes: [String],
                x: Double, width: Double, isPinned: Bool) {
        self.id = id
        self.bundleID = bundleID
        self.appleIdentifier = appleIdentifier
        self.indexInApp = indexInApp
        self.label = label
        self.keyNames = keyNames
        self.keyPrefixes = keyPrefixes
        self.x = x
        self.width = width
        self.isPinned = isPinned
    }
}

public enum ItemMatcher {
    public static let tolerance: Double = 0.5

    private static let pinnedIdentifiers: Set<String> = [
        "com.apple.menuextra.clock",
        "com.apple.menuextra.controlcenter",
    ]

    /// Left-to-right. Extras with no exact (x, width) match in `drawn` are not drawn and are dropped.
    /// Drawn items nobody claims are kept with an unknown owner so the layout still shows the slot.
    ///
    /// `offApps` are switched off in Apple's Allow list, so they aren't drawn, but an app can keep
    /// reporting the frame its icon last had, and a neighbour that slid into that place has the
    /// same frame. Their extras are only tried after every other app's (spec: exact matching,
    /// combined with Apple's Allow list).
    public static func match(drawn: [DrawnItem], extras: [AppExtra], offApps: Set<BundleID> = []) -> [MenuBarItem] {
        var unused = extras.filter { !offApps.contains($0.bundleID) } + extras.filter { offApps.contains($0.bundleID) }
        var items: [MenuBarItem] = []
        for d in drawn {
            if let apple = d.appleIdentifier {
                items.append(MenuBarItem(
                    id: apple, bundleID: nil, appleIdentifier: apple, indexInApp: 0,
                    label: d.label, keyNames: [], keyPrefixes: [],
                    x: d.x, width: d.width, isPinned: pinnedIdentifiers.contains(apple)))
            } else if let i = unused.firstIndex(where: {
                abs($0.x - d.x) <= tolerance && abs($0.width - d.width) <= tolerance
            }) {
                let e = unused.remove(at: i)
                items.append(MenuBarItem(
                    id: "\(e.bundleID)#\(e.indexInApp)", bundleID: e.bundleID, appleIdentifier: nil,
                    indexInApp: e.indexInApp, label: d.label,
                    keyNames: [e.identifier, e.title, e.description].filter { !$0.isEmpty },
                    keyPrefixes: PositionKey.prefixes(bundleID: e.bundleID, executableName: e.executableName),
                    x: d.x, width: d.width, isPinned: false))
            } else {
                items.append(MenuBarItem(
                    id: "unknown@\(Int(d.x))", bundleID: nil, appleIdentifier: nil, indexInApp: 0,
                    label: d.label, keyNames: [], keyPrefixes: [],
                    x: d.x, width: d.width, isPinned: false))
            }
        }
        return items.sorted { $0.x < $1.x }
    }
}
