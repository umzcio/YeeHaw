import AppKit
import os
import ScreenCaptureKit
import YeeHawCore

/// Tile images for the strip. A hidden item can't be photographed, so the real glyph
/// is captured whenever an item is already drawn and cached in memory and on disk. Without a
/// capture the app's icon stands in.
@MainActor
final class IconImageProvider {
    /// Edge of the app-icon fallback, in points (the strip draws it at this size).
    static let fallbackSize: CGFloat = 18
    private static let log = Logger(subsystem: Log.subsystem, category: "glyphs")
    static let defaultDirectory = URL.applicationSupportDirectory.appending(path: "YeeHaw/Glyphs", directoryHint: .isDirectory)

    private let directory: URL
    /// Processed captures by cache key; `nil` records a file that's missing or unusable.
    private var captures: [String: NSImage?] = [:]
    /// The PNG last written per cache key, so an unchanged capture isn't rewritten.
    private var written: [String: Data] = [:]
    private var fallbacks: [BundleID: NSImage] = [:]
    /// Apple items' glyphs by item id. Kept in memory only: Apple items are always drawn, so they
    /// can be photographed again whenever they're needed.
    private var appleCaptures: [String: NSImage] = [:]

    /// Whether `captureIfPermitted` photographs at all; off in tests, which have no menu bar.
    private let capturesScreen: Bool
    /// Whether Screen Recording is granted. Checked without prompting; tests pass their own.
    private let permitted: @MainActor () -> Bool
    /// Takes one shot of every `MenuBarAgent` bar. Tests pass scripted shots.
    private let captureBars: @MainActor () async throws -> [BarShot]
    /// The time, for the rate limit. Tests move it forward by hand.
    private let now: @MainActor () -> ContinuousClock.Instant
    /// Waits between `captureSettled`'s shots. It throws when the task is cancelled.
    private let sleep: @MainActor (Duration) async throws -> Void
    /// Counts YeeHaw's own writes to the bar (`MenuBarController.writeCount`). A shot taken while
    /// it changed may show items somewhere other than the frames being cropped (a reveal began or
    /// ended meanwhile), so it's thrown away rather than saved under the wrong app.
    var barWrites: @MainActor () -> Int = { 0 }
    /// Re-reads the bar once a shot is taken and says which copies (slots) of the items it was taken
    /// for can be stored as their own (`ItemMatcher.photographable`). By default none: a photograph that can't
    /// be proven to be the app's own isn't kept, and its app icon stands in, in the strip as in the
    /// Layout window.
    var proveOwnership: @MainActor ([MenuBarItem]) async -> Set<ItemSlot> = { _ in [] }

    init(directory: URL = IconImageProvider.defaultDirectory, capturesScreen: Bool = true,
         permitted: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         captureBars: @escaping @MainActor () async throws -> [BarShot] = { try await IconImageProvider.liveCaptureBars() },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
         sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.directory = directory
        self.capturesScreen = capturesScreen
        self.permitted = permitted
        self.captureBars = captureBars
        self.now = now
        self.sleep = sleep
    }

