import AppKit
import os
import ScreenCaptureKit
import YeeHawCore

/// Tile images for the strip (ruling R38). A hidden item can't be photographed, so the real glyph
/// is captured whenever an item is already drawn and cached in memory and on disk. Without a
/// capture the app's icon stands in.
@MainActor
final class IconImageProvider {
    /// Edge of the app-icon fallback, in points: menu bar size.
    static let fallbackSize: CGFloat = 18
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "glyphs")
    static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "YeeHaw/Glyphs", directoryHint: .isDirectory)

    private let directory: URL
    /// Processed captures by cache key; `nil` records a file that's missing or unusable.
    private var captures: [String: NSImage?] = [:]
    /// The PNG last written per cache key, so an unchanged capture isn't rewritten.
    private var written: [String: Data] = [:]
    private var fallbacks: [BundleID: NSImage] = [:]

    init(directory: URL = IconImageProvider.defaultDirectory) {
        self.directory = directory
    }

    /// `<bundleID>-<indexInApp>`, with anything outside `[A-Za-z0-9.-]` replaced by `_`, so a key
    /// is always a plain file name.
    static func cacheKey(bundleID: BundleID, indexInApp: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return String("\(bundleID)-\(indexInApp)".map { allowed.contains($0) ? $0 : "_" })
    }

    /// The cached glyph, else the app's icon.
    func image(for item: MenuBarItem) -> NSImage {
        guard let id = item.bundleID else { return Self.sized(NSWorkspace.shared.icon(for: .application)) }
        return image(for: id, indexInApp: item.indexInApp)
    }

    /// The cached glyph of one of an app's items (a hidden app's first item by default), else the
    /// app's icon.
    func image(for id: BundleID, indexInApp: Int = 0) -> NSImage {
        captured(Self.cacheKey(bundleID: id, indexInApp: indexInApp)) ?? appIcon(id)
    }

    /// Photographs the third-party items in `items`, which must be drawn right now, with one
    /// ScreenCaptureKit shot of each `MenuBarAgent` bar. Does nothing unless Screen Recording is
    /// already granted; it never prompts.
    func captureIfPermitted(_ items: [MenuBarItem]) async {
        guard CGPreflightScreenCaptureAccess() else { return }
        let targets = items.filter { $0.bundleID != nil && $0.bundleID != OwnIconLocator.bundleID }
        guard !targets.isEmpty else { return }
        let bars: [BarShot]
        do {
            bars = try await Self.captureBars()
        } catch {
            Self.log.error("Menu bar capture failed: \(error, privacy: .public)")
            return
        }
        for item in targets {
            guard let id = item.bundleID, let bar = Self.bar(containing: item, in: bars),
                  let crop = bar.crop(x: item.x, width: item.width) else { continue }
            let key = Self.cacheKey(bundleID: id, indexInApp: item.indexInApp)
            // Blank or opaque shots (drawn but not rendered yet, or a solid background) are dropped.
            guard let glyph = GlyphImage.make(from: crop, scale: bar.scale) else { continue }
            captures[key] = glyph
            store(crop, scale: bar.scale, key: key)
        }
    }

    // MARK: Cache

    /// The cache file for `key`, or nil unless it resolves to a file directly inside `directory`.
    func fileURL(_ key: String) -> URL? {
        let url = directory.appending(path: "\(key).png", directoryHint: .notDirectory).standardizedFileURL
        guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path else { return nil }
        return url
    }

    private func captured(_ key: String) -> NSImage? {
        if let cached = captures[key] { return cached }
        let loaded = fileURL(key).flatMap(Self.loadCapture)
        captures[key] = .some(loaded)
        return loaded
    }

    /// Saves the raw crop (not the processed glyph), so a load is processed exactly like a fresh
    /// capture. The PNG carries its point size, so the scale survives the round trip.
    private func store(_ crop: CGImage, scale: CGFloat, key: String) {
        let rep = NSBitmapImageRep(cgImage: crop)
        rep.size = NSSize(width: CGFloat(crop.width) / scale, height: CGFloat(crop.height) / scale)
        guard let url = fileURL(key), let data = rep.representation(using: .png, properties: [:]),
              written[key] != data else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            written[key] = data
        } catch {
            Self.log.error("Cannot save glyph \(key, privacy: .public): \(error, privacy: .public)")
        }
    }

    private static func loadCapture(_ url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data),
              let image = rep.cgImage, rep.size.width > 0 else { return nil }
        return GlyphImage.make(from: image, scale: CGFloat(rep.pixelsWide) / rep.size.width)
    }

    // MARK: Fallback

    private func appIcon(_ id: BundleID) -> NSImage {
        if let cached = fallbacks[id] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        let sized = Self.sized(icon)
        fallbacks[id] = sized
        return sized
    }

    /// A copy at menu bar size. The copy keeps every representation, so it stays sharp at 2x.
    private static func sized(_ icon: NSImage) -> NSImage {
        let copy = icon.copy() as? NSImage ?? icon
        copy.size = NSSize(width: fallbackSize, height: fallbackSize)
        return copy
    }

    // MARK: Capture

    /// One `MenuBarAgent` bar window: its frame (global, top-left origin, points) and a shot of it.
    struct BarShot: @unchecked Sendable {
        let frame: CGRect
        let image: CGImage
        let scale: CGFloat

        /// The item's column, full bar height.
        func crop(x: Double, width: Double) -> CGImage? {
            let rect = CGRect(x: (x - frame.minX) * scale, y: 0, width: width * scale, height: CGFloat(image.height))
                .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !rect.isEmpty else { return nil }
            return image.cropping(to: rect)
        }
    }

    /// The bar whose x range holds the item, preferring the topmost (stacked displays share x).
    private static func bar(containing item: MenuBarItem, in bars: [BarShot]) -> BarShot? {
        bars.filter { $0.frame.minX - 0.5 <= item.x && item.x + item.width <= $0.frame.maxX + 0.5 }
            .min { $0.frame.minY < $1.frame.minY }
    }

    /// `MenuBarAgent`'s bar windows aren't reported as on screen (the WindowServer composites them
    /// into the menu bar), so off-screen windows are included and filtered by shape.
    @concurrent
    private static func captureBars() async throws -> [BarShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == AXMenuBarReader.agentBundleID
                && $0.frame.height >= 16 && $0.frame.height <= 60 && $0.frame.width >= 200
        }
        var shots: [BarShot] = []
        for window in windows {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((window.frame.width * scale).rounded())
            configuration.height = Int((window.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            shots.append(BarShot(frame: window.frame, image: image, scale: scale))
        }
        return shots
    }
}

