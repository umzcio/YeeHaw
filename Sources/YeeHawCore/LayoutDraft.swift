/// What Apply has to do to make the menu bar match a `LayoutDraft`, in Apply's order: shows, then
/// hides, then moves, then the Hidden order.
public struct LayoutChanges: Equatable, Sendable {
    /// A hidden app to switch on, its icons placed between two neighbours (nil: no constraint on
    /// that side). `left` may be another shown app's icon: shown apps are placed left to right,
    /// after the moves, so every neighbour is where it stays.
    public struct Show: Equatable, Sendable {
        public var id: BundleID
        public var left, right: MenuBarItem?

        public init(id: BundleID, left: MenuBarItem?, right: MenuBarItem?) {
            self.id = id
            self.left = left
            self.right = right
        }
    }

    /// An icon to place between two neighbours, as `MenuBarController.move` takes them. Moves are
    /// written left to right: `left` may be an icon moved before it, `right` is one that stays.
    public struct Move: Equatable, Sendable {
        public var item: MenuBarItem
        public var left, right: MenuBarItem?

        public init(item: MenuBarItem, left: MenuBarItem?, right: MenuBarItem?) {
            self.item = item
            self.left = left
            self.right = right
        }
    }

    public var shows: [Show] = []
    public var hides: [BundleID] = []
    public var moves: [Move] = []
    /// The strip order to set once the hides are done, when it isn't the one they leave
    /// (hiding appends).
    public var hiddenOrder: [BundleID]?

    public var isEmpty: Bool { shows.isEmpty && hides.isEmpty && moves.isEmpty && hiddenOrder == nil }

    /// One short phrase per change, in Apply's order, naming each app once per kind
    /// ("Show DigUp", "Hide Fiddle", "Move zWhisper", "Reorder Hidden").
    public func phrases(itemName: (MenuBarItem) -> String, appName: (BundleID) -> String) -> [String] {
        var result = shows.map { "Show \(appName($0.id))" } + hides.map { "Hide \(appName($0))" }
        for move in moves {
            let phrase = "Move \(itemName(move.item))"
            if !result.contains(phrase) { result.append(phrase) }
        }
        if hiddenOrder != nil { result.append("Reorder Hidden") }
        return result
    }
}

/// The Layout window's draft: its Menu Bar and Hidden rows as the user has arranged them, beside
/// the real ones, until Apply writes the difference (`changes`) or Revert drops it. Kept free of
/// UI so the diff, the reconcile and the summary can be tested.
///
/// The draft bar holds real items, plus a placeholder per icon of a hidden app being shown (it
/// isn't drawn, so it has no frame or keys): any draft item of an app that's really hidden.
public struct LayoutDraft: Equatable, Sendable {
    /// The bar (left to right, hidden apps' items left out) and the strip order, as they really are.
    public private(set) var realBar: [MenuBarItem]
    public private(set) var realHidden: [BundleID]
    public private(set) var bar: [MenuBarItem]
    public private(set) var hidden: [BundleID]
    /// Items the user moved (or put back by showing their app), whose place may need writing.
    private var touched: Set<String> = []

    public init(bar: [MenuBarItem], hidden: [BundleID]) {
        realBar = bar
        realHidden = hidden
        self.bar = bar
        self.hidden = hidden
    }

    /// Whether the draft differs from the real rows. Moving an icon and moving it back, or hiding
    /// an app and showing it in its old place, leaves it clean.
    public var isDirty: Bool { bar.map(\.id) != realBar.map(\.id) || hidden != realHidden }

    public func isPlaceholder(_ item: MenuBarItem) -> Bool {
        item.bundleID.map(realHidden.contains) ?? false
    }

    // MARK: Edits (insertion indices as `LayoutRules` uses them)

    /// Moves `bar[from]` to insertion `to`.
    public mutating func move(from: Int, to: Int) {
        guard bar.indices.contains(from) else { return }
        touched.insert(bar[from].id)
        bar = LayoutRules.moved(bar, from: from, to: to)
    }

    /// Takes every icon of `id` out of the bar and puts the app at insertion `at` of Hidden.
    public mutating func hide(_ id: BundleID, at index: Int) {
        bar.removeAll { $0.bundleID == id }
        hidden = LayoutRules.hiddenOrder(hidden, placing: id, at: index)
    }

    /// Puts a hidden app's icons at insertion `at` of the bar: its real items when it's only
    /// hidden in the draft, else `placeholders`.
    public mutating func show(_ id: BundleID, placeholders: [MenuBarItem], at index: Int) {
        guard hidden.contains(id) else { return }
        hidden.removeAll { $0 == id }
        let real = realBar.filter { $0.bundleID == id }
        let items = real.isEmpty ? placeholders : real
        touched.formUnion(items.map(\.id))
        bar.insert(contentsOf: items, at: min(max(index, 0), bar.count))
    }

    /// Moves the hidden app `id` to insertion `at` of Hidden.
    public mutating func reorderHidden(_ id: BundleID, at index: Int) {
        guard hidden.contains(id) else { return }
        hidden = LayoutRules.hiddenOrder(hidden, placing: id, at: index)
    }

    public mutating func revert() {
        self = LayoutDraft(bar: realBar, hidden: realHidden)
    }

