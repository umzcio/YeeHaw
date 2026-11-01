import AppKit
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

    @Test(arguments: 110...130)
    func midGreyGetsTheHigherContrastInk(level: Int) {
        let fill = StripRGB(bytes: level, level, level)
        let luminance = StripColor.relativeLuminance(fill)
        let onWhite = StripColor.contrastRatio(luminance, 1)
        let onBlack = StripColor.contrastRatio(luminance, 0)
        #expect(StripColor.ink(for: fill) == (onWhite > onBlack ? .white : .black))
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

@Suite struct StripAverageColorTests {
    @Test func aSolidImageReturnsItsColour() throws {
        let color = try #require(StripColor.averageColor(of: band([(14, 15, 27, 255)])))
        #expect(color.byteTriple == [14, 15, 27])
    }

    @Test func aTwoColourImageReturnsTheMean() throws {
        let color = try #require(StripColor.averageColor(of: band([(10, 20, 30, 255), (30, 60, 90, 255)])))
        #expect(color.byteTriple == [20, 40, 60])
    }

    @Test func theResultIsOpaque() throws {
        let color = try #require(StripColor.averageColor(of: band([(200, 100, 50, 128)])))
        #expect(color.cgColor.alpha == 1)
        #expect(color.byteTriple.enumerated().allSatisfy { abs($0.element - [200, 100, 50][$0.offset]) <= 1 })
    }

    @Test func aClearImageHasNoColour() {
        #expect(StripColor.averageColor(of: band([(0, 0, 0, 0)])) == nil)
    }

    @Test func menuTitlesInTheMenuBarLayerAreLeftOut() throws {
        // The bar layer is clear except for a white menu title over the last quarter.
        let composite = band([(14, 15, 27, 255), (14, 15, 27, 255), (14, 15, 27, 255), (255, 255, 255, 255)])
        let menuBar = band([(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (255, 255, 255, 255)])
        let color = try #require(StripColor.backdropColor(composite: composite, menuBarLayer: menuBar))
        #expect(color.byteTriple == [14, 15, 27])
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
