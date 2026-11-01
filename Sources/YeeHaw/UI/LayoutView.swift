import AppKit
import SwiftUI
import YeeHawCore

/// Sizes shared by the rows, the tiles and the window.
enum LayoutMetrics {
    static let tileHeight: CGFloat = 34
    static let tileMinWidth: CGFloat = 34
    /// Space either side of a glyph that's wider than the square tile allows.
    static let glyphPadding: CGFloat = 9
    /// Tallest a glyph is drawn; smaller glyphs are never scaled up.
    static let maxGlyphHeight: CGFloat = 18
    static let tileRadius: CGFloat = 8
    static let tileSpacing: CGFloat = 6
    /// Space between an app group's tiles, and the group's backing around them.
    static let groupSpacing: CGFloat = 2
    static let groupInset: CGFloat = 3
    static let rowPadding: CGFloat = 7
    static let rowRadius: CGFloat = tileRadius + rowPadding
    static let rowHeight: CGFloat = tileHeight + 2 * rowPadding
    static let minRowWidth: CGFloat = 460
    static let windowPadding: CGFloat = 20
    /// How far tiles part around the insertion marker.
    static let insertionGap: CGFloat = 12
    static let markerWidth: CGFloat = 3
    static let liftScale: CGFloat = 1.1
    static let liftRotation: Double = -3

    static func glyphSize(_ size: NSSize) -> CGSize {
        guard size.height > maxGlyphHeight, size.height > 0 else { return size }
        return CGSize(width: size.width * maxGlyphHeight / size.height, height: maxGlyphHeight)
    }

    static func tileWidth(_ image: NSImage) -> CGFloat {
        max(tileMinWidth, glyphSize(image.size).width + 2 * glyphPadding)
    }

    static func groupWidth(_ group: HiddenGroup) -> CGFloat {
        let tiles = group.icons.reduce(0) { $0 + tileWidth($1.image) }
            + groupSpacing * CGFloat(max(group.icons.count - 1, 0))
        return group.icons.count > 1 ? tiles + 2 * groupInset : tiles
    }

    /// A row's width for its content: its tiles, the spacing between them and its padding.
    static func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        widths.reduce(0, +) + tileSpacing * CGFloat(max(widths.count - 1, 0)) + 2 * rowPadding
    }
}

/// A drag in progress, from pickup until the tile has settled into its new place.
struct LayoutDrag: Equatable {
    enum Source: Equatable {
        case bar(String)
        case hidden(BundleID)
    }

    enum Target: Equatable {
        case bar(Int)
        case hidden(Int)
        /// Over the Hidden row with a tile that can't be hidden.
        case refused(HideRefusal)
    }

    /// What the floating copy draws. Kept here because the source leaves the model on a drop
    /// between rows.
    enum Face: Equatable {
        case tile(NSImage)
        case group(HiddenGroup)
    }

    let source: Source
    let face: Face
    /// The frame key of the dragged tile or group, and its frame at pickup.
    let key: String
    let origin: CGRect
    /// The pointer's offset from the dragged view's centre at pickup.
    let grab: CGSize
    /// Insertion midpoints and row frames at pickup. Fixed for the whole drag, so tiles parting
    /// around the marker never move the insertion point.
    let barMidpoints: [CGFloat]
    let hiddenMidpoints: [CGFloat]
    let barRow: CGRect
    let hiddenRow: CGRect
    var location: CGPoint
    var target: Target?
    var lifted = false
    var cancelled = false
    /// Set once dropped: the frame the tile springs to, and the key of the view it becomes.
    var settleFrame: CGRect?
    var settleKey: String?
    /// Fades the tile out as it settles (it lands where nothing is drawn yet).
    var fadesOnSettle = false

