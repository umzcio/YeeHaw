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

    static func drawn(_ id: BundleID, index: Int) -> MenuBarItem {
        MenuBarItem(id: "\(id)#\(index)", bundleID: id, appleIdentifier: nil, indexInApp: index, label: id, keyNames: [], keyPrefixes: [id], x: Double(index) * 30, width: 20, isPinned: false)
    }

    @Test func aHiddenAppGetsATilePerIconItLastDrew() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A stale photograph of a third icon the app no longer draws.
        try Data().write(to: directory.appending(path: "com.example.app-2.png"))
        let provider = IconImageProvider(directory: directory)
        provider.noteDrawn([Self.drawn("com.example.app", index: 0), Self.drawn("com.example.app", index: 1),
                            Self.drawn("com.example.other", index: 0)])
        #expect(provider.iconIndices(for: "com.example.app") == [0, 1])
        #expect(provider.iconIndices(for: "com.example.other") == [0])
        // Remembered across launches, without Screen Recording.
        #expect(IconImageProvider(directory: directory).iconIndices(for: "com.example.app") == [0, 1])
    }

    @Test func withoutARecordThePhotographsDecide() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appending(path: "com.example.app-0.png"))
        try Data().write(to: directory.appending(path: "com.example.app-1.png"))
        #expect(IconImageProvider(directory: directory).iconIndices(for: "com.example.app") == [0, 1])
        #expect(IconImageProvider(directory: directory).iconIndices(for: "com.example.none") == [0])
    }

    @Test func fallsBackToAnEighteenPointAppIcon() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = IconImageProvider(directory: directory).image(for: "com.example.not-installed")
        #expect(!image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
    }
}

/// Scripted bar shots: hands out `shots` in turn (the last repeats), or throws `error`, and counts calls.
@MainActor final class FakeBars {
    var calls = 0
    var shots: [[IconImageProvider.BarShot]]
    var error: Error?
    /// Runs inside each call, e.g. to count a write to the bar while the shot is taken.
    var during: (() -> Void)?
    /// How long each call takes, so a test can act while a shot is in flight.
    var delay: Duration?
    init(_ shots: [[IconImageProvider.BarShot]]) { self.shots = shots }
    func capture() async throws -> [IconImageProvider.BarShot] {
        calls += 1
        during?()
        if let delay { try? await Task.sleep(for: delay) }
        if let error { throw error }
        return shots[min(calls - 1, shots.count - 1)]
    }
}

struct ShotFailed: Error {}

@MainActor final class TestClock {
    var now = ContinuousClock.now
}

@Suite @MainActor struct IconImageProviderCaptureTests {
    /// A 200x24 pt bar at scale 2 whose ink sits in the column of the item at x 60 (pixels 120-160).
    static func bar(inkX: CGFloat = 128) -> IconImageProvider.BarShot {
        IconImageProvider.BarShot(frame: CGRect(x: 0, y: 0, width: 200, height: 24),
                                  image: crop(width: 400, height: 48, ink: CGRect(x: inkX, y: 10, width: 24, height: 28)), scale: 2)
    }

    static let item = IconImageProviderTests.drawn("com.example.app", index: 2)
    static let proveAll: @MainActor ([MenuBarItem]) async -> Set<ItemSlot> = { items in Set(items.map(\.slot)) }

    @MainActor struct Fixture {
        let directory: URL
        let bars: FakeBars
        let permission = Permission()
        let clock = TestClock()
        let provider: IconImageProvider

        init(shots: [[IconImageProvider.BarShot]] = [[IconImageProviderCaptureTests.bar()]], capturesScreen: Bool = true,
             sleep: @escaping @MainActor (Duration) async throws -> Void = { _ in }) throws {
            directory = try IconImageProviderTests.temporaryDirectory()
            let bars = FakeBars(shots)
            let permission = permission, clock = clock
            self.bars = bars
            provider = IconImageProvider(directory: directory, capturesScreen: capturesScreen,
                                         permitted: { permission.granted }, captureBars: { try await bars.capture() },
                                         now: { clock.now }, sleep: sleep)
        }

        func stored(index: Int = 2) -> Bool {
            FileManager.default.fileExists(atPath: provider.fileURL(IconImageProvider.cacheKey(bundleID: "com.example.app", indexInApp: index))!.path)
        }
    }

