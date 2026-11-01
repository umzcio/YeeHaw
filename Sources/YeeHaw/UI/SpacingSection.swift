import AppKit
import SwiftUI
import YeeHawCore

/// The layout window's Spacing section (spec "Spacing"): a live preview of the bar at the
/// slider's spacing, the apps Apply restarts, and Apply. Nothing changes until Apply.
struct SpacingSection: View {
    /// The list shows this many rows before it scrolls.
    static let visibleRows = 6
    static let tickEvery = 8
    static let rowHeight: CGFloat = 30
    static let boxRadius: CGFloat = 10

    let model: SpacingModel
    /// The bar's tiles, left to right, and their colours, for the preview.
    let bar: [BarTile]
    let style: TileStyle
    let width: CGFloat
    /// A layout edit is under way; Apply waits for it.
    let layoutBusy: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Spacing")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .frame(height: 18)
                .padding(.bottom, 8)
            SpacingPreviewBar(tiles: bar, style: style, spacing: model.value, width: width,
                              height: Self.barHeight)
            sliderRow
                .padding(.top, 12)
            Text("Restart to apply")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            appList
            Text("Apps read the spacing when they start, so Apply quits and reopens the ticked apps one at a time. Unticked apps, macOS’s own icons and YeeHaw change the next time they start.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            applyRow
                .padding(.top, 14)
            if let report = model.report {
                SpacingReportBanner(report: report) {
                    withAnimation(LayoutModel.rowAnimation) { model.report = nil }
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(width: width, alignment: .leading)
    }

    /// The menu bar's height on the main screen (39 pt on a notched MacBook).
    static var barHeight: CGFloat {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return NSStatusBar.system.thickness }
        return StripPanel.barHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                    fallback: StripPanel.hiddenBarHeight(screen))
    }

    // MARK: Slider

