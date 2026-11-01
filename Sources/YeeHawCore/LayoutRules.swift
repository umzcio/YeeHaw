/// Why a tile can't be dragged at all.
public enum FixedReason: Equatable, Sendable {
    /// macOS keeps it in place (clock, Control Center).
    case pinned
    /// Nobody claims it, so it has no position key to write.
    case unknownOwner
}

/// Why a tile that can be reordered can't go into Hidden.
public enum HideRefusal: Equatable, Sendable {
    /// One of macOS's own items.
    case apple
    /// YeeHaw's own icon.
    case own
    /// The app has no Allow-list entry yet; macOS adds one some time after it first draws an icon.
    case notTrackedYet
}

/// What the layout window lets a tile do.
public enum TileCapability: Equatable, Sendable {
    case fixed(FixedReason)
    case reorderOnly(HideRefusal)
    case hideable

    public var canDrag: Bool {
        if case .fixed = self { false } else { true }
    }

    public var canHide: Bool { self == .hideable }

    public var hideRefusal: HideRefusal? {
        if case .reorderOnly(let refusal) = self { refusal } else { nil }
    }
}

/// The layout window's drop rules and index arithmetic, kept free of UI so they can be tested.
///
/// Insertion indices are positions in a row as it was when the drag began: `i` means "before the
/// tile at `i`", and `count` means "after the last tile".
public enum LayoutRules {
    public static func capability(of item: MenuBarItem, own: BundleID, tracked: Set<BundleID>,
                                  appleMovable: Bool = true) -> TileCapability {
        if item.isPinned { return .fixed(.pinned) }
        guard let id = item.bundleID else {
            guard item.appleIdentifier != nil else { return .fixed(.unknownOwner) }
            return appleMovable ? .reorderOnly(.apple) : .fixed(.pinned)
        }
        if id == own { return .reorderOnly(.own) }
        return tracked.contains(id) ? .hideable : .reorderOnly(.notTrackedYet)
    }

    /// One entry per item id, keeping the first (leftmost) of the copies other displays draw.
    public static func deduplicated(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    /// How many of `midpoints` (ascending) lie left of `x`: the insertion index for a pointer at `x`.
    public static func insertionIndex(forX x: Double, midpoints: [Double]) -> Int {
        midpoints.filter { $0 < x }.count
    }

    /// Where an item may be dropped in the Menu Bar row: anywhere left of the first pinned item,
    /// since macOS keeps the pinned items at the trailing end.
    public static func allowedInsertions(in items: [MenuBarItem]) -> ClosedRange<Int> {
        0...(items.firstIndex(where: \.isPinned) ?? items.count)
    }

    public static func clampedInsertion(_ index: Int, in items: [MenuBarItem]) -> Int {
        let range = allowedInsertions(in: items)
        return min(max(index, range.lowerBound), range.upperBound)
    }

    /// The neighbours to pass to `MenuBarController.move` when `items[from]` is dropped at
    /// insertion `to`, or nil when the drop leaves it where it is. Items with no known owner
    /// can't anchor a move, so the nearest owned item on each side is used.
    public static func moveNeighbors(from: Int, to: Int, in items: [MenuBarItem])
        -> (left: MenuBarItem?, right: MenuBarItem?)? {
        guard items.indices.contains(from), to != from, to != from + 1 else { return nil }
        var rest = items
        rest.remove(at: from)
        let slot = min(max(to > from ? to - 1 : to, 0), rest.count)
        return neighbors(at: slot, in: rest)
    }

    /// `items` with `items[from]` moved to insertion `to`: the order the row shows after a drop.
    public static func moved(_ items: [MenuBarItem], from: Int, to: Int) -> [MenuBarItem] {
        guard items.indices.contains(from), to != from, to != from + 1 else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: min(max(to > from ? to - 1 : to, 0), result.count))
        return result
    }

    /// The tiles either side of insertion `at`, for placing an app that isn't drawn (being shown).
    public static func showNeighbors(at index: Int, in items: [MenuBarItem]) -> (left: MenuBarItem?, right: MenuBarItem?) {
        neighbors(at: min(max(index, 0), items.count), in: items)
    }

    /// Whether the app's drawn items, and nothing else, sit between `left` and `right` (nil meaning
    /// the row's start or end).
    public static func isPlaced(_ id: BundleID, between left: MenuBarItem?, and right: MenuBarItem?,
                                in items: [MenuBarItem]) -> Bool {
        let start = left.flatMap { l in items.firstIndex { $0.id == l.id } }.map { $0 + 1 } ?? 0
        let end = right.flatMap { r in items.firstIndex { $0.id == r.id } } ?? items.count
        guard start < end else { return false }
        let between = items[start..<end]
        return between.allSatisfy { $0.bundleID == id }
            && between.count == items.filter { $0.bundleID == id }.count
    }

    /// The strip order after dropping app `id`'s group at insertion `at` of `order`. The app may
    /// already be in `order` (a reorder) or not (newly hidden).
    public static func hiddenOrder(_ order: [BundleID], placing id: BundleID, at index: Int) -> [BundleID] {
        var result = order
        var slot = index
        if let current = result.firstIndex(of: id) {
            result.remove(at: current)
            if slot > current { slot -= 1 }
        }
        result.insert(id, at: min(max(slot, 0), result.count))
        return result
    }

    /// The nearest items with an owner on each side of insertion `slot`.
    private static func neighbors(at slot: Int, in items: [MenuBarItem]) -> (left: MenuBarItem?, right: MenuBarItem?) {
        let owned: (MenuBarItem) -> Bool = { $0.bundleID != nil || $0.appleIdentifier != nil }
        return (items[..<slot].last(where: owned), items[slot...].first(where: owned))
    }
}
