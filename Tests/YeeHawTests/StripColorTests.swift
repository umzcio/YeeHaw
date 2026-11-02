import AppKit
import Synchronization
import Testing
@testable import YeeHaw

/// A `width`×1 sRGB image whose columns are filled with `colors` in turn (each `(r, g, b, a)` in 0...255).
func band(_ colors: [(Int, Int, Int, Int)], width: Int = 8) -> CGImage {
    let context = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<width {
        let (r, g, b, a) = colors[x * colors.count / width]
        context.setFillColor(CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
                                     alpha: CGFloat(a) / 255))
        context.fill(CGRect(x: x, y: 0, width: 1, height: 1))
    }
    return context.makeImage()!
}

@Suite struct StripInkTests {
    @Test func navyGetsWhiteInk() {
        #expect(StripColor.ink(for: StripRGB(bytes: 14, 15, 27)) == .white)
    }

    @Test func lightGreyGetsBlackInk() {
        #expect(StripColor.ink(for: StripRGB(bytes: 230, 230, 230)) == .black)
    }

    @Test(arguments: [(0, StripInk.white), (60, .white), (100, .white), (117, .white),
                      (118, .black), (128, .black), (180, .black), (255, .black)])
    func greysGetTheHigherContrastInk(level: Int, ink: StripInk) {
        #expect(StripColor.ink(for: StripRGB(bytes: level, level, level)) == ink)
    }

    @Test func midGreyFlipsBetween117And118() {
        // WCAG luminance crosses the equal-contrast point (about 0.179) between these levels.
        #expect(StripColor.ink(for: StripRGB(bytes: 117, 117, 117)) == .white)
        #expect(StripColor.ink(for: StripRGB(bytes: 118, 118, 118)) == .black)
    }

    @Test func luminanceFollowsWCAG() {
        #expect(StripColor.relativeLuminance(StripRGB(bytes: 0, 0, 0)) == 0)
        #expect(abs(StripColor.relativeLuminance(StripRGB(bytes: 255, 255, 255)) - 1) < 1e-9)
        #expect(abs(StripColor.contrastRatio(1, 0) - 21) < 1e-9)
    }
}

@Suite struct StripBackdropColorTests {
    @Test func menuTitlesInTheMenuBarLayerAreLeftOut() throws {
        // The bar layer is clear except for a white menu title over the last quarter.
        let composite = band([(14, 15, 27, 255), (14, 15, 27, 255), (14, 15, 27, 255), (255, 255, 255, 255)])
        let menuBar = band([(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255)])
        let color = try #require(StripColor.backdropColor(composite: composite, menuBarLayer: menuBar))
        #expect(color.byteTriple == [14, 15, 27])
    }

    @Test func anOpaqueBackdropKeepsItsColourAndLeavesLightTextOut() throws {
        // "Show menu bar background" or Reduce Transparency: the bar layer is opaque everywhere,
        // text included, so the text has to be told apart by colour.
        let composite = band([(40, 40, 50, 255), (40, 40, 50, 255), (40, 40, 50, 255), (250, 250, 250, 255)])
        let menuBar = composite
        let color = try #require(StripColor.backdropColor(composite: composite, menuBarLayer: menuBar))
        #expect(color.byteTriple == [40, 40, 50])
    }

    @Test func aTintedBackdropWithAClearGapKeepsTheTint() throws {
        // One clear stretch of the bar layer (wallpaper showing through) must not stand in for the backdrop.
        let composite = band([(40, 40, 50, 255), (40, 40, 50, 255), (14, 15, 27, 255), (250, 250, 250, 255)])
        let menuBar = band([(30, 30, 30, 90), (30, 30, 30, 90), (0, 0, 0, 0), (255, 255, 255, 255)])
        let color = try #require(StripColor.backdropColor(composite: composite, menuBarLayer: menuBar))
        #expect(color.byteTriple == [40, 40, 50])
    }

    @Test func tellsAnOpaqueBarLayerFromAClearOne() {
        #expect(StripColor.isOpaqueBackdrop(band([(40, 40, 50, 255), (40, 40, 50, 255), (40, 40, 50, 255), (250, 250, 250, 255)])))
        #expect(!StripColor.isOpaqueBackdrop(band([(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255)])))
        #expect(!StripColor.isOpaqueBackdrop(band([(30, 30, 30, 90), (30, 30, 30, 90), (0, 0, 0, 0), (255, 255, 255, 255)])))
    }

    @Test func aTranslucentBackdropIsKeptAndTextOnItLeftOut() throws {
        let composite = band([(40, 40, 50, 255), (40, 40, 50, 255), (40, 40, 50, 255), (250, 250, 250, 255)])
        let menuBar = band([(30, 30, 30, 90), (30, 30, 30, 90), (30, 30, 30, 90), (255, 255, 255, 255)])
        let color = try #require(StripColor.backdropColor(composite: composite, menuBarLayer: menuBar))
        #expect(color.byteTriple == [40, 40, 50])
    }
}

