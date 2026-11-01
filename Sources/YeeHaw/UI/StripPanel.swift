import AppKit
import os
import SwiftUI
import YeeHawCore

/// One hidden app in the strip.
struct StripEntry: Identifiable {
    let id: BundleID
    let image: NSImage
    let name: String
}

/// The floating Liquid Glass strip under YeeHaw's icon that lists the hidden apps (spec "The
/// strip"). A borderless, non-activating panel: it can become key (for Esc) without activating
/// YeeHaw or taking focus from the frontmost app.
@MainActor
final class StripPanel: NSPanel {
    /// Space between the bottom of the menu bar and the top of the strip.
    nonisolated static let gap: CGFloat = 6
    /// Transparent room around the strip for the glass shadow.
    nonisolated static let sideMargin: CGFloat = 20
    nonisolated static let bottomMargin: CGFloat = 26
    /// Closest the strip comes to a screen edge.
    nonisolated static let screenInset: CGFloat = 8

    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "strip")
    private let model: StripModel
    private let hosting: NSHostingView<StripView>
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Bumped on every show and dismiss, so a finished fade-out never hides a strip shown since.
    private var generation = 0
    private(set) var isShown = false
    /// YeeHaw's icon in screen coordinates while shown. Its clicks are drawn by MenuBarAgent, so
    /// they reach the global monitor too; the icon's own action handles them instead.
    private var iconRect: NSRect = .zero
    /// When the strip last closed by itself (an outside click or losing key), so the icon click
    /// that caused it can tell the strip was open.
    private(set) var lastAutoDismissal: ContinuousClock.Instant?

    /// Why the strip closes.
    enum DismissReason { case requested, outsideClick, resignedKey }

    init(menu: NSMenu, onSelect: @escaping (BundleID) -> Void, onFix: @escaping () -> Void) {
        model = StripModel(onSelect: onSelect, onFix: onFix)
        hosting = NSHostingView(rootView: StripView(model: model))
        hosting.sizingOptions = []
        secondaryMenu = menu
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the glass draws its own
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        contentView = hosting
        model.onMore = { [weak self] anchor in self?.popUpMenu(below: anchor) }
    }

    private let secondaryMenu: NSMenu

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }

    override func resignKey() {
        super.resignKey()
        // Another app took the keyboard (Command-Tab, a click elsewhere): the strip is done.
        dismiss(.resignedKey)
    }

    /// Shows `items` (and `notice`, a one-line problem with a Fix… button) just below `anchor`,
    /// YeeHaw's icon in screen coordinates, kept fully on `screen` (the status button's screen).
    func show(below anchor: NSRect, items: [StripEntry], notice: String? = nil, screen: NSScreen? = nil) {
        generation += 1
        iconRect = Self.iconHitRect(anchor)
        let target = screen ?? NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }
            ?? NSScreen.main
        let visible = target?.visibleFrame ?? anchor
        model.entries = items
        model.notice = notice
        model.maxWidth = visible.width - 2 * Self.screenInset
        model.presented = false
        // Measured on a separate view: the panel's own hosting view never sizes the window, so
        // nothing fights `setFrame` while the spring runs.
        let content = Self.measure(model)
        let strip = Self.stripFrame(size: content, below: anchor, within: visible, inset: Self.screenInset)
        setFrame(NSRect(x: strip.minX - Self.sideMargin, y: strip.minY - Self.bottomMargin,
                        width: strip.width + 2 * Self.sideMargin,
                        height: strip.height + Self.gap + Self.bottomMargin), display: false)

        let wasShown = isShown
        isShown = true
        makeKeyAndOrderFront(nil)
        if !wasShown { startMonitoring() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let showing = generation
        // Next turn of the run loop, so the hidden state is drawn before it animates away.
        DispatchQueue.main.async { [weak self, model] in
            guard let self, self.generation == showing else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.18) : .spring(duration: 0.25, bounce: 0.18)) {
                model.presented = true
            }
        }
    }

    /// Fades the strip out and orders it out. Safe to call when it's already closed.
    func dismiss(_ reason: DismissReason = .requested) {
        guard isShown else { return }
        isShown = false
        Self.log.info("Strip closing: \(String(describing: reason), privacy: .public)")
        if reason != .requested { lastAutoDismissal = .now }
        stopMonitoring()
        generation += 1
        let closing = generation
        withAnimation(.easeIn(duration: 0.12)) {
            model.presented = false
        } completion: { [weak self] in
            guard let self, self.generation == closing else { return }
            self.orderOut(nil)
        }
    }

    /// How far past the button's frame a click still counts as a click on the icon: MenuBarAgent's
    /// hit area includes the padding between items, and `NSRect.contains` excludes the max edges.
    nonisolated static let iconHitSlop: CGFloat = 4

    /// The screen area whose clicks belong to YeeHaw's icon: its frame widened by `iconHitSlop`
    /// and run up to the top of the screen.
    nonisolated static func iconHitRect(_ anchor: NSRect) -> NSRect {
        NSRect(x: anchor.minX - iconHitSlop, y: anchor.minY - iconHitSlop,
               width: anchor.width + 2 * iconHitSlop, height: anchor.height + 2 * iconHitSlop + 100)
    }

    /// A Quartz global point (top-left origin of the primary display) in AppKit screen
    /// coordinates (bottom-left origin).
    nonisolated static func appKitScreenPoint(_ quartz: CGPoint?, primaryHeight: CGFloat? = nil) -> NSPoint? {
        guard let quartz else { return nil }
        let height = primaryHeight ?? CGDisplayBounds(CGMainDisplayID()).height
        return NSPoint(x: quartz.x, y: height - quartz.y)
    }

    /// The visible strip's size (without the transparent margins) for the model's contents.
    static func measure(_ model: StripModel) -> NSSize {
        let fitting = NSHostingController(rootView: StripView(model: model))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return NSSize(width: max(0, fitting.width - 2 * sideMargin), height: max(0, fitting.height - gap - bottomMargin))
    }

    /// Where the visible strip goes: centred under `anchor`, its top `gap` below it, and at least
    /// `inset` inside `visible` on every side.
    nonisolated static func stripFrame(size: NSSize, below anchor: NSRect, within visible: NSRect,
                                       inset: CGFloat) -> NSRect {
        let width = min(size.width, visible.width - 2 * inset)
        var x = anchor.midX - width / 2
        x = min(x, visible.maxX - inset - width)
        x = max(x, visible.minX + inset)
        var y = min(anchor.minY, visible.maxY) - gap - size.height
        y = max(y, visible.minY + inset)
        return NSRect(x: x, y: y, width: width, height: size.height)
    }

    // MARK: Closing triggers

    private func startMonitoring() {
        // Clicks in other apps, except on YeeHaw's own icon, whose button toggles the strip.
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
                // Where the click happened, not where the pointer is by the time this runs.
                // `locationInWindow` is relative to another app's window here, so the global
                // Quartz location (top-left origin) is flipped into AppKit screen coordinates.
                let location = Self.appKitScreenPoint(event.cgEvent?.location) ?? NSEvent.mouseLocation
                MainActor.assumeIsolated {
                    guard let self, !self.iconRect.contains(location) else { return }
                    self.dismiss(.outsideClick)
                }
            }) {
            monitors.append(monitor)
        }
        // Esc, while the strip is key.
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.dismiss() }
            return nil
        }) {
            monitors.append(monitor)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.dismiss() }
        })
    }

    private func stopMonitoring() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    /// The secondary menu under the strip's "…" button. `anchor` is the button's frame in the
    /// hosting view's SwiftUI (top-left origin) coordinates.
    private func popUpMenu(below anchor: CGRect) {
        let y = hosting.isFlipped ? anchor.maxY + 4 : hosting.bounds.height - anchor.maxY - 4
        secondaryMenu.popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: y), in: hosting)
    }
}