    var center: CGPoint {
        CGPoint(x: location.x - grab.width, y: location.y - grab.height)
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
    /// The widest the rows may be before they scroll.
    let maxRowWidth: CGFloat

    @State private var frames: [String: CGRect] = [:]
    @State private var drag: LayoutDrag?
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
                MessageBanner(message: message, width: rowWidth, onFix: model.openSettings) {
                    withAnimation(LayoutModel.rowAnimation) { model.message = nil }
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, LayoutMetrics.windowPadding)
        .padding(.top, 6)
        .padding(.bottom, LayoutMetrics.windowPadding)
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(FrameKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) { dragOverlay }
        .onExitCommand { cancelDrag() }
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
        guard let drag, drag.settleFrame == nil, case .refused(let reason)? = drag.target,
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

    private var rowWidth: CGFloat {
        let bar = LayoutMetrics.rowWidth(model.bar.map { LayoutMetrics.tileWidth($0.image) })
        let hidden = LayoutMetrics.rowWidth(model.hidden.map(LayoutMetrics.groupWidth))
        return min(model.rowWidth(natural: max(bar, hidden, LayoutMetrics.minRowWidth)), maxRowWidth)
    }

    private var barRow: some View {
        let parting = barParting
        return RowWell(width: rowWidth, state: rowState(for: .bar), contentWidth: barContentWidth) {
            HStack(spacing: LayoutMetrics.tileSpacing) {
                ForEach(Array(model.bar.enumerated()), id: \.element.id) { index, tile in
                    barTile(tile)
                        .offset(x: parting.map { index >= $0 ? LayoutMetrics.insertionGap / 2 : -LayoutMetrics.insertionGap / 2 } ?? 0)
                }
            }
        }
        .reportFrame(Self.barRowKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Bar")
    }

    private var hiddenRow: some View {
        let parting = hiddenParting
        return RowWell(width: rowWidth, state: rowState(for: .hidden), contentWidth: hiddenContentWidth) {
            if model.hidden.isEmpty {
                Text("Drag icons here to hide them")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: rowWidth - 2 * LayoutMetrics.rowPadding, height: LayoutMetrics.tileHeight)
                    .opacity(drag?.target == .hidden(0) ? 0 : 1)
            } else {
                HStack(spacing: LayoutMetrics.tileSpacing) {
                    ForEach(Array(model.hidden.enumerated()), id: \.element.id) { index, group in
                        hiddenGroup(group)
                            .offset(x: parting.map { index >= $0 ? LayoutMetrics.insertionGap / 2 : -LayoutMetrics.insertionGap / 2 } ?? 0)
                    }
                }
            }
        }
        .reportFrame(Self.hiddenRowKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Hidden")
    }

    private var barContentWidth: CGFloat {
        LayoutMetrics.rowWidth(model.bar.map { LayoutMetrics.tileWidth($0.image) })
    }

    private var hiddenContentWidth: CGFloat {
        LayoutMetrics.rowWidth(model.hidden.map(LayoutMetrics.groupWidth))
    }

    /// The insertion index the bar row's tiles part around, if any.
    private var barParting: Int? {
        if case .bar(let index) = drag?.target, drag?.settleFrame == nil { return index }
        return nil
    }

    private var hiddenParting: Int? {
        if case .hidden(let index) = drag?.target, drag?.settleFrame == nil, !model.hidden.isEmpty { return index }
        return nil
    }

    private enum Row { case bar, hidden }

    private func rowState(for row: Row) -> RowWellState {
        guard let drag, drag.settleFrame == nil, !drag.cancelled else { return .idle }
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
            .focusRing(focus == key)
            .reportFrame(key)
            .contentShape(RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous))
            .gesture(dragGesture(.bar(tile.id), key: key), including: tile.capability.canDrag && !model.busy ? .all : .none)
            .pointerStyle(tile.capability.canDrag ? .grabIdle : nil)
            // Like buttons: in the Tab order only with Keyboard Navigation on, so opening the
            // window doesn't put a focus ring on the first tile.
            .focusable(true, interactions: .activate)
            .focusEffectDisabled()
            .focused($focus, equals: key)
            .onKeyPress(phases: .down) { press in barKey(press, tile) }
            .help(help(for: tile))
            .contextMenu { barMenu(tile) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tile.name)
            .accessibilityValue(accessibilityValue(for: tile.capability))
            .accessibilityHint(tile.capability.canDrag ? "Use the actions to move it" : "")
            .modifier(BarTileActions(model: model, tile: tile, move: { moveBarTile(tile, by: $0) },
                                     hide: { hideBarTile(tile) }))
    }

    private func hiddenGroup(_ group: HiddenGroup) -> some View {
        let key = Self.hiddenKey(group.id)
        return GroupFace(group: group, style: model.tileStyle)
            .phase(phase(of: key))
            .focusRing(focus == key, radius: LayoutMetrics.tileRadius + (group.icons.count > 1 ? LayoutMetrics.groupInset : 0))
            .reportFrame(key)
            .contentShape(RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous))
            .gesture(dragGesture(.hidden(group.id), key: key), including: model.busy ? .none : .all)
            .pointerStyle(.grabIdle)
            // Like buttons: in the Tab order only with Keyboard Navigation on, so opening the
            // window doesn't put a focus ring on the first tile.
            .focusable(true, interactions: .activate)
            .focusEffectDisabled()
            .focused($focus, equals: key)
            .onKeyPress(phases: .down) { press in hiddenKey(press, group) }
            .help(group.name)
            .contextMenu {
                Button("Show in Menu Bar") { model.show(group.id, at: nil) }
                Divider()
                Button("Move Left") { moveHiddenGroup(group, by: -1) }
                    .disabled(model.hidden.first?.id == group.id)
                Button("Move Right") { moveHiddenGroup(group, by: 1) }
                    .disabled(model.hidden.last?.id == group.id)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.name)
            .accessibilityValue(group.icons.count > 1 ? "Hidden, \(group.icons.count) icons" : "Hidden")
            .accessibilityAction(named: "Show in Menu Bar") { model.show(group.id, at: nil) }
            .accessibilityAction(named: "Move Left") { moveHiddenGroup(group, by: -1) }
            .accessibilityAction(named: "Move Right") { moveHiddenGroup(group, by: 1) }
    }

