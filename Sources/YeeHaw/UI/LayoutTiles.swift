import AppKit
import SwiftUI
import YeeHawCore

/// Sizes shared by the rows, the tiles and the window.
enum LayoutMetrics {
    static let tileHeight: CGFloat = 34
    static let tileMinWidth: CGFloat = 34
    /// Space either side of a glyph that's wider than the square tile allows.
    static let glyphPadding: CGFloat = 9
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
    static let liftScale: CGFloat = 1.1
    static let liftRotation: Double = -3

    static func tileWidth(_ image: NSImage) -> CGFloat {
        max(tileMinWidth, GlyphMetrics.size(image.size).width + 2 * glyphPadding)
    }

    /// Tiles `widths` wide laid side by side, `spacing` apart.
    static func span(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0))
    }

    static func groupWidth(_ group: HiddenGroup) -> CGFloat {
        groupWidth(group.icons.map { tileWidth($0.image) })
    }

    /// A hidden group's width for tiles `widths` wide: one tile alone, or several on a backing.
    static func groupWidth(_ widths: [CGFloat]) -> CGFloat {
        let tiles = span(widths, spacing: groupSpacing)
        return widths.count > 1 ? tiles + 2 * groupInset : tiles
    }

    /// A row's width for its content: its tiles, the spacing between them and its padding.
    static func rowWidth(_ widths: [CGFloat]) -> CGFloat {
        span(widths, spacing: tileSpacing) + 2 * rowPadding
    }

    /// The rows' width with room for one incoming slot in either of them, so a slot opening
    /// mid-drag never pushes a row's trailing tiles (the clock among them) past the well's edge,
    /// and the well never resizes under the pointer. `bar` and `hidden` are the rows' tile and
    /// group widths; `barIncoming` the widths hidden groups take when shown into the bar, and
    /// `hiddenIncoming` the widths the bar's hideable apps take as a hidden group.
    static func rowWidthWithHeadroom(bar: [CGFloat], hidden: [CGFloat], barIncoming: [CGFloat],
                                     hiddenIncoming: [CGFloat], minimum: CGFloat = minRowWidth) -> CGFloat {
        func room(_ incoming: [CGFloat]) -> CGFloat {
            incoming.max().map { $0 + tileSpacing } ?? 0
        }
        return max(rowWidth(bar) + room(barIncoming), rowWidth(hidden) + room(hiddenIncoming), minimum)
    }
}

