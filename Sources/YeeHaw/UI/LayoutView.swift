import AppKit
import SwiftUI
import YeeHawCore

/// A drag in progress, from pickup until the tile has settled into its new place.
struct LayoutDrag {
    enum Source: Equatable {
        case bar(String)
        case hidden(BundleID)
    }

    typealias Target = LayoutRules.DropTarget

    let source: Source
    /// The dragged tile's (or group's) index in its row at pickup.
    let index: Int
    /// The frame key of the dragged tile or group, and its frame at pickup.
    let key: String
    let origin: CGRect
    /// The pointer's offset from the dragged view's centre at pickup.
    let grab: CGSize
    /// A Menu Bar tile's glyph.
    let image: NSImage?
    /// The app's icons as a hidden group: the dragged group itself, or every tile of the dragged
    /// Menu Bar tile's app (they all go into Hidden together).
    let group: HiddenGroup
    /// Frame keys of the dragged tile's app's other Menu Bar tiles.
    let siblings: Set<String>
    /// Why a Menu Bar tile can't go into Hidden, if it can't.
    let refusal: HideRefusal?
    /// The rows' tile frames (model order) and row frames at pickup. Fixed for the whole drag, so
    /// tiles making room never move the insertion point.
    let barFrames: [CGRect]
    let hiddenFrames: [CGRect]
    let barRow: CGRect
    let hiddenRow: CGRect
    /// How wide the slot the held tile needs is, over each row.
    let barWidth: CGFloat
    let hiddenWidth: CGFloat
    var location: CGPoint
    var target: Target?
    var lifted = false
    /// The floating copy shows the whole app (held over Hidden, which takes all its icons).
    var showsGroup = false
    /// Dropped, cancelled or abandoned: from here on the tile only settles.
    var dropped = false
    /// The frame the tile springs to, and the key of the view it becomes.
    var settleFrame: CGRect?
    var settleKey: String?
    /// Fades the tile out as it settles (it lands where nothing is drawn yet).
    var fadesOnSettle = false

    var center: CGPoint {
        CGPoint(x: location.x - grab.width, y: location.y - grab.height)
    }

    var ruleSource: LayoutRules.DropSource {
        switch source {
        case .bar: .bar(index)
        case .hidden: .hidden(index)
        }
    }

    /// The held tile's index in `row` when it's from that row.
    func from(_ row: LayoutRules.DropRow) -> Int? {
        switch (source, row) {
        case (.bar, .bar), (.hidden, .hidden): index
        default: nil
        }
    }

    /// The insertion the tiles of `row` make room at, if the held tile is over it.
    func insertion(in row: LayoutRules.DropRow) -> Int? {
        guard !dropped else { return nil }
        switch (target, row) {
        case (.bar(let i)?, .bar), (.hidden(let i)?, .hidden): return i
        default: return nil
        }
    }

    var isRefused: Bool {
        if case .refused = target { true } else { false }
    }
}

/// Frames of tiles, groups and rows in the window's "layout" coordinate space.
private struct FrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    func reportFrame(_ key: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: FrameKey.self, value: [key: proxy.frame(in: .named(LayoutView.space))])
            }
        }
    }
}

/// The layout window's content (mockup B): a Menu Bar row and a Hidden row of icon tiles.
struct LayoutView: View {
    static let space = "layout"
    static let barRowKey = "row:bar"
    static let hiddenRowKey = "row:hidden"

    let model: LayoutModel
    let spacing: SpacingModel