// MARK: - SwiftUI

@MainActor @Observable
final class StripModel {
    var entries: [StripEntry] = []
    var notice: String?
    var presented = false
    /// The widest the visible strip may be (its screen, inset); wider tile rows scroll.
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    @ObservationIgnored let onSelect: (BundleID) -> Void
    @ObservationIgnored let onFix: () -> Void
    @ObservationIgnored var onMore: (CGRect) -> Void = { _ in }

    init(onSelect: @escaping (BundleID) -> Void, onFix: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onFix = onFix
    }
}

struct StripView: View {
    /// Tile size: a menu bar item with comfortable room around it.
    static let tileHeight: CGFloat = 28
    static let minTileWidth: CGFloat = 32
    static let tileImagePadding: CGFloat = 6
    static let tileSpacing: CGFloat = 2
    static let moreWidth: CGFloat = 26
    static let padding: CGFloat = 4
    /// Concentric with the tiles' capsules (tile radius + padding).
    static let cornerRadius: CGFloat = tileHeight / 2 + padding

    let model: StripModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moreFrame: CGRect = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Self.tileSpacing) {
                if model.entries.isEmpty {
                    Text("Nothing hidden yet. Use Layout… to hide icons.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: Self.tileHeight)
                } else if Self.tilesWidth(model.entries) > tilesLimit {
                    // "…" stays pinned outside the scroll.
                    ScrollView(.horizontal, showsIndicators: false) { tiles }
                        .frame(width: max(tilesLimit, Self.minTileWidth))
                } else {
                    tiles
                }
                Spacer(minLength: 0)
                moreButton
            }
            .padding(Self.padding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hidden menu bar icons")

            if let notice = model.notice {
                Divider().padding(.horizontal, 12)
                NoticeRow(message: notice, onFix: model.onFix)
            }
        }
        .fixedSize()
        .modifier(StripSurface(cornerRadius: Self.cornerRadius))
        .scaleEffect(model.presented || reduceMotion ? 1 : 0.92, anchor: .top)
        .offset(y: model.presented || reduceMotion ? 0 : -4)
        .opacity(model.presented ? 1 : 0)
        .padding(EdgeInsets(top: StripPanel.gap, leading: StripPanel.sideMargin,
                            bottom: StripPanel.bottomMargin, trailing: StripPanel.sideMargin))
    }

    private var tiles: some View {
        HStack(spacing: Self.tileSpacing) {
            ForEach(model.entries) { entry in
                StripTile(entry: entry) { model.onSelect(entry.id) }
            }
        }
    }

    /// Room for tiles in a strip of `model.maxWidth`: less the padding, the "…" button, and the
    /// row's two gaps (tiles to spacer, spacer to "…").
    private var tilesLimit: CGFloat {
        model.maxWidth - 2 * Self.padding - 2 * Self.tileSpacing - Self.moreWidth
    }

    static func tileWidth(_ image: NSImage) -> CGFloat {
        max(image.size.width + 2 * tileImagePadding, minTileWidth)
    }

    /// The natural width of the tile row.
    static func tilesWidth(_ entries: [StripEntry]) -> CGFloat {
        entries.reduce(0) { $0 + tileWidth($1.image) } + tileSpacing * CGFloat(max(entries.count - 1, 0))
    }

    private var moreButton: some View {
        Button { model.onMore(moreFrame) } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Self.moreWidth, height: Self.tileHeight)
        }
        .buttonStyle(StripButtonStyle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { moreFrame = $0 }
        .help("Layout, Settings, Quit")
        .accessibilityLabel("More")
    }
}

/// Liquid Glass, or a solid surface under Reduce Transparency.
private struct StripSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

private struct StripTile: View {
    let entry: StripEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(nsImage: entry.image)
                .renderingMode(entry.image.isTemplate ? .template : .original)
                .interpolation(.high)
                .foregroundStyle(.primary)
                .frame(width: entry.image.size.width, height: entry.image.size.height)
                .frame(width: StripView.tileWidth(entry.image), height: StripView.tileHeight)
        }
        .buttonStyle(StripButtonStyle())
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityHint("Opens its menu")
    }
}

/// A capsule highlight on hover and press, concentric with the strip.
private struct StripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
                }
                .contentShape(Capsule(style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Fix…", action: onFix)
                .controlSize(.small)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
    }
}