    @ViewBuilder
    private func barMenu(_ tile: BarTile) -> some View {
        if tile.capability.canHide {
            Button("Hide") { hideBarTile(tile) }
            Divider()
        }
        if tile.capability.canDrag {
            Button("Move Left") { moveBarTile(tile, by: -1) }
                .disabled(model.bar.first?.id == tile.id)
            Button("Move Right") { moveBarTile(tile, by: 1) }
                .disabled(!canMoveRight(tile))
        } else {
            Text(help(for: tile))
        }
    }

    private func phase(of key: String) -> TilePhase {
        guard let drag else { return .resting }
        if drag.settleFrame != nil { return key == drag.key || key == drag.settleKey ? .invisible : .resting }
        return key == drag.key ? .socket : .resting
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

    // MARK: Keyboard

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
        case .upArrow where command:
            focus = nil
            model.show(group.id, at: nil)
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
        withAnimation(LayoutModel.rowAnimation) { model.move(from: index, to: to) }
    }

    private func hideBarTile(_ tile: BarTile) {
        guard tile.capability.canHide, !model.busy, let index = model.bar.firstIndex(where: { $0.id == tile.id }) else { return }
        withAnimation(LayoutModel.rowAnimation) { model.hide(from: index, at: model.hidden.count) }
    }

    private func moveHiddenGroup(_ group: HiddenGroup, by step: Int) {
        guard let index = model.hidden.firstIndex(where: { $0.id == group.id }) else { return }
        let to = step < 0 ? index - 1 : index + 2
        guard to >= 0, to <= model.hidden.count else { return }
        withAnimation(LayoutModel.rowAnimation) { model.reorderHidden(group.id, at: to) }
    }

    // MARK: Dragging

