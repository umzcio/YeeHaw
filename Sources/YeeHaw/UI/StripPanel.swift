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

/// The strip under YeeHaw's icon that lists the hidden apps (spec "The strip", ruling R44). It's
/// built to look like the menus status items open on macOS 27: attached just under the bar, its
/// leading edge under the icon's, the same glass, corner radius and window shadow, and a row of
/// tiles that continues the bar's own row.
///
/// The geometry was measured from a screenshot of DigUp's native menu on 27.2 (2x pixels): the
/// menu's top edge is 1 pt below the bar, its leading edge 4.5 pt left of the item's frame, and
/// its corners have a 12 pt radius.
///
/// A borderless, non-activating panel: it can become key (for Esc) without activating YeeHaw or
/// taking focus from the frontmost app.
@MainActor
final class StripPanel: NSPanel {
    /// Space between the bottom of the menu bar and the top of the strip (measured).
    nonisolated static let gap: CGFloat = 1
    /// How far the strip's leading edge sits left of the icon's frame (measured).
    nonisolated static let leadingInset: CGFloat = 4.5
    /// Corner radius of the strip (measured).
    nonisolated static let cornerRadius: CGFloat = 12
    /// Closest the strip comes to a screen edge.
    nonisolated static let screenInset: CGFloat = 6
    /// Fade in and out, like a native menu.
    static let fadeIn: Double = 0.16
    static let fadeOut: Double = 0.12

    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "strip")
    private let model: StripModel
    private let hosting: NSHostingView<StripView>
    private let glass = NSGlassEffectView()
    private let solid = NSView()
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

    init(onSelect: @escaping (BundleID) -> Void, onFix: @escaping () -> Void) {
        model = StripModel(onSelect: onSelect, onFix: onFix)
        hosting = NSHostingView(rootView: StripView(model: model))
        // The window is sized from `measure`; the hosting view never resizes it.
        hosting.sizingOptions = []
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        // The window server's shadow, shaped by the rounded surface, as menus have.
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false

        glass.cornerRadius = Self.cornerRadius
        solid.wantsLayer = true
        solid.layer?.cornerRadius = Self.cornerRadius
        solid.layer?.cornerCurve = .continuous
        solid.layer?.masksToBounds = true
    }

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
        installSurface()
        let strip = Self.stripFrame(size: Self.measure(model), below: anchor, within: visible, inset: Self.screenInset)
        setFrame(strip, display: false)
        Self.log.info("Strip at \(NSStringFromRect(strip), privacy: .public) under icon \(NSStringFromRect(anchor), privacy: .public), screen \(NSStringFromRect(visible), privacy: .public)")

        let wasShown = isShown
        isShown = true
        alphaValue = 0
        makeKeyAndOrderFront(nil)
        invalidateShadow()
        if !wasShown { startMonitoring() }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOut
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == closing else { return }
                self.orderOut(nil)
            }
        }
    }

    /// Glass, or a solid menu-coloured surface under Reduce Transparency.
    private func installSurface() {
        // Only re-parented when the setting changed: re-setting the same content view drops its
        // frame and leaves the strip empty.
        hosting.autoresizingMask = [.width, .height]
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            solid.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            if hosting.superview !== solid {
                glass.contentView = nil
                hosting.frame = solid.bounds
                solid.addSubview(hosting)
            }
            if contentView !== solid { contentView = solid }
        } else {
            if glass.contentView !== hosting {
                hosting.removeFromSuperview()
                glass.contentView = hosting
            }
            if contentView !== glass { contentView = glass }
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

    /// The strip's size for the model's contents.
    static func measure(_ model: StripModel) -> NSSize {
        NSHostingController(rootView: StripView(model: model))
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
    }

    /// Where the strip goes: its top `gap` below `anchor` (the icon), its leading edge
    /// `leadingInset` left of the icon's, and at least `inset` inside `visible` on every side.
    nonisolated static func stripFrame(size: NSSize, below anchor: NSRect, within visible: NSRect,
                                       inset: CGFloat) -> NSRect {
        let width = min(size.width, visible.width - 2 * inset)
        var x = anchor.minX - leadingInset
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
}

// MARK: - SwiftUI

@MainActor @Observable
final class StripModel {
    var entries: [StripEntry] = []
    var notice: String?
    /// The widest the strip may be (its screen, inset); wider tile rows scroll.
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    @ObservationIgnored let onSelect: (BundleID) -> Void
    @ObservationIgnored let onFix: () -> Void

    init(onSelect: @escaping (BundleID) -> Void, onFix: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onFix = onFix
    }
}

/// The strip's content: the bar's row continued. Tiles are menu bar items: the height of the
/// bar's selection capsule, 10 pt either side of a 16 pt glyph (DigUp's own item is 36 pt wide),
/// and abutting like the bar's items. The padding puts the first tile right under YeeHaw's icon.
struct StripView: View {
    static let tileHeight: CGFloat = 24
    static let glyphSize: CGFloat = 16
    static let tileImagePadding: CGFloat = 10
    static let minTileWidth: CGFloat = glyphSize + 2 * tileImagePadding
    /// The bar's selection capsule is inset 5 pt into the item on each side (measured).
    static let highlightInset: CGFloat = 5
    static let horizontalPadding: CGFloat = StripPanel.leadingInset
    static let verticalPadding: CGFloat = 5
    static let font = Font(NSFont.menuFont(ofSize: 0))

    let model: StripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if model.entries.isEmpty {
                    Text("No hidden icons. Right-click YeeHaw for Layout.")
                        .font(Self.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: Self.tileHeight)
                } else if Self.tilesWidth(model.entries) > tilesLimit {
                    ScrollView(.horizontal, showsIndicators: false) { tiles }
                        .frame(width: max(tilesLimit, Self.minTileWidth))
                } else {
                    tiles
                }
            }
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Hidden menu bar icons")

            if let notice = model.notice {
                Divider().padding(.horizontal, 10)
                NoticeRow(message: notice, onFix: model.onFix)
            }
        }
        .fixedSize()
    }

    private var tiles: some View {
        HStack(spacing: 0) {
            ForEach(model.entries) { entry in
                StripTile(entry: entry) { model.onSelect(entry.id) }
            }
        }
    }

    /// Room for tiles in a strip of `model.maxWidth`, less the padding.
    private var tilesLimit: CGFloat {
        model.maxWidth - 2 * Self.horizontalPadding
    }

    static func tileWidth(_ image: NSImage) -> CGFloat {
        max(image.size.width + 2 * tileImagePadding, minTileWidth)
    }

    /// The natural width of the tile row.
    static func tilesWidth(_ entries: [StripEntry]) -> CGFloat {
        entries.reduce(0) { $0 + tileWidth($1.image) }
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

/// The bar's own selection capsule, on hover and press.
private struct StripButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HighlightBody(configuration: configuration)
    }

    private struct HighlightBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.2 : hovering ? 0.12 : 0))
                        .padding(.horizontal, StripView.highlightInset)
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
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
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button("Fix…", action: onFix)
                .controlSize(.small)
        }
        .font(StripView.font)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
    }
}
