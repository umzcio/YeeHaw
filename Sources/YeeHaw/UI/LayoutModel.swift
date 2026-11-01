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

/// The layout window's state and its edits, which go through `MenuBarController`. Edits update
/// the rows at once and then follow the real bar: after a move the row keeps the new order until
/// macOS has applied it (or a timeout says it didn't).
@MainActor @Observable
final class LayoutModel {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "layout")
    /// How long to wait for macOS to apply a move before showing what the bar really holds.
    static let moveSettleTimeout: Duration = .seconds(5)
    static let moveSettlePoll: Duration = .milliseconds(250)

    private(set) var bar: [BarTile] = []
    private(set) var hidden: [HiddenGroup] = []
    /// True from the start of an edit until the rows show what the bar holds after it. Drags and
    /// other edits wait for it.
    private(set) var busy = false
    /// A spacing Apply is restarting apps: their items come and go, so edits wait for it too.
    var spacingBusy = false
    /// Drags and edits wait while either is under way.
    var editsLocked: Bool { busy || spacingBusy }
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
    @ObservationIgnored private let sampler = StripColorSampler()
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
    /// A rebuild of the rows from the controller, asked for while an edit or a drag was running.
    @ObservationIgnored private var reloadPending = false
    /// A re-read of the bar, asked for while an edit, a drag or another re-read was running.
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

    // MARK: Reading

    /// Rebuilds both rows from the controller's last read and saved state.
    func reload() {
        let hiddenIDs = Set(controller.state.hidden)
        let tracked = controller.trackedApps
        images.noteDrawn(controller.items)
        withoutPositions = controller.itemsWithoutPositions()
        bar = LayoutRules.deduplicated(controller.items)
            .filter { item in item.bundleID.map { !hiddenIDs.contains($0) } ?? true }
            .map { item in
                BarTile(item: item,
                        capability: LayoutRules.capability(of: item, own: OwnIconLocator.bundleID, tracked: tracked,
                                                           appleMovable: !withoutPositions.contains(item.id)),
                        name: Self.name(of: item), image: images.image(for: item))
            }
        hidden = controller.state.hidden.map { id in
            HiddenGroup(id: id, name: StatusItemController.name(of: id),
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
    /// Asked for while an edit, a drag or another re-read is running, it runs once that ends.
    func refresh() async {
        guard !busy, !isDragging, !refreshing else {
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
            guard !busy, !isDragging else {
                // The re-read is stale by the time the edit or drag ends; read again then.
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

    /// Call when the window closes: the next opening sizes the rows afresh, and any drag ends.
    func windowClosed() {
        widestRow = 0
        message = nil
        showsFocusRing = false
        closes += 1
        dragEnded()
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

    /// Rebuilds the rows now, or once the edit or drag under way has ended.
    private func reloadWhenIdle() {
        guard !busy, !isDragging else {
            reloadPending = true
            return
        }
        reloadPending = false
        withAnimation(Self.rowAnimation) { reload() }
    }

    /// Runs what waited for an edit or a drag to end.
    private func catchUp() {
        guard !busy, !isDragging else { return }
        if refreshPending {
            Task { await refresh() }
        } else if reloadPending {
            reloadWhenIdle()
        }
    }

    private func sampleBarColour() async {
        guard let screen = NSScreen.screens.first, let display = StripColorSampler.displayID(of: screen) else { return }
        let height = max(screen.frame.maxY - screen.visibleFrame.maxY, NSStatusBar.system.thickness)
        if case .sampled(let fill) = await sampler.sample(display: display, barHeight: height) {
            tileStyle = .bar(fill: fill, ink: StripColor.ink(for: fill))
        } else if let kept = sampler.cached(for: display) {
            tileStyle = .bar(fill: kept, ink: StripColor.ink(for: kept))
        } else {
            tileStyle = .system
        }
    }

    // MARK: Edits

    /// Moves `bar[from]` to insertion `to` of the Menu Bar row.
    @discardableResult
    func move(from: Int, to: Int) -> Task<Void, Never>? {
        guard !editsLocked, bar.indices.contains(from), bar[from].capability.canDrag else { return nil }
        let to = LayoutRules.clampedInsertion(to, in: bar.map(\.item))
        let items = bar.map(\.item)
        guard let neighbors = LayoutRules.moveNeighbors(from: from, to: to, in: items, anchors: canAnchor) else { return nil }
        let tile = bar[from]
        bar = LayoutRules.moved(bar.map(\.item), from: from, to: to).compactMap { item in bar.first { $0.id == item.id } }
        return perform("move \(tile.name)", announcing: "Moved \(tile.name)") { [controller] in
            try controller.move(tile.item, leftNeighbor: neighbors.left, rightNeighbor: neighbors.right)
            try await self.waitUntilApplied { items in
                Self.isOrdered(tile.item.id, after: neighbors.left?.id, before: neighbors.right?.id, in: items)
            }
        }
    }

    /// Hides the app owning `bar[from]` and puts its group at insertion `at` of the Hidden row.
    @discardableResult
    func hide(from: Int, at index: Int) -> Task<Void, Never>? {
        guard !editsLocked, bar.indices.contains(from), bar[from].capability.canHide,
              let id = bar[from].item.bundleID else { return nil }
        let order = LayoutRules.hiddenOrder(hidden.map(\.id), placing: id, at: index)
        let name = StatusItemController.name(of: id)
        // The group gets a tile per icon the app draws right now.
        images.noteDrawn(controller.items)
        bar.removeAll { $0.item.bundleID == id }
        let icons = images.iconIndices(for: id)
        hidden = order.map { app in
            hidden.first { $0.id == app } ?? HiddenGroup(
                id: app, name: name,
                icons: icons.map { HiddenGroup.Icon(id: "\(app)#\($0)", image: images.image(for: app, indexInApp: $0)) })
        }
        return perform("hide \(name)", announcing: "Hid \(name)") { [controller] in
            try await controller.hide(id)
            // The Hidden row as it is now: other edits wait while this one runs.
            controller.reorderHidden(self.hidden.map(\.id))
        }
    }

    /// Shows a hidden app and, if it doesn't come back at insertion `at` of the Menu Bar row,
    /// places its icons there.
    @discardableResult
    func show(_ id: BundleID, at index: Int?) -> Task<Void, Never>? {
        guard !editsLocked, hidden.contains(where: { $0.id == id }) else { return nil }
        let items = bar.map(\.item)
        let target = index.map {
            LayoutRules.showNeighbors(at: LayoutRules.clampedInsertion($0, in: items), in: items, anchors: canAnchor)
        }
        let anchors = canAnchor
        let name = StatusItemController.name(of: id)
        hidden.removeAll { $0.id == id }
        return perform("show \(name)", announcing: "\(name) is back in the menu bar") { [controller] in
            try await controller.show(id)
            let drawn = LayoutRules.deduplicated(controller.items)
            let own = drawn.filter { $0.bundleID == id }
            // An app that isn't running draws nothing to place; it comes back where macOS puts it.
            guard let target, !own.isEmpty,
                  !LayoutRules.isPlaced(id, between: target.left, and: target.right, in: drawn, anchors: anchors)
            else { return }
            // Place the app's icons left to right, each just right of the one before.
            var left = target.left
            for item in own {
                try controller.move(item, leftNeighbor: left, rightNeighbor: target.right)
                left = item
            }
            try await self.waitUntilApplied { items in
                LayoutRules.isPlaced(id, between: target.left, and: target.right, in: items, anchors: anchors)
            }
        }
    }

    /// Moves the hidden app `id` to insertion `at` of the Hidden row (the strip's order).
    func reorderHidden(_ id: BundleID, at index: Int) {
        guard !editsLocked else { return }
        let order = LayoutRules.hiddenOrder(hidden.map(\.id), placing: id, at: index)
        guard order != hidden.map(\.id) else { return }
        hidden = order.compactMap { app in hidden.first { $0.id == app } }
        controller.reorderHidden(order)
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

    /// Runs one edit: marks the window busy, shows any failure inline, and finally rebuilds the
    /// rows from what the controller and the bar really hold. The window stays busy until then,
    /// so no drag or other edit starts on rows that are about to change.
    private func perform(_ what: String, announcing done: String,
                         _ edit: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        busy = true
        message = nil
        return Task {
            var failed = false
            do {
                try await edit()
            } catch {
                failed = true
                Self.log.error("Layout could not \(what, privacy: .public): \(error, privacy: .public)")
                withAnimation(Self.rowAnimation) { message = Self.message(for: error) }
            }
            await controller.refresh()
            await images.captureIfPermitted(controller.items)
            busy = false
            refreshPending = false
            reloadPending = true
            reloadWhenIdle()
            if !failed { AccessibilityNotification.Announcement(done).post() }
        }
    }

    /// Re-reads the bar until `applied` holds for it, for at most `moveSettleTimeout`. MenuBarAgent
    /// applies a layout write within a few seconds.
    private func waitUntilApplied(_ applied: ([MenuBarItem]) -> Bool) async throws {
        let deadline = ContinuousClock.now + Self.moveSettleTimeout
        while true {
            await controller.refresh()
            if applied(LayoutRules.deduplicated(controller.items)) { return }
            guard ContinuousClock.now < deadline else { throw LayoutError.moveNotApplied }
            try await Task.sleep(for: Self.moveSettlePoll)
        }
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

    static func message(for error: Error) -> LayoutMessage {
        switch error {
        case ControllerError.notHonored(let id):
            LayoutMessage(text: "macOS didn’t update \(StatusItemController.name(of: id)) in time. Try again in a moment.")
        case ControllerError.needsGrant(let file):
            LayoutMessage(text: "YeeHaw needs access to macOS’s \(describe(file)) to change the menu bar.", grant: file)
        case ControllerError.notTracked(let id):
            LayoutMessage(text: "\(StatusItemController.name(of: id)) can’t be hidden yet. macOS hasn’t listed it in its menu bar settings.")
        case ControllerError.unresolvedNeighbor:
            LayoutMessage(text: "macOS hasn’t saved a position for an icon there yet, so YeeHaw can’t place it.")
        case ControllerError.malformed(let file):
            LayoutMessage(text: "macOS’s \(describe(file)) holds something unexpected, so YeeHaw left it alone.")
        case LayoutError.moveNotApplied:
            LayoutMessage(text: "macOS didn’t apply the new order. The menu bar shows what it kept.")
        default:
            LayoutMessage(text: "That change didn’t go through.")
        }
    }

    private static func describe(_ file: GrantedFile) -> String {
        switch file {
        case .allowList: "menu bar settings file"
        case .positions: "menu bar layout file"
        }
    }

    /// A short name: the owning app's, else the item's own label up to its first comma
    /// ("Wi‑Fi, connected, 3 bars" → "Wi‑Fi").
    static func name(of item: MenuBarItem) -> String {
        if let id = item.bundleID { return StatusItemController.name(of: id) }
        let label = item.label.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return label.isEmpty ? "Unknown icon" : label
    }

    /// The rows' spring, or none under Reduce Motion.
    static var rowAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15)
    }
}
