import AppKit
import SwiftUI
import YeeHawCore

@MainActor @Observable
final class StripModel {
    var entries: [StripEntry] = []
    var notice: String?
    /// The widest the strip may be (its screen, inset); wider tile rows scroll.
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    /// The menu bar's height on the strip's screen; every row is this tall.
    var barHeight: CGFloat = NSStatusBar.system.thickness
    /// Black or white, whichever reads best on the strip's fill.
    var ink: StripInk = .black
    @ObservationIgnored let onSelect: (BundleID) -> Void
    @ObservationIgnored let onFix: () -> Void

    init(onSelect: @escaping (BundleID) -> Void, onFix: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onFix = onFix
    }
}

/// The strip's content: more of the menu bar. Each row is as tall as the bar, tiles are menu bar
/// items (the glyph with 10 pt either side, touching their neighbours), and glyphs and text use
/// the ink. The fill behind it all is the panel's.
struct StripView: View {
    /// Space at each end of the strip.
    static let horizontalPadding: CGFloat = 6
    /// Space either side of a tile's glyph.
    static let tileImagePadding: CGFloat = 10
    /// Tallest a glyph is drawn; taller ones are scaled down, smaller ones never up.
    static let maxGlyphHeight: CGFloat = 18
    /// How far the hover highlight sits inside its tile.
    static let highlightInset: CGFloat = 3
    /// Space either side of a line of text.
    static let textPadding: CGFloat = 10
    static let font = Font(NSFont.menuBarFont(ofSize: 0))

    let model: StripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.entries.isEmpty {
                    Text("No hidden icons. Right-click YeeHaw for Layout.")
                        .font(Self.font)
                        .lineLimit(1)
                        .padding(.horizontal, Self.textPadding)
                        .frame(height: model.barHeight)
                } else if Self.tilesWidth(model.entries) > tilesLimit {
                    ScrollView(.horizontal, showsIndicators: false) { tiles }
                        .frame(width: max(tilesLimit, 0), height: model.barHeight)
                } else {
                    tiles
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hidden menu bar icons")

            if let notice = model.notice {
                NoticeRow(message: notice, onFix: model.onFix)
                    .frame(height: model.barHeight)
            }
        }
        .foregroundStyle(model.ink.color)
        // System controls (the notice's button) follow the ink: light on a dark bar, dark on a light one.
        .environment(\.colorScheme, model.ink == .white ? .dark : .light)
        .fixedSize()
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            ForEach(model.entries) { entry in
                StripTile(entry: entry, barHeight: model.barHeight, ink: model.ink.color) { model.onSelect(entry.id) }
            }
        }
    }

    /// Room for tiles in a strip of `model.maxWidth`, less the padding.
    private var tilesLimit: CGFloat {
        model.maxWidth - 2 * Self.horizontalPadding
    }

    /// The size a glyph of `size` is drawn at: its own, scaled down to `maxGlyphHeight` if taller.
    static func glyphSize(_ size: NSSize) -> NSSize {
        guard size.height > maxGlyphHeight else { return size }
        return NSSize(width: size.width * maxGlyphHeight / size.height, height: maxGlyphHeight)
    }

    static func tileWidth(_ image: NSImage) -> CGFloat {
        glyphSize(image.size).width + 2 * tileImagePadding
    }

    /// The natural width of the tile row.
    static func tilesWidth(_ entries: [StripEntry]) -> CGFloat {
        entries.reduce(0) { $0 + tileWidth($1.image) }
    }
}

private struct StripTile: View {
    let entry: StripEntry
    let barHeight: CGFloat
    let ink: Color
    let action: () -> Void

    var body: some View {
        let glyph = StripView.glyphSize(entry.image.size)
        Button(action: action) {
            Image(nsImage: entry.image)
                .renderingMode(entry.image.isTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .frame(width: glyph.width, height: glyph.height)
                .frame(width: StripView.tileWidth(entry.image), height: barHeight)
        }
        .buttonStyle(StripButtonStyle(
            ink: ink, cornerRadius: max(StripPanel.cornerRadius(barHeight: barHeight) - StripView.highlightInset, 0)))
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityHint("Opens its menu")
    }
}

/// The bar's own selection highlight, on hover and press: a rounded rect of the ink, inset into
/// the tile, with the glyph growing slightly on hover.
private struct StripButtonStyle: ButtonStyle {
    let ink: Color
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration, ink: ink, cornerRadius: cornerRadius)
    }

    private struct HighlightBody: View {
        static let opacity = 0.15
        static let increasedContrastOpacity = 0.25
        static let hoverScale: CGFloat = 1.06

        let configuration: Configuration
        let ink: Color
        let cornerRadius: CGFloat
        @State private var hovering = false
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lit = hovering || configuration.isPressed
            let opacity = contrast == .increased ? Self.increasedContrastOpacity : Self.opacity
            configuration.label
                .scaleEffect(hovering && !reduceMotion ? Self.hoverScale : 1)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(ink.opacity(lit ? opacity : 0))
                        .padding(StripView.highlightInset)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.3), value: hovering)
        }
    }
}

private struct NoticeRow: View {
    let message: String
    let onFix: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
            Text(message)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Fix…", action: onFix)
                .controlSize(.small)
        }
        .font(StripView.font)
        .padding(.leading, StripView.horizontalPadding + StripView.textPadding)
        .padding(.trailing, StripView.horizontalPadding)
    }
}
