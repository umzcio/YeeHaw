import AppKit
import Observation
import os
import SwiftUI
import YeeHawCore

/// One tile of the Menu Bar row: a drawn item and what it may do.
struct BarTile: Identifiable, Equatable {
    let item: MenuBarItem
    let capability: TileCapability
    let name: String
    let image: NSImage
    var id: String { item.id }
}

/// One hidden app: a tile per icon it drew when last seen, kept together.
struct HiddenGroup: Identifiable, Equatable {
    struct Icon: Identifiable, Equatable {
        let id: String
        let image: NSImage
    }

    let id: BundleID
    let name: String
    let icons: [Icon]
}

/// A problem shown inline at the bottom of the window.
struct LayoutMessage: Equatable {
    let text: String
    /// The file to ask access to again, when "Fix…" would help.
    var grant: GrantedFile? = nil

    var offersFix: Bool { grant != nil }
}

/// The colours the tiles are painted in: the menu bar's own (sampled), so glyphs look exactly as
/// they do in the bar, or system fills when no sample is available.
enum TileStyle: Equatable {
    case bar(fill: StripRGB, ink: StripInk)
    case system
}

/// The layout window's state. Its edits are a draft (`LayoutDraft`): the rows change at once and
/// nothing is written until Apply, which writes the layout edits through `MenuBarController`,
/// waits once for macOS to show them, then applies any spacing change (`SpacingModel`). Revert,
/// or closing without applying, drops the draft.
@MainActor @Observable
final class LayoutModel {
    private static let log = Logger(subsystem: Log.subsystem, category: "layout")
    /// How long Apply waits for macOS to show all the layout edits together, before naming the
    /// ones it didn't. MenuBarAgent applies a write within a few seconds.
    static let applyTimeout: Duration = .seconds(5)
    static let applyPoll: Duration = .milliseconds(250)
    /// The longest the footer's summary may be before it gives a count instead.
    static let summaryLength = 48
    /// After Apply, how long to let the icons slide into their new places before photographing
    /// them; a shot taken while they move crops the wrong glyphs and caches them.
    static let photoSettle: Duration = .seconds(1)

    /// The draft's rows, as tiles.
    private(set) var bar: [BarTile] = []
    private(set) var hidden: [HiddenGroup] = []
    private(set) var draft = LayoutDraft(bar: [], hidden: [])
    /// True from the start of Apply until the rows show what the bar holds after it. Drags and
    /// edits wait for it.
    private(set) var applying = false
    /// A spacing Apply is restarting apps: their items come and go, so edits wait for it too.
    var spacingBusy = false
    /// Drags and edits wait while either is under way.
    var editsLocked: Bool { applying || spacingBusy }
    private(set) var tileStyle: TileStyle = .system
    var message: LayoutMessage?
    /// The widest the rows may be before they scroll, from the screen the window is on.
    var maxRowWidth: CGFloat = 1200
    /// The tallest the window's content may be before it scrolls, from the screen the window is on.
    var maxContentHeight: CGFloat = 10_000
    /// Whether the keyboard focus is drawn: only once a key was pressed in the window, not after a
    /// click, the way macOS shows focus in lists.
    var showsFocusRing = false
    /// Counts the window's closes, so the view can drop any drag and focus it still holds.
    private(set) var closes = 0
    /// Counts Esc presses during a drag, so the view can cancel it (see `requestDragCancel`).
    private(set) var dragCancels = 0