    private var sliderRow: some View {
        HStack(spacing: 12) {
            // A tick every 8 pt (the default, 16, among them); the value snaps to whole points.
            Slider(value: sliderValue, in: Double(SpacingPlan.range.lowerBound)...Double(SpacingPlan.range.upperBound),
                   neutralValue: Double(SpacingPlan.defaultValue)) {
                Text("Spacing")
            } minimumValueLabel: {
                Text("Tight").accessibilityHidden(true)
            } maximumValueLabel: {
                Text("Wide").accessibilityHidden(true)
            } ticks: {
                SliderTickContentForEach(Array(stride(from: SpacingPlan.range.lowerBound, through: SpacingPlan.range.upperBound,
                                                      by: Self.tickEvery)).map(Double.init), id: \.self) { value in
                    SliderTick(value)
                }
            }
            .labelsHidden()
            .accessibilityValue("\(model.value) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.value = SpacingPlan.clamped(model.value + 1)
                case .decrement: model.value = SpacingPlan.clamped(model.value - 1)
                @unknown default: break
                }
            }
            Text("\(model.value) pt")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
            Button("Default") { model.value = SpacingPlan.defaultValue }
                .disabled(model.value == SpacingPlan.defaultValue)
                .help("macOS’s standard spacing, \(SpacingPlan.defaultValue) pt")
        }
        .font(.callout)
        .disabled(model.isApplying)
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(model.value) },
                set: { model.value = SpacingPlan.clamped(Int($0.rounded())) })
    }

    // MARK: Apps

    @ViewBuilder
    private var appList: some View {
        let shape = RoundedRectangle(cornerRadius: Self.boxRadius, style: .continuous)
        Group {
            if model.candidates.isEmpty {
                Text("No other apps with menu bar icons are running.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight + 8)
            } else if model.candidates.count > Self.visibleRows {
                ScrollView(.vertical) { rows }
                    .frame(height: Self.rowHeight * (CGFloat(Self.visibleRows) + 0.5))
            } else {
                rows
            }
        }
        .background(rowWellColor, in: shape)
        .overlay {
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .clipShape(shape)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apps to restart")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 {
                    Divider().padding(.leading, 12)
                }
                SpacingAppRow(candidate: candidate, height: Self.rowHeight) { ticked in
                    model.setTicked(ticked, for: candidate.id)
                }
            }
        }
        .disabled(model.isApplying)
    }

    // MARK: Apply

    private var applyRow: some View {
        HStack(spacing: 8) {
            if let progress = model.progress {
                ProgressView()
                    .controlSize(.small)
                Text(progress.count == 0 ? "Saving…"
                     : "Restarting \(progress.name)… (\(progress.index + 1) of \(progress.count))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer(minLength: 12)
            Button(SpacingModel.applyTitle(restarting: model.tickedCount)) {
                Task { await model.apply() }
            }
            .disabled(!model.canApply || layoutBusy)
            .help(model.canApply ? "Saves the spacing and restarts the ticked apps"
                                 : "Move the slider to choose a new spacing")
        }
        .frame(minHeight: 22)
    }
}

/// One app in the restart list: its checkbox, icon and name, and a note when restarting it
/// would interrupt open windows.
private struct SpacingAppRow: View {
    let candidate: SpacingCandidate
    let height: CGFloat
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { candidate.ticked }, set: { onToggle($0) })) {
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: candidate.app.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(candidate.app.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if candidate.app.hasVisibleWindows {
                    Label("Open windows", systemImage: "macwindow")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help("Restarting \(candidate.app.name) closes its windows and interrupts what’s open in them.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .frame(height: height)
        .accessibilityHint(candidate.app.hasVisibleWindows
                           ? "Has open windows. Restarting it interrupts what’s open in them." : "")
    }
}

/// The menu bar in miniature: its sampled colour, its own icons in order at the slider's
/// spacing, aligned to the right like the real bar. Icons that don't fit fade out on the left.
struct SpacingPreviewBar: View {
    static let fadeWidth: CGFloat = 28
    static let endPadding: CGFloat = StripView.horizontalPadding

    let tiles: [BarTile]
    let style: TileStyle
    let spacing: Int
    let width: CGFloat
    let height: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StripPanel.cornerRadius(barHeight: height), style: .continuous)
        let overflows = contentWidth > width
        HStack(spacing: 0) {
            ForEach(tiles) { tile in
                let glyph = StripView.glyphSize(tile.image.size)
                Image(nsImage: tile.image)
                    .renderingMode(tile.image.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: glyph.width, height: glyph.height)
                    .frame(width: SpacingPreview.itemWidth(glyph: glyph.width, spacing: spacing), height: height)
            }
        }
        .fixedSize()
        .padding(.trailing, Self.endPadding)
        .foregroundStyle(ink)
        .frame(width: width, height: height, alignment: .trailing)
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: overflows ? Self.fadeWidth : 0)
                Rectangle()
            }
        }
        .background(fill, in: shape)
        .overlay { shape.strokeBorder(edge, lineWidth: contrast == .increased ? 1 : 0.5) }
        .clipShape(shape)
        .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.12), value: spacing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview")
        .accessibilityValue("Menu bar icons \(spacing) points apart")
    }

    private var contentWidth: CGFloat {
        tiles.reduce(Self.endPadding) {
            $0 + SpacingPreview.itemWidth(glyph: StripView.glyphSize($1.image.size).width, spacing: spacing)
        }
    }

    private var fill: Color {
        switch style {
        case .bar(let fill, _): Color(.sRGB, red: fill.red, green: fill.green, blue: fill.blue)
        case .system: Color(nsColor: .windowBackgroundColor)
        }
    }

    private var ink: Color {
        switch style {
        case .bar(_, let ink): ink.color
        case .system: .primary
        }
    }

    /// A hairline that keeps the bar's edge visible against the window, whatever its colour.
    private var edge: Color {
        let strength = contrast == .increased ? 0.45 : 0.14
        switch style {
        case .bar(_, .white): return .white.opacity(strength)
        case .bar(_, .black): return .black.opacity(strength)
        case .system: return Color(nsColor: .separatorColor)
        }
    }
}

/// What the last Apply did: a neutral box like the window's other messages, with the outcome's
/// symbol carrying the colour.
private struct SpacingReportBanner: View {
    let report: SpacingReport
    let onDismiss: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SpacingSection.boxRadius, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if report.skipped.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                }
            }
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(report.headline)
                    .fontWeight(.semibold)
                ForEach(report.detail, id: \.self) { line in
                    Text(line)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .padding(.vertical, 10)
        .background(rowWellColor, in: shape)
        .overlay {
            shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.5) : Color(nsColor: .separatorColor),
                               lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}
