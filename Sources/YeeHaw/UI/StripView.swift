import AppKit
import SwiftUI
import YeeHawCore

/// A one-line problem under the strip's tiles, with the button that deals with it (if any).
struct StripNotice: Equatable {
    enum Action: Equatable {
        /// A missing file grant: Settings can fix it.
        case openSettings
        /// The app didn't appear in time: reveal it again.
        case retry(BundleID)
        /// The app isn't running: open it.
        case openApp(BundleID)
    }

    var message: String
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .openSettings: "Fix…"
        case .retry: "Try Again"
        case .openApp: "Open"
        case nil: nil
        }
    }
}

@MainActor @Observable
final class StripModel {
    var entries: [StripEntry] = []
    var notice: StripNotice?
    /// The tile lit by the pointer or the arrow keys, as a menu's selected item is.
    var highlighted: BundleID?
    /// The widest the strip may be (its screen, inset); wider tile rows scroll.
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    /// The menu bar's height on the strip's screen; every row is this tall.
    var barHeight: CGFloat = NSStatusBar.system.thickness
    /// Black or white, whichever reads best on the strip's fill.
    var ink: StripInk = .black
    @ObservationIgnored let onSelect: (BundleID) -> Void
    @ObservationIgnored let onNoticeAction: (StripNotice.Action) -> Void
    @ObservationIgnored let onLayout: () -> Void

    init(onSelect: @escaping (BundleID) -> Void, onNoticeAction: @escaping (StripNotice.Action) -> Void = { _ in },
         onLayout: @escaping () -> Void = {}) {
        self.onSelect = onSelect
        self.onNoticeAction = onNoticeAction
        self.onLayout = onLayout
    }

    /// Moves the highlight `step` tiles along (Left is -1, Right +1), wrapping like a menu. With
    /// nothing lit, Right lights the first tile and Left the last.
    func moveHighlight(by step: Int) {
        highlighted = Self.moved(highlighted, in: entries.map(\.id), by: step)
    }

    nonisolated static func moved(_ current: BundleID?, in ids: [BundleID], by step: Int) -> BundleID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return step < 0 ? ids.last : ids.first }
        return ids[((index + step) % ids.count + ids.count) % ids.count]
    }
}

/// The strip's content: more of the menu bar. Each row is as tall as the bar, tiles are menu bar
/// items (the glyph with 10 pt either side, touching their neighbours), and glyphs and text use
/// the ink. The fill behind it all is the panel's. The arrow keys light tiles and Return or Space
/// opens the lit one (`StripPanel` handles the keys).
struct StripView: View {
    /// Space at each end of the strip.
    static let horizontalPadding: CGFloat = 6
    /// Space either side of a tile's glyph.
    static let tileImagePadding: CGFloat = 10
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
                    EmptyRow(onLayout: model.onLayout)
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
                NoticeRow(notice: notice, onAction: model.onNoticeAction)
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
                StripTile(entry: entry, barHeight: model.barHeight, ink: model.ink.color,
                          highlighted: model.highlighted == entry.id,
                          onHover: { inside in
                              if inside {
                                  model.highlighted = entry.id
                              } else if model.highlighted == entry.id {
                                  model.highlighted = nil
                              }
                          }) { model.onSelect(entry.id) }
            }
        }
    }

    /// Room for tiles in a strip of `model.maxWidth`, less the padding.
    private var tilesLimit: CGFloat {
        model.maxWidth - 2 * Self.horizontalPadding
    }

    static func tileWidth(_ image: NSImage) -> CGFloat {
        GlyphMetrics.size(image.size).width + 2 * tileImagePadding
    }

    /// The natural width of the tile row.
    static func tilesWidth(_ entries: [StripEntry]) -> CGFloat {
        entries.reduce(0) { $0 + tileWidth($1.image) }
    }
}

private struct StripTile: View {
    /// How strongly an app that isn't running is drawn: it's there, but has no menu to open yet.
    static let notRunningOpacity = 0.45

    let entry: StripEntry
    let barHeight: CGFloat
    let ink: Color
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void

    var body: some View {
        let glyph = GlyphMetrics.size(entry.image.size)
        Button(action: action) {
            Image(nsImage: entry.image)
                .renderingMode(entry.image.isTemplate ? .template : .original)
                .resizable()
                .interpolation(.high)
                .frame(width: glyph.width, height: glyph.height)
                .opacity(entry.isRunning ? 1 : Self.notRunningOpacity)
                .frame(width: StripView.tileWidth(entry.image), height: barHeight)
        }
        .buttonStyle(StripButtonStyle(
            ink: ink, highlighted: highlighted,
            cornerRadius: max(StripPanel.cornerRadius(barHeight: barHeight) - StripView.highlightInset, 0)))
        .onHover(perform: onHover)
        .help(entry.isRunning ? entry.name : "\(entry.name) (not open)")
        .accessibilityLabel(entry.name)
        .accessibilityValue(entry.isRunning ? "" : "Not open")
        .accessibilityHint(entry.isRunning ? "Opens its menu" : "Not open, so it has no menu yet")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

/// The bar's own selection highlight, for the lit tile (pointer or arrow keys) and a press: a
/// rounded rect of the ink, inset into the tile, with the glyph growing slightly while lit.
private struct StripButtonStyle: ButtonStyle {
    let ink: Color
    let highlighted: Bool
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration, ink: ink, highlighted: highlighted, cornerRadius: cornerRadius)
    }

    private struct HighlightBody: View {
        static let opacity = 0.15
        static let increasedContrastOpacity = 0.25
        static let hoverScale: CGFloat = 1.06

        let configuration: Configuration
        let ink: Color
        let highlighted: Bool
        let cornerRadius: CGFloat
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let lit = highlighted || configuration.isPressed
            let opacity = contrast == .increased ? Self.increasedContrastOpacity : Self.opacity
            configuration.label
                .scaleEffect(highlighted && !reduceMotion ? Self.hoverScale : 1)
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(ink.opacity(lit ? opacity : 0))
                        .padding(StripView.highlightInset)
                }
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0.3), value: highlighted)
        }
    }
}

/// The strip with nothing hidden: says so, and offers the Layout window, where icons are hidden.
private struct EmptyRow: View {
    let onLayout: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("No hidden icons")
                .lineLimit(1)
            Spacer(minLength: 16)
            Button("Layout…", action: onLayout)
                .controlSize(.small)
                .help("Arrange the menu bar and choose icons to hide (⌘L)")
        }
        .font(StripView.font)
        .padding(.leading, StripView.textPadding)
    }
}

private struct NoticeRow: View {
    let notice: StripNotice
    let onAction: (StripNotice.Action) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .accessibilityHidden(true)
            Text(notice.message)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let action = notice.action, let title = notice.actionTitle {
                Button(title) { onAction(action) }
                    .controlSize(.small)
            }
        }
        .font(StripView.font)
        .padding(.leading, StripView.horizontalPadding + StripView.textPadding)
        .padding(.trailing, StripView.horizontalPadding)
        .accessibilityElement(children: .contain)
    }
}