/// Where the slot a held tile would land in opens, given the row's tile frames at pickup.
enum LayoutGeometry {
    /// The leading x of a slot `width` wide for a drop at `insertion`, after the row's tiles have
    /// shifted by `LayoutRules.slotShift` (`from` is the held tile's index when it's from this
    /// row). `spans` are the tiles' leading and trailing x at pickup; `rowStart` is where an empty
    /// row's first tile would go.
    static func slotMinX(insertion: Int, from: Int?, spans: [(minX: CGFloat, maxX: CGFloat)], width: CGFloat,
                         spacing: CGFloat, rowStart: CGFloat) -> CGFloat {
        if let from, spans.indices.contains(from) {
            let landing = insertion > from ? insertion - 1 : insertion
            if landing < from { return spans[max(landing, 0)].minX }
            if landing > from { return spans[min(landing, spans.count - 1)].maxX - width }
            return spans[from].minX
        }
        if spans.indices.contains(insertion) { return spans[max(insertion, 0)].minX }
        if let last = spans.last { return last.maxX + spacing }
        return rowStart
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Tile states

/// How a tile draws while a drag is under way.
enum TilePhase {
    case resting
    /// The dragged tile's empty place, while the tile isn't over a new place in its own row.
    case socket
    /// The dragged tile's place while its row closes up around a new slot, or where it's
    /// landing: the floating copy draws it until it's settled.
    case invisible
}

private struct PhaseModifier: ViewModifier {
    let phase: TilePhase
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .opacity(phase == .resting ? 1 : 0)
            .background {
                if phase == .socket {
                    let shape = RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
                    shape.fill(Color.primary.opacity(0.06))
                        .overlay {
                            shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.45 : 0.18),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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

extension View {
    func phase(_ phase: TilePhase) -> some View { modifier(PhaseModifier(phase: phase)) }

    func focusRing(_ focused: Bool, radius: CGFloat = LayoutMetrics.tileRadius) -> some View {
        modifier(FocusRingModifier(focused: focused, radius: radius))
    }
}

/// VoiceOver actions for a Menu Bar tile, matching what it may do.
struct BarTileActions: ViewModifier {
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

// MARK: - Faces

/// One icon, drawn the way the menu bar draws it: its glyph on a tile of the bar's colour.
struct TileFace: View {
    let image: NSImage
    let style: TileStyle
    let dimmed: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let glyph = GlyphMetrics.size(image.size)
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
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: LayoutMetrics.groupSpacing) {
            ForEach(group.icons) { icon in
                TileFace(image: icon.image, style: style, dimmed: false)
            }
        }
        .padding(group.icons.count > 1 ? LayoutMetrics.groupInset : 0)
        .background {
            if group.icons.count > 1 {
                let shape = RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius + LayoutMetrics.groupInset,
                                             style: .continuous)
                shape.fill(Color.primary.opacity(0.08))
                    .overlay {
                        if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1) }
                    }
            }
        }
    }
}

/// Where a held tile would land: a slot the size of the tile, opened in the row.
struct GhostSlot: View {
    let size: CGSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LayoutMetrics.tileRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(0.12))
            .overlay {
                shape.strokeBorder(Color.accentColor.opacity(contrast == .increased ? 1 : 0.65),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: size.width, height: size.height)
    }
}

// MARK: - Rows

/// Whether a drop would land in a row.
enum RowWellState { case idle, accepting, refusing }

/// A faint shade in light mode and a faint lift in dark mode, like a grouped settings box.
let rowWellColor = Color(nsColor: NSColor(name: "YeeHawLayoutWell") { appearance in
    appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
        ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04)
})

/// The grouped-box look shared by the window's boxes (the restart list and the messages): the
/// well's shade and a separator edge, firmer under Increase Contrast.
struct WellBox<Box: InsettableShape>: ViewModifier {
    let shape: Box
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(rowWellColor, in: shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                                   lineWidth: contrast == .increased ? 1 : 0.5)
            }
    }
}

extension View {
    func wellBox(_ shape: some InsettableShape) -> some View {
        modifier(WellBox(shape: shape))
    }
}

/// A row's rounded well. It takes a faint accent tint when a drop would land in it (the slot
/// and the lifted tile carry the rest), and dims behind a dashed edge when the dragged tile can't
/// go there.
struct RowWell<Content: View>: View {
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
        .opacity(state == .refusing ? (contrast == .increased ? 0.55 : 0.35) : 1)
        .frame(width: width, height: LayoutMetrics.rowHeight)
        .background {
            shape.fill(rowWellColor)
            shape.fill(Color.accentColor.opacity(state == .accepting ? 0.07 : 0))
        }
        .overlay { edge(shape) }
        .clipShape(shape)
    }

    @ViewBuilder
    private func edge(_ shape: RoundedRectangle) -> some View {
        if state == .refusing {
            shape.strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        } else {
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
    }
}

/// A problem with an edit, shown under the rows until dismissed or the next edit. A neutral box
/// like the rows; the warning symbol carries the colour.
struct MessageBanner: View {
    let message: LayoutMessage
    let width: CGFloat
    let onFix: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .imageScale(.large)
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
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.vertical, 9)
        .frame(width: width)
        .wellBox(shape)
        // The message reads as one element; Fix… and Dismiss stay buttons of their own.
        .accessibilityElement(children: .contain)
    }
}