    @ObservationIgnored let controller: MenuBarController
    @ObservationIgnored let images: IconImageProvider
    @ObservationIgnored let requestGrant: (GrantedFile) async -> Bool
    /// The window's spacing section, whose change is part of the draft and applied last.
    @ObservationIgnored var spacing: SpacingModel?
    /// How long Apply waits for macOS (`applyTimeout`; shorter in tests).
    @ObservationIgnored var applyTimeout = LayoutModel.applyTimeout
    /// Shared with the strip, so both read one cache of the bar's colour.
    @ObservationIgnored private let sampler = StripColorSampler.shared
    /// Set by the view while a tile is being dragged; reloads wait until the drag ends, so the
    /// rows don't change under the pointer.
    @ObservationIgnored var isDragging = false {
        didSet { if isDragging != oldValue { onDraggingChange?(isDragging) } }
    }
    /// Told when a drag starts and ends (the window watches for Esc meanwhile).
    @ObservationIgnored var onDraggingChange: ((Bool) -> Void)?
    /// The widest the rows have been since the window opened. Rows never narrow while it's open,
    /// so the window doesn't jump each time an icon is hidden or shown.
    @ObservationIgnored private var widestRow: CGFloat = 0
    /// A rebuild of the rows from the controller, asked for while Apply or a drag was running.
    @ObservationIgnored private var reloadPending = false
    /// A re-read of the bar, asked for while Apply, a drag or another re-read was running.
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var refreshing = false
    /// Drawn items whose position key isn't saved yet: they can't anchor a move (see
    /// `MenuBarController.itemsWithoutPositions`).
    @ObservationIgnored private var withoutPositions: Set<String> = []

    init(controller: MenuBarController, images: IconImageProvider,
         requestGrant: @escaping (GrantedFile) async -> Bool = { _ in false }) {
        self.controller = controller
        self.images = images
        self.requestGrant = requestGrant
        reload()
    }

    // MARK: The draft

    /// Whether anything waits for Apply: a layout edit or a spacing change.
    var isDirty: Bool { draft.isDirty || spacing?.isPending == true }

    /// What Apply would do, one phrase per change, the spacing change last.
    var pendingPhrases: [String] {
        draft.changes(anchors: canAnchor).phrases(itemName: Self.name(of:), appName: AppIdentity.name(of:))
            + [spacing?.pendingPhrase].compactMap(\.self)
    }

    /// The footer's summary of the draft ("Hide Fiddle, move zWhisper", or "3 changes").
    var summary: String { LayoutDraft.summary(pendingPhrases, maxLength: Self.summaryLength) }

    /// The apps Apply will quit and reopen for the spacing change.
    var restarting: [String] { spacing?.isPending == true ? spacing?.restartNames ?? [] : [] }

    // MARK: Reading

    /// Takes the controller's last read and saved state as the real rows. A clean draft follows
    /// them; a dirty one keeps its edits (`LayoutDraft.reconcile`).
    func reload() {
        let hiddenIDs = controller.state.hidden
        images.noteDrawn(controller.items)
        withoutPositions = controller.itemsWithoutPositions()
        let real = LayoutRules.deduplicated(controller.items).filter { item in
            item.bundleID.map { !hiddenIDs.contains($0) } ?? true
        }
        if draft.isDirty {
            draft.reconcile(bar: real, hidden: hiddenIDs)
        } else {
            draft = LayoutDraft(bar: real, hidden: hiddenIDs)
        }
        rebuildRows()
    }

    /// The tiles for the draft. A hidden app being shown isn't drawn: its tiles are the icons it
    /// drew when last seen.
    private func rebuildRows() {
        let tracked = controller.trackedApps
        bar = draft.bar.map { item in
            if draft.isPlaceholder(item), let id = item.bundleID {
                return BarTile(item: item, capability: .hideable, name: AppIdentity.name(of: id),
                               image: images.image(for: id, indexInApp: item.indexInApp))
            }
            return BarTile(item: item,
                           capability: LayoutRules.capability(of: item, own: OwnIconLocator.bundleID, tracked: tracked,
                                                              appleMovable: !withoutPositions.contains(item.id)),
                           name: Self.name(of: item), image: images.image(for: item))
        }
        hidden = draft.hidden.map { id in
            HiddenGroup(id: id, name: AppIdentity.name(of: id),
                        icons: images.iconIndices(for: id).map {
                            HiddenGroup.Icon(id: "\(id)#\($0)", image: images.image(for: id, indexInApp: $0))
                        })
        }
    }