    @State private var frames: [String: CGRect] = [:]
    @State private var drag: LayoutDrag?
    /// True while a drag gesture is live. It resets even when the gesture is cancelled without an
    /// end (its view went away), which `abandonDrag` turns into a spring back.
    @GestureState private var gestureLive = false
    /// A gesture whose drag was cancelled (Esc) while the button is still down: it mustn't start
    /// another drag before it ends.
    @State private var spentGesture = false
    @FocusState private var focus: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func barKey(_ id: String) -> String { "bar:\(id)" }
    static func hiddenKey(_ id: BundleID) -> String { "hidden:\(id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("Menu Bar", busy: model.busy) { barRow }
                .padding(.bottom, 18)
            section("Hidden", busy: false) { hiddenRow }
            footnote
                .frame(width: rowWidth, alignment: .topLeading)
                .padding(.top, 12)
            if let message = model.message {
                MessageBanner(message: message, width: rowWidth, onFix: model.fix) {
                    withAnimation(LayoutModel.rowAnimation) { model.message = nil }
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Divider()
                .frame(width: rowWidth)
                .padding(.vertical, 20)
            SpacingSection(model: spacing, bar: model.bar, style: model.tileStyle, width: rowWidth,
                           layoutBusy: model.busy)
        }
        .padding(.horizontal, LayoutMetrics.windowPadding)
        .padding(.top, 6)
        .padding(.bottom, LayoutMetrics.windowPadding)
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(FrameKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) { dragOverlay }
        .onExitCommand { cancelDrag() }
        .onChange(of: model.dragCancels) { cancelDrag() }
        .onChange(of: gestureLive) { _, live in
            // After the gesture's own end has run: only a gesture that ended without one is left.
            if !live {
                spentGesture = false
                DispatchQueue.main.async { abandonDrag() }
            }
        }
        .onChange(of: model.closes) {
            drag = nil
            focus = nil
            NSCursor.arrow.set()
        }
        .onAppear { focus = nil }
        .fixedSize()
    }

    /// How to use the window, or, while a tile that can't be hidden is over the Hidden row, why.
    /// Both take the same two lines, so nothing below moves.
    private var footnote: some View {
        ZStack(alignment: .topLeading) {
            Text("Drag icons to reorder them, or between rows to hide and show them. Hidden icons open from the strip when you click YeeHaw.")
                .foregroundStyle(.secondary)
                .opacity(refusal == nil ? 1 : 0)
            if let refusal {
                Label(refusal, systemImage: "nosign")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .transition(.opacity)
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: refusal)
    }

    /// Why the dragged tile can't go into Hidden, while it's over the Hidden row.
    private var refusal: String? {
        guard let drag, !drag.dropped, case .refused(let reason)? = drag.target,
              case .bar(let id) = drag.source, let tile = model.bar.first(where: { $0.id == id }) else { return nil }
        return Self.refusalText(reason, name: tile.name)
    }

    // MARK: Sections and rows

    private func section<Content: View>(_ title: String, busy: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating the menu bar")
                }
            }
            .frame(height: 18)
            content()
        }
    }

    /// Both rows share one width, with room for a slot to open in either during a drag (the
    /// slots' widths match the ones `startDrag` gives the held tile).
    private var rowWidth: CGFloat {
        let shown = model.hidden.map { group in
            LayoutMetrics.span(group.icons.map { LayoutMetrics.tileWidth($0.image) }, spacing: LayoutMetrics.tileSpacing)
        }
        // An app hides as one group of all its tiles.
        var hideable: [String: [CGFloat]] = [:], order: [String] = []
        for tile in model.bar where tile.capability.hideRefusal == nil {
            let app = tile.item.bundleID ?? tile.id
            if hideable[app] == nil { order.append(app) }
            hideable[app, default: []].append(LayoutMetrics.tileWidth(tile.image))
        }
        let hidden = order.map { LayoutMetrics.groupWidth(hideable[$0, default: []]) }
        let natural = LayoutMetrics.rowWidthWithHeadroom(
            bar: model.bar.map { LayoutMetrics.tileWidth($0.image) },
            hidden: model.hidden.map(LayoutMetrics.groupWidth),
            barIncoming: shown, hiddenIncoming: hidden)
        return min(model.rowWidth(natural: natural), model.maxRowWidth)
    }

    private var barRow: some View {
        let from = drag?.from(.bar), to = drag?.insertion(in: .bar)
        let step = (drag?.barWidth ?? 0) + LayoutMetrics.tileSpacing
        return RowWell(width: rowWidth, state: rowState(for: .bar), contentWidth: barContentWidth) {
            HStack(spacing: LayoutMetrics.tileSpacing) {
                ForEach(Array(model.bar.enumerated()), id: \.element.id) { index, tile in
                    barTile(tile)
                        .offset(x: CGFloat(LayoutRules.slotShift(of: index, from: from, to: to)) * step)
                }
            }
        }
        .reportFrame(Self.barRowKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Bar")
    }

    private var hiddenRow: some View {
        let from = drag?.from(.hidden), to = drag?.insertion(in: .hidden)
        let step = (drag?.hiddenWidth ?? 0) + LayoutMetrics.tileSpacing
        return RowWell(width: rowWidth, state: rowState(for: .hidden), contentWidth: hiddenContentWidth) {
            if model.hidden.isEmpty {
                Text("Drag icons here to hide them")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: rowWidth - 2 * LayoutMetrics.rowPadding, height: LayoutMetrics.tileHeight)
                    // Out of the way of the slot and the held tile while anything is over the row.
                    .opacity(isOverHidden ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOverHidden)
            } else {
                HStack(spacing: LayoutMetrics.tileSpacing) {
                    ForEach(Array(model.hidden.enumerated()), id: \.element.id) { index, group in
                        hiddenGroup(group)
                            .offset(x: CGFloat(LayoutRules.slotShift(of: index, from: from, to: to)) * step)
                    }
                }
            }
        }
        .reportFrame(Self.hiddenRowKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hidden")
    }

    private var isOverHidden: Bool {
        guard let drag, !drag.dropped else { return false }
        switch drag.target {
        case .hidden?, .refused?: return true
        default: return false
        }
    }

    private var barContentWidth: CGFloat {
        LayoutMetrics.rowWidth(model.bar.map { LayoutMetrics.tileWidth($0.image) })
    }

    private var hiddenContentWidth: CGFloat {
        LayoutMetrics.rowWidth(model.hidden.map(LayoutMetrics.groupWidth))
    }

    private func rowState(for row: LayoutRules.DropRow) -> RowWellState {
        guard let drag, !drag.dropped else { return .idle }
        switch (row, drag.target) {
        case (.bar, .bar?), (.hidden, .hidden?): return .accepting
        case (.hidden, .refused?): return .refusing
        default: return .idle
        }
    }

    // MARK: Tiles

    private func barTile(_ tile: BarTile) -> some View {
        let key = Self.barKey(tile.id)
        return TileFace(image: tile.image, style: model.tileStyle, dimmed: !tile.capability.canDrag)
            .phase(phase(of: key))
            .focusRing(focus == key && model.showsFocusRing)
            .reportFrame(key)
            .contentShape(RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous))
            .gesture(dragGesture(.bar(tile.id), key: key), including: tile.capability.canDrag && !model.busy ? .all : .none)
            .pointerStyle(tile.capability.canDrag ? .grabIdle : nil)
            // Focusable by click as well as Tab, like the items of a collection; the ring shows
            // only once a key is pressed (`LayoutModel.showsFocusRing`).
            .focusable(true, interactions: .edit)
            .focusEffectDisabled()
            .focused($focus, equals: key)
            .onKeyPress(phases: .down) { press in barKey(press, tile) }
            .help(help(for: tile))
            .contextMenu { barMenu(tile) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.name)
            .accessibilityValue(accessibilityValue(for: tile.capability))
            .accessibilityHint(tile.capability.canDrag ? "Use the actions to move it" : "")
            .modifier(BarTileActions(tile: tile, move: { moveBarTile(tile, by: $0) }, hide: { hideBarTile(tile) }))
    }

    private func hiddenGroup(_ group: HiddenGroup) -> some View {
        let key = Self.hiddenKey(group.id)
        return GroupFace(group: group, style: model.tileStyle)
            .phase(phase(of: key))
            .focusRing(focus == key && model.showsFocusRing,
                       radius: LayoutMetrics.tileRadius + (group.icons.count > 1 ? LayoutMetrics.groupInset : 0))
            .reportFrame(key)
            .contentShape(RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous))
            .gesture(dragGesture(.hidden(group.id), key: key), including: model.busy ? .none : .all)
            .pointerStyle(.grabIdle)
            .focusable(true, interactions: .edit)
            .focusEffectDisabled()
            .focused($focus, equals: key)
            .onKeyPress(phases: .down) { press in hiddenKey(press, group) }
            .help(group.name)
            .contextMenu {
                Button("Show in Menu Bar") { showGroup(group) }
                    .disabled(model.busy)
                Divider()
                Button("Move Left") { moveHiddenGroup(group, by: -1) }
                    .disabled(model.busy || model.hidden.first?.id == group.id)
                Button("Move Right") { moveHiddenGroup(group, by: 1) }
                    .disabled(model.busy || model.hidden.last?.id == group.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.name)
            .accessibilityValue(group.icons.count > 1 ? "Hidden, \(group.icons.count) icons" : "Hidden")
            .accessibilityAction(named: "Show in Menu Bar") { showGroup(group) }
            .accessibilityAction(named: "Move Left") { moveHiddenGroup(group, by: -1) }
            .accessibilityAction(named: "Move Right") { moveHiddenGroup(group, by: 1) }
    }

    @ViewBuilder
    private func barMenu(_ tile: BarTile) -> some View {
        if tile.capability.canHide {
            Button("Hide") { hideBarTile(tile) }
                .disabled(model.busy)
            Divider()
        }
        if tile.capability.canDrag {
            Button("Move Left") { moveBarTile(tile, by: -1) }
                .disabled(model.busy || model.bar.first?.id == tile.id)
            Button("Move Right") { moveBarTile(tile, by: 1) }
                .disabled(model.busy || !canMoveRight(tile))
        } else {
            Text(help(for: tile))
        }
    }

    private func phase(of key: String) -> TilePhase {
        guard let drag else { return .resting }
        if drag.dropped { return key == drag.key || key == drag.settleKey ? .invisible : .resting }
        guard key == drag.key || (drag.showsGroup && drag.siblings.contains(key)) else { return .resting }
        // Over a new place in its own row, the row closes up around the slot (`slotShift`).
        switch (drag.source, drag.target) {
        case (.bar, .bar?), (.hidden, .hidden?): return key == drag.key ? .invisible : .socket
        default: return .socket
        }
    }

    private func help(for tile: BarTile) -> String {
        switch tile.capability {
        case .fixed(.pinned): "macOS keeps \(tile.name) in place."
        case .fixed(.unknownOwner): "YeeHaw can’t tell which app this icon belongs to, so it can’t move it."
        case .reorderOnly(.notTrackedYet): "\(tile.name): not hideable yet. macOS hasn’t listed it in its menu bar settings."
        case .reorderOnly(.apple): "\(tile.name) belongs to macOS. It can be moved but not hidden."
        case .reorderOnly(.own), .hideable: tile.name
        }
    }

    private func accessibilityValue(for capability: TileCapability) -> String {
        switch capability {
        case .fixed: "Fixed"
        case .reorderOnly(.notTrackedYet): "Not hideable yet"
        case .reorderOnly, .hideable: ""
        }
    }

    // MARK: Keyboard and actions

    /// Left and Right move the focus; Up and Down switch rows. With Command they move the icon:
    /// Command-Left/Right reorder, Command-Down hides.
    private func barKey(_ press: KeyPress, _ tile: BarTile) -> KeyPress.Result {
        guard let index = model.bar.firstIndex(where: { $0.id == tile.id }) else { return .ignored }
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .leftArrow where command: moveBarTile(tile, by: -1)
        case .rightArrow where command: moveBarTile(tile, by: 1)
        case .downArrow where command: hideBarTile(tile)
        case .leftArrow: focus = model.bar[safe: index - 1].map { Self.barKey($0.id) } ?? focus
        case .rightArrow: focus = model.bar[safe: index + 1].map { Self.barKey($0.id) } ?? focus
        case .downArrow: focus = model.hidden.first.map { Self.hiddenKey($0.id) } ?? focus
        default: return .ignored
        }
        return .handled
    }

    /// Like `barKey`; Command-Up shows the app.
    private func hiddenKey(_ press: KeyPress, _ group: HiddenGroup) -> KeyPress.Result {
        guard let index = model.hidden.firstIndex(where: { $0.id == group.id }) else { return .ignored }
        let command = press.modifiers.contains(.command)
        switch press.key {
        case .leftArrow where command: moveHiddenGroup(group, by: -1)
        case .rightArrow where command: moveHiddenGroup(group, by: 1)
        case .upArrow where command: showGroup(group)
        case .leftArrow: focus = model.hidden[safe: index - 1].map { Self.hiddenKey($0.id) } ?? focus
        case .rightArrow: focus = model.hidden[safe: index + 1].map { Self.hiddenKey($0.id) } ?? focus
        case .upArrow: focus = model.bar.first.map { Self.barKey($0.id) } ?? focus
        default: return .ignored
        }
        return .handled
    }

    private func canMoveRight(_ tile: BarTile) -> Bool {
        guard let index = model.bar.firstIndex(where: { $0.id == tile.id }) else { return false }
        return LayoutRules.clampedInsertion(index + 2, in: model.bar.map(\.item)) == index + 2
    }

    private func moveBarTile(_ tile: BarTile, by step: Int) {
        guard tile.capability.canDrag, !model.busy, let index = model.bar.firstIndex(where: { $0.id == tile.id }) else { return }
        let to = step < 0 ? index - 1 : index + 2
        guard to >= 0, LayoutRules.clampedInsertion(to, in: model.bar.map(\.item)) == to else { return }
        withAnimation(LayoutModel.rowAnimation) { _ = model.move(from: index, to: to) }
    }

    /// Hides the tile's app; a focused tile hands the focus to the app's new hidden group.
    private func hideBarTile(_ tile: BarTile) {
        guard tile.capability.canHide, !model.busy, let app = tile.item.bundleID,
              let index = model.bar.firstIndex(where: { $0.id == tile.id }) else { return }
        let hadFocus = focus == Self.barKey(tile.id)
        withAnimation(LayoutModel.rowAnimation) { _ = model.hide(from: index, at: model.hidden.count) }
        if hadFocus { focus = Self.hiddenKey(app) }
    }

    /// Shows the group's app; a focused group hands the focus to its neighbour in Hidden, or the
    /// first Menu Bar tile when it was the last.
    private func showGroup(_ group: HiddenGroup) {
        guard !model.busy, let index = model.hidden.firstIndex(where: { $0.id == group.id }) else { return }
        let hadFocus = focus == Self.hiddenKey(group.id)
        let next = model.hidden[safe: index + 1] ?? model.hidden[safe: index - 1]
        withAnimation(LayoutModel.rowAnimation) { _ = model.show(group.id, at: nil) }
        if hadFocus { focus = next.map { Self.hiddenKey($0.id) } ?? model.bar.first.map { Self.barKey($0.id) } }
    }

    private func moveHiddenGroup(_ group: HiddenGroup, by step: Int) {
        guard !model.busy, let index = model.hidden.firstIndex(where: { $0.id == group.id }) else { return }
        let to = step < 0 ? index - 1 : index + 2
        guard to >= 0, to <= model.hidden.count else { return }
        withAnimation(LayoutModel.rowAnimation) { model.reorderHidden(group.id, at: to) }
    }

    // MARK: Dragging

    private func dragGesture(_ source: LayoutDrag.Source, key: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .updating($gestureLive) { _, live, _ in live = true }
            .onChanged { value in
                if drag == nil, !spentGesture { begin(source, key: key, at: value.startLocation) }
                guard var current = drag, current.key == key, !current.dropped else { return }
                current.location = value.location
                current.target = target(for: value.location, in: current)
                (current.isRefused ? NSCursor.operationNotAllowed : NSCursor.closedHand).set()
                if current.target != drag?.target {
                    if case .hidden? = current.target { current.showsGroup = true } else { current.showsGroup = false }
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.2)) { drag = current }
                } else {
                    drag = current
                }
            }
            .onEnded { _ in
                guard let current = drag, current.key == key, !current.dropped else { return }
                drop(current)
            }
    }

    private func begin(_ source: LayoutDrag.Source, key: String, at start: CGPoint) {
        guard !model.busy, let origin = frames[key] else { return }
        let barFrames = model.bar.compactMap { frames[Self.barKey($0.id)] }
        let hiddenFrames = model.hidden.compactMap { frames[Self.hiddenKey($0.id)] }
        // Frames lag the model by a layout pass; a drag needs all of them.
        guard barFrames.count == model.bar.count, hiddenFrames.count == model.hidden.count else { return }
        let index: Int, image: NSImage?, group: HiddenGroup, siblings: [BarTile], refusal: HideRefusal?
        switch source {
        case .bar(let id):
            guard let i = model.bar.firstIndex(where: { $0.id == id }) else { return }
            let tile = model.bar[i]
            let app = tile.item.bundleID
            let tiles = app.map { app in model.bar.filter { $0.item.bundleID == app } } ?? [tile]
            (index, image, refusal) = (i, tile.image, tile.capability.hideRefusal)
            siblings = tiles.filter { $0.id != id }
            group = HiddenGroup(id: app ?? tile.id, name: tile.name,
                                icons: tiles.map { HiddenGroup.Icon(id: $0.id, image: $0.image) })
        case .hidden(let app):
            guard let i = model.hidden.firstIndex(where: { $0.id == app }) else { return }
            (index, image, refusal, siblings, group) = (i, nil, nil, [], model.hidden[i])
        }
        let iconSpan = LayoutMetrics.span(group.icons.map { LayoutMetrics.tileWidth($0.image) },
                                          spacing: LayoutMetrics.tileSpacing)
        focus = nil
        model.message = nil
        model.isDragging = true
        drag = LayoutDrag(
            source: source, index: index, key: key, origin: origin,
            grab: CGSize(width: start.x - origin.midX, height: start.y - origin.midY),
            image: image, group: group, siblings: Set(siblings.map { Self.barKey($0.id) }), refusal: refusal,
            barFrames: barFrames, hiddenFrames: hiddenFrames,
            barRow: frames[Self.barRowKey] ?? .zero, hiddenRow: frames[Self.hiddenRowKey] ?? .zero,
            barWidth: image == nil ? iconSpan : origin.width,
            hiddenWidth: image == nil ? origin.width : LayoutMetrics.groupWidth(group),
            location: start)
        NSCursor.closedHand.set()
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.35)) { drag?.lifted = true }
    }

    /// Where a drop at `point` would go, or nil for nowhere (outside the rows, or back where it was).
    private func target(for point: CGPoint, in drag: LayoutDrag) -> LayoutDrag.Target? {
        let reach: (CGRect) -> CGRect = { $0.insetBy(dx: -24, dy: -14) }
        let row: LayoutRules.DropRow? = reach(drag.barRow).contains(point) ? .bar
            : reach(drag.hiddenRow).contains(point) ? .hidden : nil
        let frames = row == .bar ? drag.barFrames : drag.hiddenFrames
        let insertion = LayoutRules.insertionIndex(forX: Double(point.x), midpoints: frames.map { Double($0.midX) })
        return LayoutRules.dropTarget(over: row, insertion: insertion, source: drag.ruleSource,
                                      bar: model.bar.map(\.item), refusal: drag.refusal, anchors: model.canAnchor)
    }

    private func drop(_ dropped: LayoutDrag) {
        var settled = dropped
        settled.target = nil
        settled.dropped = true
        // The rows close up and change in one animation: the tiles that made room are already
        // where the new order puts them, so nothing jumps.
        let animation = LayoutModel.rowAnimation
        switch (dropped.source, dropped.target) {
        case (.bar(let id), .bar(let index)?):
            settled.settleKey = Self.barKey(id)
            withAnimation(animation) {
                drag = settled
                if let from = model.bar.firstIndex(where: { $0.id == id }) { model.move(from: from, to: index) }
            }
        case (.bar(let id), .hidden(let index)?):
            guard let from = model.bar.firstIndex(where: { $0.id == id }),
                  let app = model.bar[from].item.bundleID else { return cancelDrag() }
            settled.settleKey = Self.hiddenKey(app)
            withAnimation(animation) {
                drag = settled
                model.hide(from: from, at: index)
            }
        case (.hidden(let app), .hidden(let index)?):
            settled.settleKey = Self.hiddenKey(app)
            withAnimation(animation) {
                drag = settled
                model.reorderHidden(app, at: index)
            }
        case (.hidden(let app), .bar(let index)?):
            // The icons come back once macOS draws them; the tile fades into its slot meanwhile.
            settled.settleFrame = slotFrame(for: dropped.target, in: dropped) ?? dropped.origin
            settled.fadesOnSettle = true
            settled.showsGroup = false
            withAnimation(animation) {
                drag = settled
                model.show(app, at: index)
            }
        default:
            return cancelDrag()
        }
        // The new layout's frames arrive with the next layout pass.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            settle()
        }
    }

    /// Springs the floating tile into its new place, then ends the drag. `start` is the drag to
    /// settle when it isn't in `drag` yet, so its other changes animate with the spring.
    private func settle(_ start: LayoutDrag? = nil) {
        guard var current = start ?? drag else { return }
        if current.settleFrame == nil {
            current.settleFrame = current.settleKey.flatMap { frames[$0] } ?? current.origin
        }
        let frame = current.settleFrame ?? current.origin
        // Keep the frame's centre but the tile's own size: a group lands centred on its slot.
        current.location = CGPoint(x: frame.midX + current.grab.width, y: frame.midY + current.grab.height)
        current.lifted = false
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.12)) { drag = current } completion: { finish() }
        } else {
            withAnimation(.spring(duration: 0.38, bounce: 0.22)) { drag = current } completion: { finish() }
        }
    }

    private func finish() {
        drag = nil
        NSCursor.arrow.set()
        model.dragEnded()
    }

    /// Esc, or a drop that goes nowhere: the tile springs straight back to where it came from.
    /// The gesture's later end is ignored.
    private func cancelDrag() {
        guard var current = drag, !current.dropped else { return }
        current.target = nil
        current.dropped = true
        current.showsGroup = false
        current.settleFrame = current.origin
        current.settleKey = current.key
        if gestureLive { spentGesture = true }
        settle(current)
    }

    /// The gesture went away without ending (its view was removed): treated as a cancel, so the
    /// drag never stays stuck.
    private func abandonDrag() {
        guard let current = drag, !current.dropped else { return }
        cancelDrag()
    }

    // MARK: Drag overlay

    @ViewBuilder
    private var dragOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let drag, !drag.dropped, let slot = slotFrame(for: drag.target, in: drag) {
                GhostSlot(size: slot.size)
                    .position(x: slot.midX, y: slot.midY)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if let drag {
                floatingTile(drag)
                    .position(drag.center)
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func floatingTile(_ drag: LayoutDrag) -> some View {
        let lift = drag.lifted && !reduceMotion
        let refused = drag.isRefused
        let radius = LayoutMetrics.tileRadius + (drag.showsGroup || drag.image == nil ? LayoutMetrics.groupInset : 0)
        Group {
            if let image = drag.image, !drag.showsGroup {
                TileFace(image: image, style: model.tileStyle, dimmed: false)
            } else {
                GroupFace(group: drag.group, style: model.tileStyle)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: radius + 1, style: .continuous)
                .strokeBorder(refused ? Color.secondary.opacity(0.5) : Color.accentColor, lineWidth: refused ? 1 : 2)
                .padding(-1)
                .opacity(drag.lifted ? 1 : 0)
        }
        .overlay(alignment: .topTrailing) {
            if refused {
                Image(systemName: "nosign")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color(nsColor: .systemGray), in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1) }
                    .offset(x: 7, y: -7)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .opacity(refused ? 0.85 : 1)
        .scaleEffect(lift ? LayoutMetrics.liftScale : 1)
        .rotationEffect(.degrees(lift ? LayoutMetrics.liftRotation : 0))
        .shadow(color: .black.opacity(drag.lifted ? 0.28 : 0), radius: drag.lifted ? 12 : 0, y: drag.lifted ? 8 : 0)
        .opacity(drag.fadesOnSettle && !drag.lifted ? 0 : 1)
    }

    /// The slot the held tile would land in for `target`: the room the row's tiles make
    /// (`LayoutRules.slotShift`), at the tile's height, centred in the row.
    private func slotFrame(for target: LayoutDrag.Target?, in drag: LayoutDrag) -> CGRect? {
        let row: LayoutRules.DropRow, insertion: Int
        switch target {
        case .bar(let i)?: (row, insertion) = (.bar, i)
        case .hidden(let i)?: (row, insertion) = (.hidden, i)
        default: return nil
        }
        let rowFrame = row == .bar ? drag.barRow : drag.hiddenRow
        let spans = (row == .bar ? drag.barFrames : drag.hiddenFrames).map { (minX: $0.minX, maxX: $0.maxX) }
        let width = row == .bar ? drag.barWidth : drag.hiddenWidth
        let x = LayoutGeometry.slotMinX(insertion: insertion, from: drag.from(row), spans: spans, width: width,
                                        spacing: LayoutMetrics.tileSpacing,
                                        rowStart: rowFrame.minX + LayoutMetrics.rowPadding)
        let clamped = min(x, rowFrame.maxX - LayoutMetrics.rowPadding - width)
        return CGRect(x: clamped, y: rowFrame.midY - LayoutMetrics.tileHeight / 2,
                      width: width, height: LayoutMetrics.tileHeight)
    }

    static func refusalText(_ refusal: HideRefusal, name: String) -> String {
        switch refusal {
        case .apple: "\(name) belongs to macOS and stays in the menu bar."
        case .own: "YeeHaw’s own icon stays in the menu bar."
        case .notTrackedYet: "\(name) isn’t hideable yet. macOS hasn’t listed it in its menu bar settings."
        }
    }
}