    /// `<bundleID>-<indexInApp>`, with anything outside `[A-Za-z0-9.-]` replaced by `_`, so a key
    /// is always a plain file name.
    static func cacheKey(bundleID: BundleID, indexInApp: Int) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return String("\(bundleID)-\(indexInApp)".map { allowed.contains($0) ? $0 : "_" })
    }

    /// The cached glyph, else the app's icon (YeeHaw's own glyph for YeeHaw, a symbol for an Apple
    /// item that hasn't been photographed).
    func image(for item: MenuBarItem) -> NSImage {
        if item.bundleID == OwnIconLocator.bundleID { return StatusGlyph.image() }
        guard let id = item.bundleID else {
            if let captured = appleCaptures[item.id] { return captured }
            return Self.symbol(for: item.appleIdentifier)
        }
        return image(for: id, indexInApp: item.indexInApp)
    }

    /// The icons a hidden app drew when it was last seen, at least `[0]`: one layout tile each.
    /// They come from `noteDrawn`; for an app never noted, from the saved photographs.
    func iconIndices(for id: BundleID) -> [Int] {
        if let noted = drawnIndices[id], !noted.isEmpty { return noted }
        let found = (0..<Self.maxIconsPerApp).filter { index in
            let key = Self.cacheKey(bundleID: id, indexInApp: index)
            if let cached = captures[key] { return cached != nil }
            return fileURL(key).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
        return found.isEmpty ? [0] : found
    }

    /// Records which icons each app in `items` draws, so a hidden app shows as many tiles as it
    /// drew, with or without Screen Recording. `items` must hold every drawn item of each app in
    /// it (a full read of the bar), or an app would be noted with fewer icons than it has.
    func noteDrawn(_ items: [MenuBarItem]) {
        var seen: [BundleID: Set<Int>] = [:]
        for item in items {
            guard let id = item.bundleID, id != OwnIconLocator.bundleID else { continue }
            seen[id, default: []].insert(item.indexInApp)
        }
        var next = drawnIndices
        for (id, indices) in seen { next[id] = indices.sorted() }
        guard next != drawnIndices else { return }
        drawnIndices = next
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: drawnIndicesURL, options: .atomic)
        } catch {
            Self.log.error("Cannot save icon counts: \(error, privacy: .public)")
        }
    }

    /// Each app's drawn icon indices as last noted, saved next to the photographs.
    private lazy var drawnIndices: [BundleID: [Int]] =
        (try? JSONDecoder().decode([BundleID: [Int]].self, from: Data(contentsOf: drawnIndicesURL))) ?? [:]
    private var drawnIndicesURL: URL { directory.appending(path: "DrawnIcons.json", directoryHint: .notDirectory) }

    /// The most icons looked up per app; no app on record draws more than a handful.
    static let maxIconsPerApp = 8

    /// The cached glyph of one of an app's items (a hidden app's first item by default), else the
    /// app's icon.
    func image(for id: BundleID, indexInApp: Int = 0) -> NSImage {
        captured(Self.cacheKey(bundleID: id, indexInApp: indexInApp)) ?? appIcon(id)
    }

    /// How old a photo may get before a routine capture (a strip open, launch) takes it again.
    static let photoMaxAge: Duration = .seconds(600)
    /// How old the Layout window lets a photo get: it shows drawn items' photos, so they stay current there.
    static let layoutPhotoMaxAge: Duration = .seconds(60)
    /// How soon an item that has no photo yet is tried again after a pass that couldn't keep one.
    static let missingRetry: Duration = .seconds(60)
    /// When each item was last part of a capture pass, by `attemptKey`.
    private var lastAttempt: [String: ContinuousClock.Instant] = [:]
    /// Set while `captureIfPermitted` runs, so a second pass never overlaps it.
    private var capturing = false

    /// What `lastAttempt` is keyed by: the cache key for an app's item, the item id for an Apple one.
    static func attemptKey(_ item: MenuBarItem) -> String {
        guard let id = item.bundleID else { return "apple:" + item.id }
        return cacheKey(bundleID: id, indexInApp: item.indexInApp)
    }

    private func hasPhoto(_ item: MenuBarItem) -> Bool {
        guard let id = item.bundleID else { return appleCaptures[item.id] != nil }
        return captured(Self.cacheKey(bundleID: id, indexInApp: item.indexInApp)) != nil
    }

    /// Whether a routine pass should photograph the item: it was never tried this session, or its
    /// photo is `maxAge` old, or it has none and the last try was `missingRetry` ago.
    private func isDue(_ item: MenuBarItem, maxAge: Duration, at time: ContinuousClock.Instant) -> Bool {
        guard let last = lastAttempt[Self.attemptKey(item)] else { return true }
        return time - last >= (hasPhoto(item) ? maxAge : Self.missingRetry)
    }

    /// Photographs the third-party items in `items`, which must be drawn right now, with one
    /// ScreenCaptureKit shot of each `MenuBarAgent` bar, keeping only the photos
    /// `proveOwnership` vouches for. Does nothing unless Screen Recording is already granted; it
    /// never prompts. Every shot makes macOS flash its recording indicator and re-lay out the bar,
    /// so a pass only happens when an item is due (it has no photo yet, or its photo is `maxAge`
    /// old), and never while another pass is still running.
    func captureIfPermitted(_ items: [MenuBarItem], maxAge: Duration = IconImageProvider.photoMaxAge) async {
        guard capturesScreen, !capturing, permitted() else { return }
        let targets = items.filter {
            ($0.bundleID != nil && $0.bundleID != OwnIconLocator.bundleID) || $0.appleIdentifier != nil
        }
        guard !targets.isEmpty else { return }
        let time = now()
        guard targets.contains(where: { isDue($0, maxAge: maxAge, at: time) }), !Task.isCancelled else { return }
        // Nothing awaits between the `capturing` guard and this line, so two calls can't both pass.
        capturing = true
        defer { capturing = false }
        // Recorded even if the proof fails, so an item that can never be proven doesn't cost a
        // shot on every strip open.
        for item in targets { lastAttempt[Self.attemptKey(item)] = time }
        let writesBefore = barWrites()
        let bars: [BarShot]
        do {
            bars = try await captureBars()
        } catch {
            Self.log.error("Menu bar capture failed: \(error, privacy: .public)")
            return
        }
        guard !Task.isCancelled else { return }
        // The bar is read again after the shot: an item whose frame or owner is in any doubt is
        // left out. On 27.2 a switched-off app stays listed at its slot for a moment while the
        // icon sliding in is what's drawn there (a Fiddle photo of YeeHaw's own hat).
        let proven = await proveOwnership(items)
        // `StatusItemController.openStrip` cancels the previous strip refresh; a replaced refresh
        // must not store photos.
        guard !Task.isCancelled else {
            Self.log.info("Menu bar capture dropped: cancelled")
            return
        }
        guard barWrites() == writesBefore else {
            Self.log.info("Menu bar capture dropped: the bar changed while it was taken")
            return
        }
        let drawn = items.sorted { $0.x < $1.x }
        var kept: Set<String> = []
        for item in Self.photoOrder(targets, bars: bars) {
            guard proven.contains(item.slot) else {
                Self.log.info("Not keeping a photo of \(item.id, privacy: .public): it can't be proven to be its own")
                continue
            }
            guard !kept.contains(Self.attemptKey(item)) else { continue }
            let column = item.bundleID == nil ? Self.widened(item, among: drawn) : (x: item.x, width: item.width)
            guard let bar = Self.bar(containing: item, in: bars),
                  let crop = bar.crop(x: column.x, width: column.width),
                  // Blank or opaque shots (drawn but not rendered yet, or a solid background) are dropped.
                  let glyph = GlyphImage.make(from: crop, scale: bar.scale) else { continue }
            guard let id = item.bundleID else {
                appleCaptures[item.id] = glyph
                kept.insert(Self.attemptKey(item))
                continue
            }
            let key = Self.cacheKey(bundleID: id, indexInApp: item.indexInApp)
            captures[key] = glyph
            store(crop, scale: bar.scale, key: key)
            kept.insert(Self.attemptKey(item))
        }
    }

    /// Between the shots `captureSettled` compares, and the most it takes.
    static let settleInterval: Duration = .milliseconds(120)
    static let settleShots = 4

    /// Photographs one revealed third-party item once it holds still: shots `settleInterval`
    /// apart until two in a row match, at most `settleShots`. A reveal's photo taken at once
    /// caught neighbours mid-slide or the pressed highlight; taken as the app's menu or popover
    /// closes and kept only when settled, it shows the icon as the app now draws it (Fiddle's
    /// filled flame while it runs), which a hidden app can't otherwise show.
    func captureSettled(_ item: MenuBarItem) async {
        guard capturesScreen, permitted(), let id = item.bundleID,
              id != OwnIconLocator.bundleID else { return }
        let writesBefore = barWrites()
        var last: (crop: CGImage, scale: CGFloat, pixels: Data)?
        for shot in 0..<Self.settleShots {
            if shot > 0 {
                do { try await sleep(Self.settleInterval) } catch { return }
            }
            guard !Task.isCancelled else { return }
            guard let bars = try? await captureBars(), let bar = Self.bar(containing: item, in: bars),
                  let crop = bar.crop(x: item.x, width: item.width), let pixels = Self.pixels(crop) else { return }
            if let last, last.pixels == pixels {
                guard barWrites() == writesBefore, await proveOwnership([item]).contains(item.slot),
                      let glyph = GlyphImage.make(from: crop, scale: bar.scale) else {
                    Self.log.info("Not keeping a settled photo of \(item.id, privacy: .public): it can't be proven to be its own")
                    return
                }
                let key = Self.cacheKey(bundleID: id, indexInApp: item.indexInApp)
                captures[key] = glyph
                store(crop, scale: bar.scale, key: key)
                lastAttempt[Self.attemptKey(item)] = now()
                return
            }
            last = (crop, bar.scale, pixels)
        }
        Self.log.info("Not keeping a photo of \(item.id, privacy: .public): it didn't hold still")
    }

    /// A crop's pixels in one fixed format, so two shots compare byte for byte.
    nonisolated static func pixels(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height, bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? data : nil
    }

    /// How far an Apple item's crop may reach past its frame into empty bar: the clock's text
    /// can be drawn a little wider than its frame after the time changes.
    nonisolated static let appleCropSlack: Double = 4

    /// An Apple item's column, widened by up to `appleCropSlack` on each side where no other
    /// drawn item is (so a neighbour's ink is never included).
    nonisolated static func widened(_ item: MenuBarItem, among drawn: [MenuBarItem]) -> (x: Double, width: Double) {
        let left = drawn.filter { abs($0.y - item.y) <= ItemMatcher.tolerance && $0.id != item.id && $0.x < item.x }
            .map { $0.x + $0.width }.max()
        let right = drawn.filter { abs($0.y - item.y) <= ItemMatcher.tolerance && $0.id != item.id && $0.x > item.x }
            .map(\.x).min()
        let before = min(appleCropSlack, max(0, item.x - (left ?? -.infinity)))
        let after = min(appleCropSlack, max(0, (right ?? .infinity) - (item.x + item.width)))
        return (item.x - before, item.width + before + after)
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
        let sized = Self.sized(AppIdentity.icon(for: id))
        fallbacks[id] = sized
        return sized
    }

    /// A template symbol standing in for an Apple item that hasn't been photographed.
    private static func symbol(for appleIdentifier: String?) -> NSImage {
        let name = switch appleIdentifier?.split(separator: ".").last?.lowercased() {
        case "wifi": "wifi"
        case "battery": "battery.100percent"
        case "bluetooth": "dot.radiowaves.left.and.right"
        case "sound", "volume": "speaker.wave.2.fill"
        case "controlcenter": "switch.2"
        case "clock": "clock"
        case "screenmirroring": "rectangle.on.rectangle"
        case "nowplaying": "play.fill"
        case "focus", "focusmodes": "moon.fill"
        case "spotlight": "magnifyingglass"
        case "siri": "mic.fill"
        default: "square.dashed"
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
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

    /// The bar holding the item's copy: its x range and its height both, since stacked displays share x.
    static func bar(containing item: MenuBarItem, in bars: [BarShot]) -> BarShot? {
        bars.filter { $0.frame.minX - 0.5 <= item.x && item.x + item.width <= $0.frame.maxX + 0.5
                      && $0.frame.minY - 0.5 <= item.y && item.y <= $0.frame.maxY + 0.5 }
            .min { $0.frame.minY < $1.frame.minY }
    }

    /// Whether `bar` is the primary display's (its frame holds the global origin).
    nonisolated static func isPrimary(_ bar: BarShot) -> Bool {
        bar.frame.minX <= 0 && 0 < bar.frame.maxX && bar.frame.minY <= 0 && 0 < bar.frame.maxY
    }

    /// The order copies are tried in when several displays draw one item: the primary display's copy
    /// first, then left to right. The first that makes a usable glyph is kept, so one copy per photo
    /// is stored, and the choice doesn't depend on which display happens to be rightmost.
    static func photoOrder(_ items: [MenuBarItem], bars: [BarShot]) -> [MenuBarItem] {
        func rank(_ item: MenuBarItem) -> Int { bar(containing: item, in: bars).map(isPrimary) == true ? 0 : 1 }
        return items.sorted { (rank($0), $0.x) < (rank($1), $1.x) }
    }

    /// The shots that worked. One bar window that can't be captured (a display going to sleep, a
    /// bar being torn down) no longer costs every display its photos; only when every window
    /// failed is the first error thrown, so the caller logs it as before.
    nonisolated static func keptShots(_ results: [Result<BarShot, Error>]) throws -> [BarShot] {
        var shots: [BarShot] = []
        var firstError: Error?
        for result in results {
            switch result {
            case .success(let shot): shots.append(shot)
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if shots.isEmpty, let firstError { throw firstError }
        return shots
    }

    /// `MenuBarAgent`'s bar windows aren't reported as on screen (the WindowServer composites them
    /// into the menu bar), so off-screen windows are included and filtered by shape.
    @concurrent
    static func liveCaptureBars() async throws -> [BarShot] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let windows = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == AXMenuBarReader.agentBundleID
                && $0.frame.height >= 16 && $0.frame.height <= 60 && $0.frame.width >= 200
        }
        var results: [Result<BarShot, Error>] = []
        for window in windows {
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = CGFloat(filter.pointPixelScale)
            let configuration = SCStreamConfiguration()
            configuration.width = Int((window.frame.width * scale).rounded())
            configuration.height = Int((window.frame.height * scale).rounded())
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                results.append(.success(BarShot(frame: window.frame, image: image, scale: scale)))
            } catch {
                results.append(.failure(error))
            }
        }
        return try keptShots(results)
    }
}

/// Turns a raw crop of a menu bar item into a strip tile image.
enum GlyphImage {
    /// Tallest tile image, in points (a menu bar glyph); taller glyphs are scaled down.
    static let maxHeight: CGFloat = 16
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