    /// Takes a new reading of the real rows without losing the user's edits: items that are no
    /// longer drawn leave the draft (a show of an app that's no longer hidden goes with them),
    /// items still drawn take their latest reading, and newly drawn items join at their real
    /// place (after the nearest item before them that's in the draft). Apps hidden in the draft
    /// stay hidden there; apps newly hidden for real join the end of Hidden.
    public mutating func reconcile(bar newBar: [MenuBarItem], hidden newHidden: [BundleID]) {
        let fresh = Dictionary(newBar.map { ($0.id, $0) }) { first, _ in first }
        let wasHidden = realHidden
        // Placeholders stay while their app is still really hidden; real items while still drawn.
        var draftBar = bar.compactMap { item -> MenuBarItem? in
            if isPlaceholder(item) { return newHidden.contains(item.bundleID ?? "") ? item : nil }
            return fresh[item.id]
        }
        var draftHidden = hidden.filter { newHidden.contains($0) || !wasHidden.contains($0) }
        for id in newHidden where !wasHidden.contains(id) && !draftHidden.contains(id) {
            draftHidden.append(id)
            draftBar.removeAll { $0.bundleID == id }
        }
        for (index, item) in newBar.enumerated() where !draftBar.contains(where: { $0.id == item.id }) {
            guard !(item.bundleID.map(draftHidden.contains) ?? false) else { continue }
            let before = newBar[..<index].last { earlier in draftBar.contains { $0.id == earlier.id } }
            let slot = before.flatMap { earlier in draftBar.firstIndex { $0.id == earlier.id } }.map { $0 + 1 } ?? 0
            draftBar.insert(item, at: slot)
        }
        realBar = newBar
        realHidden = newHidden
        bar = draftBar
        hidden = draftHidden
        touched.formIntersection(draftBar.map(\.id))
    }

    // MARK: The difference

    /// What Apply writes. `anchors` says which real items can be a neighbour (by default those with
    /// an owner; the caller also rules out items with no saved position). Placeholders can only be
    /// the left neighbour of a later shown app, since their keys exist only once placed.
    public func changes(anchors: (MenuBarItem) -> Bool = LayoutRules.isOwned) -> LayoutChanges {
        var changes = LayoutChanges()
        changes.hides = hidden.filter { !realHidden.contains($0) }

        // Items moved relative to the rest. Moving an item never reorders the others, so the
        // untouched ones keep their real order; a touched one that still fits that order (moved
        // back, or passed by another) needs no move of its own.
        let realIndex = Dictionary(realBar.enumerated().map { ($1.id, $0) }) { first, _ in first }
        var staying = Set(bar.filter { !touched.contains($0.id) && realIndex[$0.id] != nil }.map(\.id))
        for item in bar where touched.contains(item.id) && realIndex[item.id] != nil {
            let order = bar.filter { staying.contains($0.id) || $0.id == item.id }.compactMap { realIndex[$0.id] }
            if order == order.sorted() { staying.insert(item.id) }
        }
        func real(_ item: MenuBarItem) -> Bool { realIndex[item.id] != nil && anchors(item) }
        for (index, item) in bar.enumerated() where realIndex[item.id] != nil && !staying.contains(item.id) {
            let left = bar[..<index].last(where: real)
            let right = bar[(index + 1)...].first { staying.contains($0.id) && real($0) }
            changes.moves.append(.init(item: item, left: left, right: right))
        }

        for id in realHidden where !hidden.contains(id) {
            guard let first = bar.firstIndex(where: { $0.bundleID == id }),
                  let last = bar.lastIndex(where: { $0.bundleID == id }) else { continue }
            let left = bar[..<first].last { isPlaceholder($0) || real($0) }
            let right = bar[(last + 1)...].first(where: real)
            changes.shows.append(.init(id: id, left: left, right: right))
        }
        changes.shows.sort { a, b in
            (bar.firstIndex { $0.bundleID == a.id } ?? 0) < (bar.firstIndex { $0.bundleID == b.id } ?? 0)
        }

        let afterHiding = realHidden.filter(hidden.contains) + changes.hides
        if hidden != afterHiding { changes.hiddenOrder = hidden }
        return changes
    }

    /// The real items either side of `item` in the draft bar, whatever they can anchor: where the
    /// user put it. A move is placed between anchors (`changes`), so when an icon that can't
    /// anchor sits between those, only this says whether it really landed where it was put.
    public func neighbours(of item: MenuBarItem) -> (left: MenuBarItem?, right: MenuBarItem?) {
        guard let index = bar.firstIndex(where: { $0.id == item.id }) else { return (nil, nil) }
        return (bar[..<index].last { !isPlaceholder($0) }, bar[(index + 1)...].first { !isPlaceholder($0) })
    }

    /// The footer's summary: the phrases joined ("Hide Fiddle, move zWhisper") while that fits in
    /// `maxLength` characters, else a count ("3 changes"). Empty for no changes.
    public static func summary(_ phrases: [String], maxLength: Int) -> String {
        guard !phrases.isEmpty else { return "" }
        let joined = phrases.enumerated().map { index, phrase in
            index == 0 ? phrase : phrase.prefix(1).lowercased() + phrase.dropFirst()
        }.joined(separator: ", ")
        if joined.count <= maxLength { return joined }
        return phrases.count == 1 ? "1 change" : "\(phrases.count) changes"
    }
}