    private func dragGesture(_ source: LayoutDrag.Source, key: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil { begin(source, key: key, at: value.startLocation) }
                guard var current = drag, current.key == key, current.settleFrame == nil, !current.cancelled else { return }
                current.location = value.location
                current.target = target(for: value.location, in: current)
                if current.target != drag?.target {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.2)) { drag = current }
                } else {
                    drag = current
                }
            }
            .onEnded { value in
                guard let current = drag, current.key == key, current.settleFrame == nil else { return }
                drop(current)
            }
    }

    private func begin(_ source: LayoutDrag.Source, key: String, at start: CGPoint) {
        guard let origin = frames[key] else { return }
        let face: LayoutDrag.Face
        switch source {
        case .bar(let id):
            guard let tile = model.bar.first(where: { $0.id == id }) else { return }
            face = .tile(tile.image)
        case .hidden(let app):
            guard let group = model.hidden.first(where: { $0.id == app }) else { return }
            face = .group(group)
        }
        focus = nil
        model.message = nil
        model.isDragging = true
        drag = LayoutDrag(
            source: source, face: face, key: key, origin: origin,
            grab: CGSize(width: start.x - origin.midX, height: start.y - origin.midY),
            barMidpoints: model.bar.compactMap { frames[Self.barKey($0.id)]?.midX },
            hiddenMidpoints: model.hidden.compactMap { frames[Self.hiddenKey($0.id)]?.midX },
            barRow: frames[Self.barRowKey] ?? .zero, hiddenRow: frames[Self.hiddenRowKey] ?? .zero,
            location: start)
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.35)) { drag?.lifted = true }
    }

    /// Where a drop at `point` would go, or nil for nowhere (outside the rows, or back where it was).
    private func target(for point: CGPoint, in drag: LayoutDrag) -> LayoutDrag.Target? {
        let reach: (CGRect) -> CGRect = { $0.insetBy(dx: -24, dy: -14) }
        let items = model.bar.map(\.item)
        if reach(drag.barRow).contains(point) {
            let index = LayoutRules.clampedInsertion(
                LayoutRules.insertionIndex(forX: Double(point.x), midpoints: drag.barMidpoints.map(Double.init)), in: items)
            if case .bar(let id) = drag.source, let from = model.bar.firstIndex(where: { $0.id == id }),
               LayoutRules.moveNeighbors(from: from, to: index, in: items) == nil { return nil }
            return .bar(index)
        }
        if reach(drag.hiddenRow).contains(point) {
            if case .bar(let id) = drag.source, let tile = model.bar.first(where: { $0.id == id }),
               let refusal = tile.capability.hideRefusal { return .refused(refusal) }
            let index = LayoutRules.insertionIndex(forX: Double(point.x), midpoints: drag.hiddenMidpoints.map(Double.init))
            if case .hidden(let id) = drag.source, let from = model.hidden.firstIndex(where: { $0.id == id }),
               index == from || index == from + 1 { return nil }
            return .hidden(index)
        }
        return nil
    }

    private func drop(_ dropped: LayoutDrag) {
        var settled = dropped
        settled.target = nil
        // No marker or parting from here on, before the rows change under the old target.
        drag = settled
        let animation = LayoutModel.rowAnimation
        switch (dropped.source, dropped.cancelled ? nil : dropped.target) {
        case (.bar(let id), .bar(let index)?):
            guard let from = model.bar.firstIndex(where: { $0.id == id }) else { return finish() }
            withAnimation(animation) { model.move(from: from, to: index) }
            settled.settleKey = Self.barKey(id)
        case (.bar(let id), .hidden(let index)?):
            guard let from = model.bar.firstIndex(where: { $0.id == id }),
                  let app = model.bar[from].item.bundleID else { return finish() }
            withAnimation(animation) { model.hide(from: from, at: index) }
            settled.settleKey = Self.hiddenKey(app)
        case (.hidden(let app), .hidden(let index)?):
            withAnimation(animation) { model.reorderHidden(app, at: index) }
            settled.settleKey = Self.hiddenKey(app)
        case (.hidden(let app), .bar(let index)?):
            // The icons come back once macOS draws them; the tile fades into the gap meanwhile.
            settled.settleFrame = markerFrame(for: .bar(index), in: dropped) ?? dropped.origin
            settled.fadesOnSettle = true
            withAnimation(animation) { model.show(app, at: index) }
        default:
            settled.settleFrame = dropped.origin
            settled.settleKey = dropped.key
        }
        drag = settled
        // The new layout's frames arrive with the next layout pass.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            settle()
        }
    }

    /// Springs the floating tile into its new place, then ends the drag.
    private func settle() {
        guard var current = drag else { return }
        if current.settleFrame == nil {
            current.settleFrame = current.settleKey.flatMap { frames[$0] } ?? current.origin
        }
        let frame = current.settleFrame!
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
        model.isDragging = false
        model.dragEnded()
    }

    private func cancelDrag() {
        guard var current = drag, current.settleFrame == nil else { return }
        current.cancelled = true
        current.target = nil
        withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) { drag = current }
    }

    // MARK: Drag overlay

    @ViewBuilder
    private var dragOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let drag, let marker = drag.settleFrame == nil ? markerFrame(for: drag.target, in: drag) : nil {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: marker.width, height: marker.height)
                    .position(x: marker.midX, y: marker.midY)
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
        Group {
            switch drag.face {
            case .tile(let image): TileFace(image: image, style: model.tileStyle, dimmed: false)
            case .group(let group): GroupFace(group: group, style: model.tileStyle)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius + 1, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-1)
                .opacity(drag.lifted ? 1 : 0)
        }
        .scaleEffect(lift ? LayoutMetrics.liftScale : 1)
        .rotationEffect(.degrees(lift ? LayoutMetrics.liftRotation : 0))
        .shadow(color: .black.opacity(drag.lifted ? 0.28 : 0), radius: drag.lifted ? 12 : 0, y: drag.lifted ? 8 : 0)
        .opacity(drag.fadesOnSettle && !drag.lifted ? 0 : 1)
    }

    /// Where the insertion marker sits for `target`: centred in the gap the tiles part to make.
    private func markerFrame(for target: LayoutDrag.Target?, in drag: LayoutDrag) -> CGRect? {
        let row: CGRect, keys: [String], index: Int
        switch target {
        case .bar(let i)?:
            (row, keys, index) = (drag.barRow, model.bar.map { Self.barKey($0.id) }, i)
        case .hidden(let i)?:
            (row, keys, index) = (drag.hiddenRow, model.hidden.map { Self.hiddenKey($0.id) }, i)
        default:
            return nil
        }
        // Taller than a lifted tile, so it shows above and below the tile hovering over it.
        let height = LayoutMetrics.rowHeight - 4
        // Frames can lag the model by a layout pass, so a missing one just means no marker yet.
        let slot = min(max(index, 0), keys.count)
        let left = slot > 0 ? frames[keys[slot - 1]] : nil
        let right = slot < keys.count ? frames[keys[slot]] : nil
        let reach = LayoutMetrics.tileSpacing / 2 + LayoutMetrics.insertionGap / 2
        let x: CGFloat
        switch (left, right) {
        case let (left?, right?): x = (left.maxX + right.minX) / 2
        case let (left?, nil): x = left.maxX + reach
        case let (nil, right?): x = right.minX - reach
        case (nil, nil):
            guard keys.isEmpty else { return nil }
            x = row.minX + LayoutMetrics.rowPadding + LayoutMetrics.markerWidth
        }
        return CGRect(x: x - LayoutMetrics.markerWidth / 2, y: row.midY - height / 2,
                      width: LayoutMetrics.markerWidth, height: height)
    }

    static func refusalText(_ refusal: HideRefusal, name: String) -> String {
        switch refusal {
        case .apple: "\(name) belongs to macOS and stays in the menu bar."
        case .own: "YeeHaw’s own icon stays in the menu bar."
        case .notTrackedYet: "\(name) isn’t hideable yet. macOS hasn’t listed it in its menu bar settings."
        }
    }
}