    @Test func withoutScreenRecordingNothingIsShot() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        f.permission.granted = false
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 0)
    }

    @Test func capturesScreenOffShootsNothing() async throws {
        let f = try Fixture(capturesScreen: false)
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 0)
    }

    @Test func onlyYeeHawsOwnItemShootsNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([IconImageProviderTests.drawn(OwnIconLocator.bundleID, index: 0)])
        #expect(f.bars.calls == 0)
    }

    @Test func aProvenItemIsStored() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
        #expect(f.stored())
        #expect(f.provider.image(for: "com.example.app", indexInApp: 2).isTemplate)
    }

    @Test func anUnprovenItemIsNotStored() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = { _ in [] }
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
        #expect(!f.stored())
    }

    @Test func aShotTakenWhileTheBarChangedIsDropped() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        var writes = 0
        f.provider.barWrites = { writes }
        f.bars.during = { writes += 1 }
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
        #expect(!f.stored())
    }

    @Test func aFailedShotStoresNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        f.bars.error = ShotFailed()
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
        #expect(!f.stored())
    }

    @Test func settledStoresOnceTwoShotsMatch() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureSettled(Self.item)
        #expect(f.bars.calls == 2)
        #expect(f.stored())
    }

    @Test func settledGivesUpWhenTheIconNeverHoldsStill() async throws {
        let a = Self.bar(), b = Self.bar(inkX: 136)
        let f = try Fixture(shots: [[a], [b], [a], [b]])
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureSettled(Self.item)
        #expect(f.bars.calls == IconImageProvider.settleShots)
        #expect(!f.stored())
    }

    // MARK: Rate limit

    @Test func aFreshPhotoIsNotRetaken() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
    }

    @Test func aPhotoIsRetakenOnceItsOld() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        await f.provider.captureIfPermitted([Self.item])
        f.clock.now += IconImageProvider.photoMaxAge
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 2)
    }

    @Test func theLayoutsShorterAgeApplies() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        f.clock.now += .seconds(61)
        await f.provider.captureIfPermitted([Self.item], maxAge: IconImageProvider.layoutPhotoMaxAge)
        #expect(f.bars.calls == 2)
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 2)
    }

    @Test func anItemWithNoPhotoIsRetriedAfterAMinuteNotBefore() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = { _ in [] }
        await f.provider.captureIfPermitted([Self.item])
        f.clock.now += .seconds(30)
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 1)
        f.clock.now += .seconds(31)
        await f.provider.captureIfPermitted([Self.item])
        #expect(f.bars.calls == 2)
    }

    @Test func aNewItemTriggersAPass() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureIfPermitted([Self.item])
        let other = IconImageProviderTests.drawn("com.example.app", index: 3)
        await f.provider.captureIfPermitted([Self.item, other])
        #expect(f.bars.calls == 2)
    }

    @Test func aSecondPassDoesNotOverlapOneInFlight() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        f.bars.delay = .milliseconds(50)
        let other = IconImageProviderTests.drawn("com.example.app", index: 3)
        let first = Task { await f.provider.captureIfPermitted([Self.item]) }
        while f.bars.calls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await f.provider.captureIfPermitted([other])
        await first.value
        #expect(f.bars.calls == 1)
    }

    // MARK: Cancellation

    @Test func aCancelledPassShootsNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        let task = Task { await f.provider.captureIfPermitted([Self.item]) }
        task.cancel()
        await task.value
        #expect(f.bars.calls == 0)
    }

    @Test func aPassCancelledDuringTheProofStoresNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = { items in
            withUnsafeCurrentTask { $0?.cancel() }
            return Set(items.map(\.slot))
        }
        await Task { await f.provider.captureIfPermitted([Self.item]) }.value
        #expect(f.bars.calls == 1)
        #expect(!f.stored())
    }

    @Test func aSettleCancelledMidwayStopsShooting() async throws {
        let a = Self.bar(), b = Self.bar(inkX: 136)
        let f = try Fixture(shots: [[a], [b], [a], [b]], sleep: { _ in throw CancellationError() })
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        await f.provider.captureSettled(Self.item)
        #expect(f.bars.calls == 1)
        #expect(!f.stored())
    }

    @Test func aCancelledSettleShootsNothing() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        f.provider.proveOwnership = Self.proveAll
        let task = Task { await f.provider.captureSettled(Self.item) }
        task.cancel()
        await task.value
        #expect(f.bars.calls == 0)
    }
}

@Suite struct AppleCropTests {
    static func item(_ id: String, x: Double, width: Double, apple: Bool = true) -> MenuBarItem {
        MenuBarItem(id: id, bundleID: apple ? nil : id, appleIdentifier: apple ? id : nil, indexInApp: 0,
                    label: id, keyNames: [], keyPrefixes: [], x: x, width: width, isPinned: false)
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
