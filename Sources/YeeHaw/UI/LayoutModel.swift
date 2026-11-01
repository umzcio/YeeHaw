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
    /// Whether "Fix…" (open Settings) would help.
    let offersFix: Bool
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
    private(set) var busy = false
    private(set) var tileStyle: TileStyle = .system
    var message: LayoutMessage?

    @ObservationIgnored let controller: MenuBarController
    @ObservationIgnored let images: IconImageProvider
    @ObservationIgnored let openSettings: () -> Void
    @ObservationIgnored private let sampler = StripColorSampler()
    /// Set by the view while a tile is being dragged; reloads wait until the drag ends, so the
    /// rows don't change under the pointer.
    @ObservationIgnored var isDragging = false
    /// The widest the rows have been since the window opened. Rows never narrow while it's open,
    /// so the window doesn't jump each time an icon is hidden or shown.
    @ObservationIgnored private var widestRow: CGFloat = 0
    /// A reload asked for while an edit was running, done when it ends.
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var refreshing = false

    init(controller: MenuBarController, images: IconImageProvider, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.images = images
        self.openSettings = openSettings
        reload()
    }

    // MARK: Reading

    /// Rebuilds both rows from the controller's last read and saved state.
    func reload() {
        let hiddenIDs = Set(controller.state.hidden)
        let tracked = controller.trackedApps
        bar = LayoutRules.deduplicated(controller.items)
            .filter { item in item.bundleID.map { !hiddenIDs.contains($0) } ?? true }
            .map { item in
                BarTile(item: item,
                        capability: LayoutRules.capability(of: item, own: OwnIconLocator.bundleID, tracked: tracked),
                        name: Self.name(of: item), image: images.image(for: item))
            }
        hidden = controller.state.hidden.map { id in
            HiddenGroup(id: id, name: StatusItemController.name(of: id),
                        icons: images.iconIndices(for: id).map {
                            HiddenGroup.Icon(id: "\(id)#\($0)", image: images.image(for: id, indexInApp: $0))
                        })
        }
    }

    /// Re-reads the bar, photographs what's drawn, samples the bar's colour and rebuilds the rows.
    /// Deferred while an edit is running, since the edit reloads when it ends.
    func refresh() async {
        guard !busy, !isDragging else {
            reloadPending = true
            return
        }
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        await controller.refresh()
        await images.captureIfPermitted(controller.items)
        await sampleBarColour()
        guard !busy, !isDragging else {
            reloadPending = true
            return
        }
        withAnimation(Self.rowAnimation) { reload() }
    }

    /// Call after the Allow list changed on disk and the controller has applied it.
    func allowListChanged() {
        guard !busy, !isDragging else {
            reloadPending = true
            return
        }
        withAnimation(Self.rowAnimation) { reload() }
    }

    /// The rows' width for content `natural` wide, never less than before while the window is open.
    func rowWidth(natural: CGFloat) -> CGFloat {
        widestRow = max(widestRow, natural)
        return widestRow
    }

    /// Call when the window closes: the next opening sizes the rows afresh.
    func windowClosed() {
        widestRow = 0
        message = nil
    }

    /// Call when a drag has ended: applies a reload that waited for it.
    func dragEnded() {
        guard reloadPending, !busy else { return }
        reloadPending = false
        withAnimation(Self.rowAnimation) { reload() }
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
    func move(from: Int, to: Int) {
        guard bar.indices.contains(from), bar[from].capability.canDrag else { return }
        let to = LayoutRules.clampedInsertion(to, in: bar.map(\.item))
        let items = bar.map(\.item)
        guard let neighbors = LayoutRules.moveNeighbors(from: from, to: to, in: items) else { return }
        let tile = bar[from]
        bar = LayoutRules.moved(bar.map(\.item), from: from, to: to).compactMap { item in bar.first { $0.id == item.id } }
        perform("move \(tile.name)") { [controller] in
            try controller.move(tile.item, leftNeighbor: neighbors.left, rightNeighbor: neighbors.right)
            try await self.waitUntilApplied { items in
                Self.isOrdered(tile.item.id, after: neighbors.left?.id, before: neighbors.right?.id, in: items)
            }
        }
    }

    /// Hides the app owning `bar[from]` and puts its group at insertion `at` of the Hidden row.
    func hide(from: Int, at index: Int) {
        guard bar.indices.contains(from), bar[from].capability.canHide, let id = bar[from].item.bundleID else { return }
        let order = LayoutRules.hiddenOrder(controller.state.hidden, placing: id, at: index)
        let name = StatusItemController.name(of: id)
        bar.removeAll { $0.item.bundleID == id }
        let icons = images.iconIndices(for: id)
        hidden = order.map { app in
            hidden.first { $0.id == app } ?? HiddenGroup(
                id: app, name: name,
                icons: icons.map { HiddenGroup.Icon(id: "\(app)#\($0)", image: images.image(for: app, indexInApp: $0)) })
        }
        perform("hide \(name)") { [controller] in
            try await controller.hide(id)
            controller.reorderHidden(order)
        }
    }

    /// Shows a hidden app and, if it doesn't come back at insertion `at` of the Menu Bar row,
    /// places its icons there.
    func show(_ id: BundleID, at index: Int?) {
        guard hidden.contains(where: { $0.id == id }) else { return }
        let items = bar.map(\.item)
        let target = index.map { LayoutRules.showNeighbors(at: LayoutRules.clampedInsertion($0, in: items), in: items) }
        let name = StatusItemController.name(of: id)
        hidden.removeAll { $0.id == id }
        perform("show \(name)") { [controller] in
            try await controller.show(id)
            let drawn = LayoutRules.deduplicated(controller.items)
            guard let target, !LayoutRules.isPlaced(id, between: target.left, and: target.right, in: drawn)
            else { return }
            // Place the app's icons left to right, each just right of the one before.
            var left = target.left
            for item in drawn.filter({ $0.bundleID == id }) {
                try controller.move(item, leftNeighbor: left, rightNeighbor: target.right)
                left = item
            }
            try await self.waitUntilApplied { items in
                LayoutRules.isPlaced(id, between: target.left, and: target.right, in: items)
            }
        }
    }

    /// Moves the hidden app `id` to insertion `at` of the Hidden row (the strip's order).
    func reorderHidden(_ id: BundleID, at index: Int) {
        let order = LayoutRules.hiddenOrder(hidden.map(\.id), placing: id, at: index)
        guard order != hidden.map(\.id) else { return }
        hidden = order.compactMap { app in hidden.first { $0.id == app } }
        controller.reorderHidden(order)
    }

    /// Runs one edit: marks the window busy, shows any failure inline, and finally rebuilds the
    /// rows from what the controller and the bar really hold.
    private func perform(_ what: String, _ edit: @escaping @MainActor () async throws -> Void) {
        busy = true
        message = nil
        Task {
            do {
                try await edit()
            } catch {
                Self.log.error("Layout could not \(what, privacy: .public): \(error, privacy: .public)")
                withAnimation(Self.rowAnimation) { message = Self.message(for: error) }
            }
            busy = false
            reloadPending = false
            await controller.refresh()
            await images.captureIfPermitted(controller.items)
            withAnimation(Self.rowAnimation) { reload() }
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
            LayoutMessage(text: "macOS didn’t update \(StatusItemController.name(of: id)) in time. Try again in a moment.",
                          offersFix: false)
        case ControllerError.needsGrant(let file):
            LayoutMessage(text: "YeeHaw needs access to macOS’s \(describe(file)) to change the menu bar.", offersFix: true)
        case ControllerError.notTracked(let id):
            LayoutMessage(text: "\(StatusItemController.name(of: id)) can’t be hidden yet. macOS hasn’t listed it in its menu bar settings.",
                          offersFix: false)
        case ControllerError.unresolvedNeighbor:
            LayoutMessage(text: "macOS hasn’t saved a position for an icon there yet, so YeeHaw can’t place it.",
                          offersFix: false)
        case ControllerError.malformed(let file):
            LayoutMessage(text: "macOS’s \(describe(file)) holds something unexpected, so YeeHaw left it alone.",
                          offersFix: false)
        case LayoutError.moveNotApplied:
            LayoutMessage(text: "macOS didn’t apply the new order. The menu bar shows what it kept.", offersFix: false)
        default:
            LayoutMessage(text: "That change didn’t go through.", offersFix: false)
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