// MARK: - Pieces

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// How a tile draws while a drag is under way.
enum TilePhase {
    case resting
    /// The dragged tile's empty place.
    case socket
    /// Where the dragged tile is landing; the floating copy draws it until it's settled.
    case invisible
}

private struct PhaseModifier: ViewModifier {
    let phase: TilePhase

    func body(content: Content) -> some View {
        content
            .opacity(phase == .resting ? 1 : 0)
            .background {
                if phase == .socket {
                    RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .overlay {
                            RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                }
            }
    }
}

private struct FocusRingModifier: ViewModifier {
    let focused: Bool
    let radius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .padding(-3)
                .opacity(focused ? 1 : 0)
        }
    }
}

private extension View {
    func phase(_ phase: TilePhase) -> some View { modifier(PhaseModifier(phase: phase)) }

    func focusRing(_ focused: Bool, radius: CGFloat = LayoutMetrics.tileRadius) -> some View {
        modifier(FocusRingModifier(focused: focused, radius: radius))
    }
}

/// VoiceOver actions for a Menu Bar tile, matching what it may do.
private struct BarTileActions: ViewModifier {
    let model: LayoutModel
    let tile: BarTile
    let move: (Int) -> Void
    let hide: () -> Void

    func body(content: Content) -> some View {
        if tile.capability.canHide {
            content
                .accessibilityAction(named: "Hide") { hide() }
                .accessibilityAction(named: "Move Left") { move(-1) }
                .accessibilityAction(named: "Move Right") { move(1) }
        } else if tile.capability.canDrag {
            content
                .accessibilityAction(named: "Move Left") { move(-1) }
                .accessibilityAction(named: "Move Right") { move(1) }
        } else {
            content
        }
    }
}