@Suite @MainActor struct StripFallbackTests {
    @Test(arguments: [(NSAppearance.Name.darkAqua, StripInk.white), (.aqua, .black)])
    func fallbackIsOpaqueWithTheAppearancesInk(name: NSAppearance.Name, ink: StripInk) throws {
        let appearance = try #require(NSAppearance(named: name))
        let fill = StripColor.fallback(for: appearance)
        #expect(fill.cgColor.alpha == 1)
        #expect(StripColor.ink(for: fill) == ink)
    }
}

@Suite struct BackdropWindowMatchTests {
    typealias Window = BackdropWindowInfo

    @Test func picksTheMenubarBackdropAndTheWallpaper() {
        #expect(StripColorSampler.role(of: Window(title: "Menubar", bundleID: nil, layer: 24)) == .menuBar)
        #expect(StripColorSampler.role(of: Window(title: "Menubar", bundleID: "", layer: 24)) == .menuBar)
        #expect(StripColorSampler.role(of: Window(title: "Wallpaper", bundleID: "com.apple.WindowManager",
                                                  layer: -2_147_483_624)) == .wallpaper)
        #expect(StripColorSampler.role(of: Window(title: "Wallpaper", bundleID: "com.apple.dock",
                                                  layer: -2_147_483_624)) == .wallpaper)
    }

    @Test func ignoresStatusItemsAndAppWindows() {
        let others = [
            Window(title: "", bundleID: "com.apple.MenuBarAgent", layer: 24),           // status item bar
            Window(title: nil, bundleID: "com.zapps.yeehaw", layer: 25),                // YeeHaw's own item
            Window(title: "Menubar", bundleID: "com.example.app", layer: 24),           // an app's window
            Window(title: "Menubar", bundleID: nil, layer: 0),                          // a bundle-less app's window
            Window(title: "Wallpaper", bundleID: "com.example.wallpapers", layer: 0),   // an app named its window so
            Window(title: "Wallpaper", bundleID: nil, layer: 0),
            Window(title: "Dock", bundleID: "com.apple.dock", layer: 20),
            Window(title: "underbelly", bundleID: nil, layer: -2_147_483_602),
        ]
        for window in others {
            #expect(StripColorSampler.role(of: window) == nil, "\(window)")
        }
    }
}

/// Hands out scripted capture results and counts the calls.
final class ScriptedCapture: Sendable {
    let calls = Mutex(0)
    let results: [StripColorSampler.Outcome]
    let delays: [Duration]

    init(_ results: [StripColorSampler.Outcome], delays: [Duration] = []) {
        self.results = results
        self.delays = delays
    }

    var capture: StripColorSampler.Capture {
        { [self] _, _ in
            let call = calls.withLock { value in
                defer { value += 1 }
                return value
            }
            if call < delays.count { try? await Task.sleep(for: delays[call]) }
            return results[min(call, results.count - 1)]
        }
    }
}

@MainActor final class Permission {
    var granted = true
}

@Suite @MainActor struct StripColorSamplerTests {
    static let navy = StripRGB(bytes: 14, 15, 27)
    static let grey = StripRGB(bytes: 120, 120, 120)

    @Test func aSuccessIsCached() async {
        let sampler = StripColorSampler(permitted: { true }, capture: ScriptedCapture([.sampled(Self.navy)]).capture)
        #expect(await sampler.sample(display: 1, barHeight: 39) == .sampled(Self.navy))
        #expect(sampler.cached(for: 1) == Self.navy)
        #expect(sampler.cached(for: 2) == nil)
    }

    @Test func losingScreenRecordingClearsTheCache() async {
        let permission = Permission()
        let script = ScriptedCapture([.sampled(Self.navy)])
        let sampler = StripColorSampler(permitted: { permission.granted }, capture: script.capture)
        _ = await sampler.sample(display: 1, barHeight: 39)
        permission.granted = false
        #expect(await sampler.sample(display: 1, barHeight: 39) == .noPermission)
        #expect(sampler.cached(for: 1) == nil)
        #expect(script.calls.withLock { $0 } == 1)
    }

    @Test func aTransientFailureKeepsTheLastGoodColour() async {
        let sampler = StripColorSampler(permitted: { true },
                                        capture: ScriptedCapture([.sampled(Self.navy), .failed("capture failed: timeout")]).capture)
        _ = await sampler.sample(display: 1, barHeight: 39)
        #expect(await sampler.sample(display: 1, barHeight: 39) == .failed("capture failed: timeout"))
        #expect(sampler.cached(for: 1) == Self.navy)
    }

    @Test func anOlderSampleFinishingLastIsDropped() async throws {
        // The first capture is slow and returns grey; the second, started later, returns navy first.
        let script = ScriptedCapture([.sampled(Self.grey), .sampled(Self.navy)], delays: [.milliseconds(300)])
        let sampler = StripColorSampler(permitted: { true }, capture: script.capture)
        let older = Task { await sampler.sample(display: 1, barHeight: 39) }
        while script.calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await sampler.sample(display: 1, barHeight: 39) == .sampled(Self.navy))
        #expect(await older.value == .sampled(Self.grey))
        #expect(sampler.cached(for: 1) == Self.navy)
    }
}