    /// Whether `item` can anchor a move: it has an owner and a saved position.
    func canAnchor(_ item: MenuBarItem) -> Bool {
        LayoutRules.isOwned(item) && !withoutPositions.contains(item.id)
    }

    /// Re-reads the bar, photographs what's drawn, samples the bar's colour and rebuilds the rows.
    /// Asked for while Apply, a drag or another re-read is running, it runs once that ends.
    func refresh() async {
        guard !applying, !isDragging, !refreshing else {
            refreshPending = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshPending = false
            await controller.refresh()
            await images.captureIfPermitted(controller.items)
            await sampleBarColour()
            guard !applying, !isDragging else {
                // The re-read is stale by the time Apply or the drag ends; read again then.
                refreshPending = true
                return
            }
            reloadPending = false
            withAnimation(Self.rowAnimation) { reload() }
        } while refreshPending
    }

    /// Call after the Allow list changed on disk and the controller has applied it.
    func allowListChanged() {
        reloadWhenIdle()
    }

    /// The rows' width for content `natural` wide, never less than before while the window is open.
    func rowWidth(natural: CGFloat) -> CGFloat {
        widestRow = max(widestRow, natural)
        return widestRow
    }

    /// Call when the window closes: an unapplied draft is let go, the next opening sizes the rows
    /// afresh, and any drag ends. An Apply under way carries on.
    func windowClosed() {
        widestRow = 0
        message = nil
        showsFocusRing = false
        closes += 1
        dragEnded()
        if !applying {
            draft.revert()
            rebuildRows()
        }
    }

    /// Call when Esc is pressed during a drag; the view springs the tile back.
    func requestDragCancel() {
        dragCancels += 1
    }

    /// Call when a drag has ended: applies a re-read or reload that waited for it.
    func dragEnded() {
        isDragging = false
        catchUp()
    }

    /// Rebuilds the rows now, or once Apply or the drag under way has ended.
    private func reloadWhenIdle() {
        guard !applying, !isDragging else {
            reloadPending = true
            return
        }
        reloadPending = false
        withAnimation(Self.rowAnimation) { reload() }
    }

    /// Runs what waited for Apply or a drag to end.
    private func catchUp() {
        guard !applying, !isDragging else { return }
        if refreshPending {
            Task { await refresh() }
        } else if reloadPending {
            reloadWhenIdle()
        }
    }

    private func sampleBarColour() async {
        guard let screen = NSScreen.screens.first, let display = StripColorSampler.displayID(of: screen) else { return }
        if case .sampled(let fill) = await sampler.sample(display: display, barHeight: StripPanel.barHeight(of: screen)) {
            tileStyle = .bar(fill: fill, ink: StripColor.ink(for: fill))
        } else if let kept = sampler.cached(for: display) {
            tileStyle = .bar(fill: kept, ink: StripColor.ink(for: kept))
        } else {
            tileStyle = .system
        }
    }

    // MARK: Edits (all to the draft)

    /// Moves `bar[from]` to insertion `to` of the Menu Bar row. False when nothing moves.
    @discardableResult
    func move(from: Int, to: Int) -> Bool {
        guard !editsLocked, bar.indices.contains(from), bar[from].capability.canDrag else { return false }
        let to = LayoutRules.clampedInsertion(to, in: draft.bar)
        guard LayoutRules.moved(draft.bar, from: from, to: to) != draft.bar else { return false }
        draft.move(from: from, to: to)
        edited()
        return true
    }

    /// Hides the app owning `bar[from]` and puts its group at insertion `at` of the Hidden row.
    @discardableResult
    func hide(from: Int, at index: Int) -> Bool {
        guard !editsLocked, bar.indices.contains(from), bar[from].capability.canHide,
              let id = bar[from].item.bundleID else { return false }
        // The group gets a tile per icon the app draws right now.
        images.noteDrawn(controller.items)
        draft.hide(id, at: index)
        edited()
        return true
    }