/// One icon, drawn the way the menu bar draws it: its glyph on a tile of the bar's colour.
struct TileFace: View {
    let image: NSImage
    let style: TileStyle
    let dimmed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let glyph = LayoutMetrics.glyphSize(image.size)
        RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
            .fill(fill)
            .overlay {
                RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
                    .strokeBorder(edge, lineWidth: contrast == .increased ? 1 : 0.5)
            }
            .overlay {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: glyph.width, height: glyph.height)
                    .foregroundStyle(ink)
                    // A fixed item keeps its tile; only its glyph recedes.
                    .opacity(dimmed ? (contrast == .increased ? 0.7 : 0.45) : 1)
            }
            .frame(width: LayoutMetrics.tileWidth(image), height: LayoutMetrics.tileHeight)
    }

    private var fill: Color {
        switch style {
        case .bar(let fill, _): Color(.sRGB, red: fill.red, green: fill.green, blue: fill.blue)
        case .system: Color(nsColor: .quaternarySystemFill)
        }
    }

    private var ink: Color {
        switch style {
        case .bar(_, let ink): ink.color
        case .system: .primary
        }
    }

    /// A hairline that keeps the tile's edge visible against the row, whatever the bar's colour.
    private var edge: Color {
        let strength = contrast == .increased ? 0.45 : 0.14
        switch style {
        case .bar(_, .white): return .white.opacity(strength)
        case .bar(_, .black): return .black.opacity(strength)
        case .system: return .primary.opacity(strength)
        }
    }
}

/// A hidden app's tiles, kept together on a shared backing when there are several.
struct GroupFace: View {
    let group: HiddenGroup
    let style: TileStyle

    var body: some View {
        HStack(spacing: LayoutMetrics.groupSpacing) {
            ForEach(group.icons) { icon in
                TileFace(image: icon.image, style: style, dimmed: false)
            }
        }
        .padding(group.icons.count > 1 ? LayoutMetrics.groupInset : 0)
        .background {
            if group.icons.count > 1 {
                RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius + LayoutMetrics.groupInset, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
        }
    }
}

/// Whether a drop would land in a row.
private enum RowWellState { case idle, accepting, refusing }

/// A faint shade in light mode and a faint lift in dark mode, like a grouped settings box.
private let rowWellColor = Color(nsColor: NSColor(name: "YeeHawLayoutWell") { appearance in
    appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
})

/// A row's rounded well. It lights up with the accent colour when a drop would land in it, and
/// dims behind a dashed edge when the dragged tile can't go there.
private struct RowWell<Content: View>: View {
    let width: CGFloat
    let state: RowWellState
    let contentWidth: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LayoutMetrics.rowRadius, style: .continuous)
        ScrollView(.horizontal, showsIndicators: false) {
            content
                .padding(LayoutMetrics.rowPadding)
                .frame(minWidth: width, alignment: .leading)
        }
        .scrollDisabled(contentWidth <= width)
        .opacity(state == .refusing ? 0.35 : 1)
        .frame(width: width, height: LayoutMetrics.rowHeight)
        .background {
            shape.fill(rowWellColor)
            shape.fill(Color.accentColor.opacity(state == .accepting ? 0.08 : 0))
        }
        .overlay { edge(shape) }
        .clipShape(shape)
    }

    @ViewBuilder
    private func edge(_ shape: RoundedRectangle) -> some View {
        switch state {
        case .accepting:
            shape.strokeBorder(Color.accentColor, lineWidth: 1.5)
        case .refusing:
            shape.strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .idle:
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
    }
}

/// A problem with an edit, shown under the rows until dismissed or the next edit.
private struct MessageBanner: View {
    let message: LayoutMessage
    let width: CGFloat
    let onFix: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            Text(message.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.offersFix {
                Button("Fix…", action: onFix)
                    .controlSize(.small)
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: width)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.yellow.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
