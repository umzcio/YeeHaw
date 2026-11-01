import AppKit
import ScreenCaptureKit

/// What `StripColorSampler` needs to know about a window to tell the bar's backdrop and the
/// wallpaper from everything else.
struct BackdropWindowInfo: Equatable, Sendable {
    let title: String?
    let bundleID: String?
    let layer: Int
}

/// Samples the menu bar's colour with ScreenCaptureKit and keeps the last sample per display.
///
/// It captures a 1 pt band across the display at the bar's vertical middle, with only the bar's
/// backdrop window and the wallpaper under it in the shot: no status items, no other windows. On
/// 27.2 `SCShareableContent` lists the backdrop as the window titled "Menubar" with no owning
/// bundle ID (layer 24), and the desktop picture as "Wallpaper", owned by WindowManager. That
/// "Menubar" window also draws the app menus and the clock, which `StripColor.backdropColor`
/// leaves out.
///
/// It never asks for Screen Recording: without it, sampling reports `noPermission`.
@MainActor
final class StripColorSampler {
    enum Role: Equatable { case menuBar, wallpaper }

    enum Outcome: Equatable, Sendable {
        case sampled(StripRGB)
        /// Screen Recording isn't granted.
        case noPermission
        /// The capture didn't produce a colour, and why, for the log.
        case failed(String)
    }

    /// Takes one sample of a display's bar, given its height.
    typealias Capture = @Sendable (CGDirectDisplayID, CGFloat) async -> Outcome

    private let permitted: @MainActor () -> Bool
    private let capture: Capture
    private var cache: [CGDirectDisplayID: StripRGB] = [:]
    /// The number of the last sample started, and the newest one whose result was kept, per display.
    private var started: [CGDirectDisplayID: Int] = [:]
    private var applied: [CGDirectDisplayID: Int] = [:]

    init(permitted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         capture: @escaping Capture = { display, height in await StripColorSampler.screenCapture(display: display, barHeight: height) }) {
        self.permitted = permitted
        self.capture = capture
    }

    /// The last good sample of `display`'s bar.
    func cached(for display: CGDirectDisplayID) -> StripRGB? {
        cache[display]
    }

    /// Samples the bar on `display`, whose menu bar is `barHeight` points tall.
    ///
    /// A success is cached unless a sample started later has already been kept. Without Screen
    /// Recording the cache is cleared, so a stale colour isn't shown once permission is withdrawn;
    /// a failed capture keeps the last good colour.
    func sample(display: CGDirectDisplayID, barHeight: CGFloat) async -> Outcome {
        guard permitted() else {
            cache[display] = nil
            applied[display] = started[display] // A capture still in flight is stale now.
            return .noPermission
        }
        let number = (started[display] ?? 0) + 1
        started[display] = number
        let outcome = await capture(display, barHeight)
        if case .sampled(let color) = outcome, number > applied[display] ?? 0 {
            applied[display] = number
            cache[display] = color
        }
        return outcome
    }

    /// The display `screen` shows.
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Whether `window` is the bar's backdrop, the wallpaper, or neither. Both are owned by the
    /// system (no bundle ID, or the Dock or WindowManager); the backdrop sits above normal windows
    /// and the wallpaper below them, so an app window that borrows either title never matches.
    nonisolated static func role(of window: BackdropWindowInfo) -> Role? {
        let owner = window.bundleID ?? ""
        guard owner.isEmpty || owner == "com.apple.dock" || owner == "com.apple.WindowManager" else { return nil }
        switch window.title {
        case "Menubar" where window.layer > 0: return .menuBar
        case "Wallpaper" where window.layer < 0: return .wallpaper
        default: return nil
        }
    }

    /// Samples the bar with ScreenCaptureKit (see the type's comment).
    @concurrent
    nonisolated static func screenCapture(display id: CGDirectDisplayID, barHeight: CGFloat) async -> Outcome {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                return .failed("display \(id) not in shareable content")
            }
            let onDisplay = content.windows.filter { $0.frame.intersects(display.frame) }
            func windows(_ role: Role) -> [SCWindow] {
                onDisplay.filter {
                    Self.role(of: BackdropWindowInfo(title: $0.title, bundleID: $0.owningApplication?.bundleIdentifier,
                                                     layer: $0.windowLayer)) == role
                }
            }
            let menuBar = windows(.menuBar)
            guard !menuBar.isEmpty else { return .failed("no Menubar window") }
            let wallpaper = windows(.wallpaper)
            let layer = try await band(of: display, including: menuBar, barHeight: barHeight)
            let composite: CGImage
            if !wallpaper.isEmpty {
                composite = try await band(of: display, including: menuBar + wallpaper, barHeight: barHeight)
            } else if StripColor.isOpaqueBackdrop(layer) {
                // An opaque backdrop hides the wallpaper anyway.
                composite = layer
            } else {
                return .failed("no Wallpaper window")
            }
            guard let color = StripColor.backdropColor(composite: composite, menuBarLayer: layer) else {
                return .failed("blank capture")
            }
            return .sampled(color)
        } catch {
            return .failed("capture failed: \(error.localizedDescription)")
        }
    }

    /// A 1 pt band across `display` at the bar's vertical middle, showing only `windows`, in sRGB.
    @concurrent
    private static func band(of display: SCDisplay, including windows: [SCWindow], barHeight: CGFloat) async throws -> CGImage {
        let filter = SCContentFilter(display: display, including: windows)
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: 0, y: ((barHeight - 1) / 2).rounded(.down), width: display.frame.width, height: 1)
        configuration.width = Int((display.frame.width * scale).rounded())
        configuration.height = max(1, Int(scale.rounded()))
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