    /// Shows a hidden app at insertion `at` of the Menu Bar row: by default at the row's right
    /// end, just left of the icons macOS keeps in place, where it's easy to see.
    @discardableResult
    func show(_ id: BundleID, at index: Int?) -> Bool {
        guard !editsLocked, hidden.contains(where: { $0.id == id }) else { return false }
        let at = LayoutRules.clampedInsertion(index ?? draft.bar.count, in: draft.bar)
        let placeholders = images.iconIndices(for: id).map { icon in
            MenuBarItem(id: "\(id)#\(icon)", bundleID: id, appleIdentifier: nil, indexInApp: icon,
                        label: AppIdentity.name(of: id), keyNames: [], keyPrefixes: [], x: 0, width: 0, isPinned: false)
        }
        draft.show(id, placeholders: placeholders, at: at)
        edited()
        return true
    }

    /// Moves the hidden app `id` to insertion `at` of the Hidden row (the strip's order).
    func reorderHidden(_ id: BundleID, at index: Int) {
        guard !editsLocked else { return }
        let order = LayoutRules.hiddenOrder(draft.hidden, placing: id, at: index)
        guard order != draft.hidden else { return }
        draft.reorderHidden(id, at: index)
        edited()
    }

    /// Puts the draft, the slider and the ticks back to what's real, animated.
    func revert() {
        guard !editsLocked else { return }
        withAnimation(Self.rowAnimation) {
            draft.revert()
            spacing?.revert()
            message = nil
            rebuildRows()
        }
    }

    private func edited() {
        message = nil
        rebuildRows()
    }

    /// "Fix…": asks for the file again, and clears the message once it's granted.
    func fix() {
        guard let file = message?.grant else { return }
        Task {
            if await requestGrant(file) {
                withAnimation(Self.rowAnimation) { message = nil }
            }
        }
    }

    // MARK: Apply

    /// One edit Apply couldn't make, and why.
    struct Failure {
        let what: String
        let error: Error
    }

    /// Writes the draft: the layout edits (`applyLayout`), then the spacing change, which restarts
    /// apps and so must see the final layout. The window stays locked until the rows show what the
    /// bar really holds; each edit that failed is back where it really is, its reason inline.
    @discardableResult
    func apply() -> Task<[Failure], Never>? {
        guard isDirty, !editsLocked else { return nil }
        let changes = draft.changes(anchors: canAnchor)
        let neighbours = Dictionary(changes.moves.map { ($0.item.id, draft.neighbours(of: $0.item)) }) { first, _ in first }
        let order = draft.hidden
        let hiddenBefore = draft.realHidden
        let spacing = spacing?.isPending == true ? spacing : nil
        applying = true
        message = nil
        return Task {
            let failures = await applyLayout(changes, neighbours: neighbours, hiddenOrder: order,
                                             hiddenBefore: hiddenBefore)
            // The spacing section reports (and announces) its own outcome.
            if let spacing { await spacing.apply() }
            await controller.refresh()
            applying = false
            refreshPending = false
            reloadPending = false
            withAnimation(Self.rowAnimation) {
                draft.revert()
                reload()
                message = Self.message(for: failures.map(\.error))
            }
            catchUp()
            for failure in failures {
                Self.log.error("Layout could not \(failure.what, privacy: .public): \(failure.error, privacy: .public)")
            }
            let outcome = failures.isEmpty ? "Your changes are in the menu bar."
                : "Some changes didn’t apply. \(message?.text ?? "")"
            AccessibilityNotification.Announcement(outcome).post()
            refreshOnceSettled()
            return failures
        }
    }

    /// Re-reads the bar and photographs it once the icons Apply moved have settled.
    private func refreshOnceSettled() {
        Task { [weak self] in
            try? await Task.sleep(for: Self.photoSettle)
            await self?.refresh()
        }
    }

