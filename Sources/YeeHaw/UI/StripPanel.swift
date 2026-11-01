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
/// built to read as a piece of the menu bar hanging down under the hat: a solid bar as tall as the
/// menu bar, 1 pt below it, centred under the icon, filled with the bar's own colour (sampled by
/// `StripColorSampler`, or an opaque neutral without Screen Recording), with continuous corners
/// and the window shadow.
///
/// A borderless, non-activating panel: it can become key (for Esc) without activating YeeHaw or
/// taking focus from the frontmost app.
@MainActor
final class StripPanel: NSPanel {
    /// Space between the bottom of the menu bar and the top of the strip.
    nonisolated static let gap: CGFloat = 1
    /// Closest the strip comes to a screen edge.
    nonisolated static let screenInset: CGFloat = 6
    /// Fade in and out, like a native menu.
    static let fadeIn: Double = 0.16
    static let fadeOut: Double = 0.12
    /// Crossfade when a fresh sample changes the fill.
    static let colorCrossfade: Double = 0.2
    /// How long after a Space switch to resample, so the new Space's wallpaper is on screen.
    static let spaceSettle: Duration = .milliseconds(600)

    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "strip")
    private let model: StripModel
    private let hosting: NSHostingView<StripView>
    /// The rounded, opaque fill everything sits on.
    private let surface = NSView()
    private let sampler = StripColorSampler()
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Space and appearance watchers, kept for the panel's lifetime so the cache stays current.
    private var resampleTriggers: [NSObjectProtocol] = []
    private var appearanceObservation: NSKeyValueObservation?
    /// Bumped on every show and dismiss, so a finished fade-out never hides a strip shown since.
    private var generation = 0
    private(set) var isShown = false
    /// The display and bar height the strip was last shown on.
    private var displayID: CGDirectDisplayID?
    private var barHeight = NSStatusBar.system.thickness
    /// The fill on screen now.
    private var fill: StripRGB?
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
        // The window server's shadow, shaped by the rounded surface.
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false

        surface.wantsLayer = true
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        contentView = surface
        watchForResampling()
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
        let frame = target?.frame ?? anchor
        barHeight = Self.barHeight(screenFrame: frame, visibleFrame: target?.visibleFrame ?? frame,
                                   fallback: target.map(Self.hiddenBarHeight) ?? NSStatusBar.system.thickness)
        displayID = target.flatMap(StripColorSampler.displayID)
        model.entries = items
        model.notice = notice
        model.barHeight = barHeight
        model.maxWidth = frame.width - 2 * Self.screenInset
        surface.layer?.cornerRadius = Self.cornerRadius(barHeight: barHeight)
        // The last sample (or the neutral) goes on before the panel is ordered front, so the strip
        // never opens in the wrong colour.
        paint(currentFill(), animated: false)
        let strip = Self.stripFrame(size: Self.measure(model), under: anchor, screen: frame, barHeight: barHeight,
                                    inset: Self.screenInset)
        setFrame(strip, display: false)
        Self.log.info("Strip at \(NSStringFromRect(strip), privacy: .public) under icon \(NSStringFromRect(anchor), privacy: .public), screen \(NSStringFromRect(frame), privacy: .public)")

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
        resampleForShow()
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

    // MARK: Fill

    /// The fill for the current display: its last sample, else the neutral for the appearance.
    private func currentFill() -> StripRGB {
        displayID.flatMap(sampler.cached) ?? StripColor.fallback(for: effectiveAppearance)
    }

    /// Fills the strip with `color` and picks the ink for it, crossfading when `animated`.
    private func paint(_ color: StripRGB, animated: Bool) {
        guard let layer = surface.layer else { return }
        if animated, color != fill {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color.cgColor
            fade.duration = Self.colorCrossfade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "fill")
        }
        layer.backgroundColor = color.cgColor
        fill = color
        let ink = StripColor.ink(for: color)
        guard ink != model.ink else { return }
        if animated {
            withAnimation(.easeInOut(duration: Self.colorCrossfade)) { model.ink = ink }
        } else {
            model.ink = ink
        }
    }

    /// Samples the bar on the strip's display and, if the strip is still showing, crossfades to
    /// the result. Logs the colour's tier (once per show).
    private func resampleForShow() {
        let showing = generation
        guard let display = displayID else {
            Self.log.info("Strip colour: fallback (no display for the strip's screen)")
            return
        }
        let height = barHeight
        Task { [weak self] in
            guard let self else { return }
            let outcome = await sampler.sample(display: display, barHeight: height)
            switch outcome {
            case .sampled(let color):
                Self.log.info("Strip colour: sampled \(Self.describe(color), privacy: .public)")
            case .noPermission:
                Self.log.info("Strip colour: fallback (no Screen Recording)")
            case .failed(let reason):
                if let kept = sampler.cached(for: display) {
                    Self.log.info("Strip colour: kept \(Self.describe(kept), privacy: .public) (\(reason, privacy: .public))")
                } else {
                    Self.log.info("Strip colour: fallback (\(reason, privacy: .public))")
                }
            }
            guard isShown, generation == showing, displayID == display else { return }
            paint(currentFill(), animated: true)
        }
    }

    private static func describe(_ color: StripRGB) -> String {
        color.byteTriple.map(String.init).joined(separator: ",")
    }

    /// Resamples every screen's bar, so the next show anywhere opens in the right colour, and
    /// crossfades the strip if it's showing.
    private func resampleAllScreens() {
        let screens = NSScreen.screens.compactMap { screen in
            StripColorSampler.displayID(of: screen).map {
                ($0, Self.barHeight(screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                                    fallback: Self.hiddenBarHeight(screen)))
            }
        }
        Task { [weak self] in
            guard let self else { return }
            for (display, height) in screens {
                _ = await sampler.sample(display: display, barHeight: height)
            }
            if isShown { paint(currentFill(), animated: true) }
        }
    }

    /// Samples every screen now, so the first show after launch opens in the bar's colour, and
    /// again when a display comes or goes, the active Space changes or the appearance changes: the
    /// wallpaper, the bar's tint and the neutral can all change with them.
    private func watchForResampling() {
        resampleAllScreens()
        resampleTriggers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resampleAllScreens() }
        })
        resampleTriggers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.spaceSettle)
                self?.resampleAllScreens()
            }
        })
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isShown { paint(currentFill(), animated: true) }
                resampleAllScreens()
            }
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

    /// The menu bar's height on a screen: its top inset (39 pt on a notched MacBook), or
    /// `fallback` when the bar is set to hide and the screen reports none.
    nonisolated static func barHeight(screenFrame: NSRect, visibleFrame: NSRect, fallback: CGFloat) -> CGFloat {
        let inset = screenFrame.maxY - visibleFrame.maxY
        return inset >= 1 ? inset : fallback
    }

    /// The bar's height on `screen` while it's hidden: the notch's safe area, else the status bar's thickness.
    static func hiddenBarHeight(_ screen: NSScreen) -> CGFloat {
        max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
    }

    /// The strip's continuous corner radius for a bar of `barHeight`.
    nonisolated static func cornerRadius(barHeight: CGFloat) -> CGFloat {
        barHeight / 4
    }

    /// Where the strip goes: its top `gap` below the menu bar (`barHeight` from the top of
    /// `screen`), centred under `anchor` (the icon), and at least `inset` inside the screen's sides.
    nonisolated static func stripFrame(size: NSSize, under anchor: NSRect, screen: NSRect, barHeight: CGFloat,
                                       inset: CGFloat) -> NSRect {
        let width = min(size.width, screen.width - 2 * inset)
        var x = anchor.midX - width / 2
        x = min(x, screen.maxX - inset - width)
        x = max(x, screen.minX + inset)
        let top = screen.maxY - barHeight - gap
        return NSRect(x: x, y: top - size.height, width: width, height: size.height)
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