/// Turns a raw crop of a menu bar item into a strip tile image.
enum GlyphImage {
    /// Tallest tile image, in points; taller glyphs are scaled down.
    static let maxHeight: CGFloat = 22
    /// Alpha (0...255) above which a pixel counts as part of the glyph's bounding box.
    static let inkAlpha: UInt8 = 10
    /// Alpha below which a pixel counts as clear background (about 5%).
    static let clearAlpha: UInt8 = 13
    /// Alpha above which a pixel is solid enough to judge its colour (about 20%).
    static let colorJudgedAlpha: UInt8 = 51
    /// A real menu bar item is mostly clear; less clear area than this means a solid background.
    static let minClearFraction = 0.15
    /// Visible pixels more saturated than `colorSaturation` above this share make a colour glyph.
    static let colorShare = 0.05
    static let colorSaturation = 0.2
    /// Peak alpha (0...255) below which the item was still fading in when photographed.
    static let minPeakAlpha: UInt8 = 128

    enum Kind: Equatable { case template, color }

    /// The glyph trimmed to its ink (plus a pixel), at point size, tinted like the strip's text
    /// when it's monochrome. Nil when it's blank or has no clear background.
    static func make(from image: CGImage, scale: CGFloat) -> NSImage? {
        guard let pixels = Pixels(image), let analysis = analyze(pixels),
              let trimmed = image.cropping(to: analysis.ink.insetBy(dx: -1, dy: -1)
                  .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
        else { return nil }
        var size = NSSize(width: CGFloat(trimmed.width) / scale, height: CGFloat(trimmed.height) / scale)
        if size.height > maxHeight {
            size = NSSize(width: size.width * maxHeight / size.height, height: maxHeight)
        }
        let glyph = NSImage(cgImage: trimmed, size: size)
        glyph.isTemplate = analysis.kind == .template
        return glyph
    }

    /// The ink's bounding box in pixels (top-left origin) and whether it's monochrome, or nil when
    /// the crop is blank, faint (caught mid-fade) or not mostly clear.
    static func analyze(_ pixels: Pixels) -> (ink: CGRect, kind: Kind)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var clear = 0, visible = 0, colored = 0
        var peak: UInt8 = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let (r, g, b, a) = pixels[x, y]
                if a < clearAlpha { clear += 1 }
                peak = max(peak, a)
                guard a > inkAlpha else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                guard a > colorJudgedAlpha else { continue }
                visible += 1
                // Premultiplied, so the ratio is unaffected by alpha.
                let high = max(r, g, b), low = min(r, g, b)
                if high > 0, Double(high - low) / Double(high) > colorSaturation { colored += 1 }
            }
        }
        let total = pixels.width * pixels.height
        guard maxX >= 0, total > 0, peak >= minPeakAlpha, Double(clear) / Double(total) >= minClearFraction
        else { return nil }
        let ink = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let isColor = visible > 0 && Double(colored) / Double(visible) > colorShare
        return (ink, isColor ? .color : .template)
    }

    /// Premultiplied RGBA8, top-left origin.
    struct Pixels {
        let width: Int, height: Int
        private var bytes: [UInt8]

        init?(_ image: CGImage) {
            width = image.width
            height = image.height
            guard width > 0, height > 0 else { return nil }
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
        }

        subscript(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }
}