    /// The layout edits in Apply's order (shows, hides, moves, the Hidden order), written without
    /// waiting between them, then one wait of at most `applyTimeout` for macOS to show them all.
    /// A shown app is switched on first but placed after the moves, so its neighbours are where
    /// they stay. A switch macOS didn't honour in time is undone; a move it didn't apply is
    /// left to what the bar holds. A move counts as applied once the icon sits between its
    /// `neighbours` in the draft, not just the anchors it was placed by: an icon with no saved
    /// position between those can't be placed around, and that's named. Returns what failed.
    private func applyLayout(_ changes: LayoutChanges, neighbours: [String: (left: MenuBarItem?, right: MenuBarItem?)],
                             hiddenOrder: [BundleID], hiddenBefore: [BundleID]) async -> [Failure] {
        var failures: [Failure] = []
        var shown: [LayoutChanges.Show] = []
        var hid: [BundleID] = []
        var moved: [LayoutChanges.Move] = []
        var placed: [LayoutChanges.Show] = []
        for show in changes.shows {
            do {
                try await controller.show(show.id, waits: false)
                shown.append(show)
            } catch {
                failures.append(Failure(what: "show \(show.id)", error: error))
            }
        }
        for id in changes.hides {
            do {
                try await controller.hide(id, waits: false)
                hid.append(id)
            } catch {
                failures.append(Failure(what: "hide \(id)", error: error))
            }
        }
        for move in changes.moves {
            do {
                try controller.move(move.item, leftNeighbor: move.left, rightNeighbor: move.right)
                moved.append(move)
            } catch {
                failures.append(Failure(what: "move \(move.item.id)", error: error))
            }
        }
        for show in shown {
            do {
                try await controller.place(show.id, leftNeighbor: show.left, rightNeighbor: show.right)
                placed.append(show)
            } catch {
                failures.append(Failure(what: "place \(show.id)", error: error))
            }
        }
        controller.reorderHidden(hiddenOrder)

        // One wait for everything. An app that isn't running draws nothing either way.
        var running: Set<BundleID> = []
        for id in shown.map(\.id) + hid where await controller.isRunning(id) { running.insert(id) }
        let anchors = canAnchor
        func outstanding(_ items: [MenuBarItem])
            -> (hides: [BundleID], shows: [BundleID], unplaced: [BundleID], unmoved: [LayoutChanges.Move]) {
            let drawn = { (id: BundleID) in items.contains { $0.bundleID == id } }
            let unplaced = placed.filter { show in
                running.contains(show.id) && drawn(show.id)
                    && !LayoutRules.isPlaced(show.id, between: show.left, and: show.right, in: items, anchors: anchors)
            }
            let unmoved = moved.filter { move in
                let next = neighbours[move.item.id] ?? (move.left, move.right)
                return !Self.isOrdered(move.item.id, after: next.left?.id, before: next.right?.id, in: items)
            }
            return (hid.filter { running.contains($0) && drawn($0) }, shown.map(\.id).filter { running.contains($0) && !drawn($0) },
                    unplaced.map(\.id), unmoved)
        }
        let deadline = ContinuousClock.now + applyTimeout
        var left = outstanding([])
        var polls = 0
        while true {
            polls += 1
            await controller.refresh()
            left = outstanding(LayoutRules.deduplicated(controller.items))
            let done = left.hides.isEmpty && left.shows.isEmpty && left.unplaced.isEmpty && left.unmoved.isEmpty
            if done || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: Self.applyPoll)
        }
        let written = "shown \(shown.map(\.id)), hidden \(hid), moved \(moved.map(\.item.id)), placed \(placed.map(\.id))"
        let late = "\(left.hides + left.shows + left.unplaced + left.unmoved.map(\.item.id))"
        Self.log.notice("Apply wrote \(written, privacy: .public); \(polls) poll(s); not shown in time: \(late, privacy: .public)")

