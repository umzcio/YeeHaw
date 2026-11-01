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
/// It never asks for Screen Recording: without it, sampling reports unavailable.
@MainActor
final class StripColorSampler {
    enum Role: Equatable { case menuBar, wallpaper }

    enum Outcome: Equatable, Sendable {
        case sampled(StripRGB)
        /// Why there's no sample, for the log.
        case unavailable(String)
    }

    private var cache: [CGDirectDisplayID: StripRGB] = [:]

    /// The last sample taken on `display`, if the last attempt succeeded.
    func cached(for display: CGDirectDisplayID) -> StripRGB? {
        cache[display]
    }

    /// Samples the bar on `display`, whose menu bar is `barHeight` points tall, and caches it.
    /// A failed attempt clears the cache, so a stale colour isn't shown after permission is withdrawn.
    func sample(display: CGDirectDisplayID, barHeight: CGFloat) async -> Outcome {
        let outcome: Outcome
        if CGPreflightScreenCaptureAccess() {
            outcome = await Self.capture(display: display, barHeight: barHeight)
        } else {
            outcome = .unavailable("no Screen Recording")
        }
        switch outcome {
        case .sampled(let color): cache[display] = color
        case .unavailable: cache[display] = nil
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

    @concurrent
    private static func capture(display id: CGDirectDisplayID, barHeight: CGFloat) async -> Outcome {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                return .unavailable("display \(id) not in shareable content")
            }
            let onDisplay = content.windows.filter { $0.frame.intersects(display.frame) }
            func windows(_ role: Role) -> [SCWindow] {
                onDisplay.filter {
                    Self.role(of: BackdropWindowInfo(title: $0.title, bundleID: $0.owningApplication?.bundleIdentifier,
                                                     layer: $0.windowLayer)) == role
                }
            }
            let menuBar = windows(.menuBar)
            guard !menuBar.isEmpty else { return .unavailable("no Menubar window") }
            let composite = try await band(of: display, including: menuBar + windows(.wallpaper), barHeight: barHeight)
            let layer = try await band(of: display, including: menuBar, barHeight: barHeight)
            guard let color = StripColor.backdropColor(composite: composite, menuBarLayer: layer) else {
                return .unavailable("blank capture")
            }
            return .sampled(color)
        } catch {
            return .unavailable("capture failed: \(error.localizedDescription)")
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
