import AppKit
import Testing
@testable import YeeHaw
import YeeHawCore

/// A `width`×`height` pixel crop, clear except `ink` (top-left origin) filled with `color`.
func crop(width: Int = 60, height: Int = 78, ink: CGRect, color: CGColor = .white, background: CGColor? = nil) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.setFillColor(color)
    context.fill(CGRect(x: ink.minX, y: CGFloat(height) - ink.maxY, width: ink.width, height: ink.height))
    return context.makeImage()!
}

@Suite struct GlyphImageTests {
    static let ink = CGRect(x: 20, y: 25, width: 24, height: 28)

    @Test func monochromeGlyphOnClearIsATemplateTrimmedToItsInk() throws {
        let pixels = try #require(GlyphImage.Pixels(crop(ink: Self.ink, color: CGColor(gray: 1, alpha: 0.9))))
        let analysis = try #require(GlyphImage.analyze(pixels))
        #expect(analysis.ink == Self.ink)
        #expect(analysis.kind == .template)
    }

    @Test func colouredGlyphKeepsItsColours() throws {
        let pixels = try #require(GlyphImage.Pixels(crop(ink: Self.ink, color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1))))
        #expect(GlyphImage.analyze(pixels)?.kind == .color)
    }

    @Test func blankOrOpaqueShotsAreRejected() throws {
        let blank = try #require(GlyphImage.Pixels(crop(ink: .zero)))
        #expect(GlyphImage.analyze(blank) == nil)
        let opaque = try #require(GlyphImage.Pixels(crop(ink: Self.ink, background: CGColor(gray: 0.2, alpha: 1))))
        #expect(GlyphImage.analyze(opaque) == nil)
    }

    @Test func faintShotsCaughtMidFadeAreRejected() throws {
        let faint = try #require(GlyphImage.Pixels(crop(ink: Self.ink, color: CGColor(gray: 1, alpha: 0.3))))
        #expect(GlyphImage.analyze(faint) == nil)
    }

    @Test func imageIsInPointsWithAPixelOfPadding() throws {
        let image = try #require(GlyphImage.make(from: crop(ink: Self.ink), scale: 2))
        #expect(image.size == NSSize(width: 13, height: 15))
        #expect(image.isTemplate)
    }

    @Test func tallGlyphsAreScaledDownToTheCap() throws {
        let image = try #require(GlyphImage.make(from: crop(width: 40, height: 80, ink: CGRect(x: 10, y: 1, width: 18, height: 62)), scale: 2))
        #expect(image.size.height == GlyphImage.maxHeight)
    }
}

@Suite @MainActor struct IconImageProviderTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "YeeHawTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func cacheFilesAreNamedByBundleIDAndIndex() {
        #expect(IconImageProvider.cacheKey(bundleID: "com.abdurrahim.DigUp", indexInApp: 0) == "com.abdurrahim.DigUp-0")
    }

    @Test func cacheNamesAreSanitisedAndStayInTheGlyphsFolder() throws {
        #expect(IconImageProvider.cacheKey(bundleID: "../evil/app id", indexInApp: 2) == ".._evil_app_id-2")
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = IconImageProvider(directory: directory)
        let url = try #require(provider.fileURL(IconImageProvider.cacheKey(bundleID: "../evil", indexInApp: 0)))
        #expect(url.deletingLastPathComponent().path == directory.standardizedFileURL.path)
        #expect(provider.fileURL("../outside") == nil)
    }

    @Test func loadsACachedCaptureFromDisk() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rep = NSBitmapImageRep(cgImage: crop(ink: GlyphImageTests.ink))
        rep.size = NSSize(width: 30, height: 39) // 2x
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appending(path: "com.example.app-1.png"))

        let image = IconImageProvider(directory: directory).image(for: "com.example.app", indexInApp: 1)
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 13, height: 15))
    }

    @Test func fallsBackToAnEighteenPointAppIcon() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = IconImageProvider(directory: directory).image(for: "com.example.not-installed")
        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}

@Suite struct AppleCropTests {
    static func item(_ id: String, x: Double, width: Double, apple: Bool = true) -> MenuBarItem {
        MenuBarItem(id: id, bundleID: apple ? nil : id, appleIdentifier: apple ? id : nil, indexInApp: 0,
                    axIdentifier: "", label: id, keyNames: [], keyPrefixes: [], x: x, width: width, isPinned: false)
    }

    @Test func theClockReachesIntoTheEmptyBarOnItsRight() {
        let controlCenter = Self.item("cc", x: 1866, width: 26)
        let clock = Self.item("clock", x: 1908, width: 127.5)
        let column = IconImageProvider.widened(clock, among: [controlCenter, clock])
        #expect(column.x == 1904)
        #expect(column.width == 127.5 + 8)
    }

    @Test func neverReachesIntoANeighbour() {
        let wifi = Self.item("wifi", x: 100, width: 22)
        let left = Self.item("a", x: 80, width: 20, apple: false)
        let right = Self.item("b", x: 124, width: 20, apple: false)
        let column = IconImageProvider.widened(wifi, among: [left, wifi, right])
        #expect(column.x == 100)
        #expect(column.width == 24)
    }
}