        // macOS didn't honour these switches: put them back, and the app back in its place in Hidden.
        for id in left.hides {
            try? await controller.show(id, waits: false)
            failures.append(Failure(what: "hide \(id)", error: ControllerError.notHonored(id)))
        }
        for id in left.shows {
            try? await controller.hide(id, waits: false)
            failures.append(Failure(what: "show \(id)", error: ControllerError.notHonored(id)))
        }
        if !left.shows.isEmpty {
            var order = hiddenOrder
            for id in left.shows { order.insert(id, at: min(hiddenBefore.firstIndex(of: id) ?? order.count, order.count)) }
            controller.reorderHidden(order)
        }
        for id in left.unplaced {
            failures.append(Failure(what: "place \(id)", error: LayoutError.moveNotApplied))
        }
        // Next to an icon with no saved position, YeeHaw could only place it near; say so.
        for move in left.unmoved {
            let next = neighbours[move.item.id] ?? (move.left, move.right)
            let unplaceable = [next.left, next.right].contains { $0.map { !anchors($0) } ?? false }
            failures.append(Failure(what: "move \(move.item.id)",
                                    error: unplaceable ? ControllerError.unresolvedNeighbor : LayoutError.moveNotApplied))
        }
        return failures
    }

    enum LayoutError: Error { case moveNotApplied }

    /// Whether `id` sits after `left` and before `right` (nil: no constraint on that side).
    static func isOrdered(_ id: String, after left: String?, before right: String?, in items: [MenuBarItem]) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        if let left, let l = items.firstIndex(where: { $0.id == left }), l >= index { return false }
        if let right, let r = items.firstIndex(where: { $0.id == right }), r <= index { return false }
        return true
    }

    // MARK: Text

    /// One line per failure (the same reason twice reads once), offering "Fix…" for the first
    /// missing grant. Nil for none.
    static func message(for errors: [Error]) -> LayoutMessage? {
        let messages = errors.map(message(for:))
        guard !messages.isEmpty else { return nil }
        var lines: [String] = []
        for text in messages.map(\.text) where !lines.contains(text) { lines.append(text) }
        return LayoutMessage(text: lines.joined(separator: "\n"), grant: messages.lazy.compactMap(\.grant).first)
    }

    static func message(for error: Error) -> LayoutMessage {
        switch error {
        case ControllerError.notHonored(let id):
            LayoutMessage(text: "macOS didn’t update \(AppIdentity.name(of: id)) in time. Try again in a moment.")
        case ControllerError.needsGrant(let file):
            LayoutMessage(text: "YeeHaw needs access to the \(describe(file)) to change the menu bar.", grant: file)
        case ControllerError.notTracked(let id):
            LayoutMessage(text: LayoutView.notHideableYet(AppIdentity.name(of: id)))
        case ControllerError.unresolvedNeighbor:
            LayoutMessage(text: "macOS hasn’t saved a position for an icon there yet, so YeeHaw can’t place it.")
        case ControllerError.malformed(let file):
            LayoutMessage(text: "The \(describe(file)) holds something unexpected, so YeeHaw left it alone.")
        case LayoutError.moveNotApplied:
            LayoutMessage(text: "macOS didn’t apply the new order. The menu bar shows what it kept.")
        default:
            LayoutMessage(text: "That change didn’t go through.")
        }
    }

    /// The file's name as Settings and onboarding give it.
    private static func describe(_ file: GrantedFile) -> String {
        AppPermission(file: file)?.title ?? file.rawValue
    }

    /// A short name: the owning app's, else the item's own label up to its first comma
    /// ("Wi‑Fi, connected, 3 bars" → "Wi‑Fi").
    static func name(of item: MenuBarItem) -> String {
        if let id = item.bundleID { return AppIdentity.name(of: id) }
        let label = item.label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return label.isEmpty ? "Unknown icon" : label
    }

    /// The rows' spring, or none under Reduce Motion.
    static var rowAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)
    }
}
