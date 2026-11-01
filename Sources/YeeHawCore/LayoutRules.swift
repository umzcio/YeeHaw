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

    /// Whether an item has an owner, and so may have a position key: items with neither a bundle ID
    /// nor an Apple identifier can't anchor a move.
    public static func isOwned(_ item: MenuBarItem) -> Bool {
        item.bundleID != nil || item.appleIdentifier != nil
    }

    /// The neighbours to pass to `MenuBarController.move` when `items[from]` is dropped at
    /// insertion `to`, or nil when the drop leaves it where it is. Only items passing `anchors`
    /// can anchor a move (by default those with an owner), so the nearest such item on each side
    /// is used.
    public static func moveNeighbors(from: Int, to: Int, in items: [MenuBarItem],
                                     anchors: (MenuBarItem) -> Bool = isOwned)
        -> (left: MenuBarItem?, right: MenuBarItem?)? {
        guard items.indices.contains(from), !isBesideItself(from: from, to: to) else { return nil }
        var rest = items
        rest.remove(at: from)
        let slot = min(max(to > from ? to - 1 : to, 0), rest.count)
        return neighbors(at: slot, in: rest, anchors: anchors)
    }

    /// `items` with `items[from]` moved to insertion `to`: the order the row shows after a drop.
    public static func moved(_ items: [MenuBarItem], from: Int, to: Int) -> [MenuBarItem] {
        guard items.indices.contains(from), !isBesideItself(from: from, to: to) else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: min(max(to > from ? to - 1 : to, 0), result.count))
        return result
    }

    /// The tiles either side of insertion `at`, for placing an app that isn't drawn (being shown).
    public static func showNeighbors(at index: Int, in items: [MenuBarItem],
                                     anchors: (MenuBarItem) -> Bool = isOwned) -> (left: MenuBarItem?, right: MenuBarItem?) {
        neighbors(at: min(max(index, 0), items.count), in: items, anchors: anchors)
    }

    /// Whether the app's drawn items, and no other anchor, sit between `left` and `right` (nil
    /// meaning the row's start or end). Items that can't anchor (see `moveNeighbors`) are ignored,
    /// since the neighbours were chosen skipping them.
    public static func isPlaced(_ id: BundleID, between left: MenuBarItem?, and right: MenuBarItem?,
                                in items: [MenuBarItem], anchors: (MenuBarItem) -> Bool = isOwned) -> Bool {
        let row = items.filter { $0.bundleID == id || anchors($0) }
        let start = left.flatMap { l in row.firstIndex { $0.id == l.id } }.map { $0 + 1 } ?? 0
        let end = right.flatMap { r in row.firstIndex { $0.id == r.id } } ?? row.count
        guard start < end else { return false }
        let between = row[start..<end]
        return between.allSatisfy { $0.bundleID == id }
            && between.count == row.filter { $0.bundleID == id }.count
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

    // MARK: Dragging

    /// The rows a drag can be over.
    public enum DropRow: Sendable { case bar, hidden }

    /// Where a dragged tile comes from: its index in the Menu Bar row, or its group's index in the
    /// Hidden row.
    public enum DropSource: Equatable, Sendable {
        case bar(Int)
        case hidden(Int)
    }

    /// Where a drop would go: an insertion in one of the rows, or a refusal (a tile that can't be
    /// hidden held over the Hidden row).
    public enum DropTarget: Equatable, Sendable {
        case bar(Int)
        case hidden(Int)
        case refused(HideRefusal)
    }

    /// Where a tile from `source` held over `row` at `insertion` would be dropped, or nil for
    /// nowhere: outside the rows, or back where it was. `refusal` is why a Menu Bar tile can't be
    /// hidden, if it can't.
    public static func dropTarget(over row: DropRow?, insertion: Int, source: DropSource, bar: [MenuBarItem],
                                  refusal: HideRefusal?, anchors: (MenuBarItem) -> Bool = isOwned) -> DropTarget? {
        switch (row, source) {
        case (nil, _):
            return nil
        case (.bar?, .bar(let from)):
            let index = clampedInsertion(insertion, in: bar)
            return moveNeighbors(from: from, to: index, in: bar, anchors: anchors) == nil ? nil : .bar(index)
        case (.bar?, .hidden):
            return .bar(clampedInsertion(insertion, in: bar))
        case (.hidden?, .bar):
            return refusal.map(DropTarget.refused) ?? .hidden(max(insertion, 0))
        case (.hidden?, .hidden(let from)):
            return isBesideItself(from: from, to: insertion) ? nil : .hidden(insertion)
        }
    }

    /// How many slots the tile at `index` shifts while a tile is held over insertion `to` of its
    /// row (nil: not over this row), so a full slot opens where it would land. `from` is the held
    /// tile's own index when it's from this row: its place closes up, the way the Dock does it.
    /// The held tile's own place doesn't shift.
    public static func slotShift(of index: Int, from: Int?, to: Int?) -> Int {
        guard let to else { return 0 }
        guard let from else { return index >= to ? 1 : 0 }
        guard index != from, !isBesideItself(from: from, to: to) else { return 0 }
        let landing = to > from ? to - 1 : to
        if landing < from { return (landing..<from).contains(index) ? 1 : 0 }
        return (from + 1...landing).contains(index) ? -1 : 0
    }

    /// Whether insertion `to` leaves the tile at `from` where it is.
    private static func isBesideItself(from: Int, to: Int) -> Bool {
        to == from || to == from + 1
    }

    /// The nearest items passing `anchors` on each side of insertion `slot`.
    private static func neighbors(at slot: Int, in items: [MenuBarItem], anchors: (MenuBarItem) -> Bool)
        -> (left: MenuBarItem?, right: MenuBarItem?) {
        (items[..<slot].last(where: anchors), items[slot...].first(where: anchors))
    }
}
