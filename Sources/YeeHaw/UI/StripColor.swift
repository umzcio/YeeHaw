import AppKit
import SwiftUI

/// An opaque sRGB colour, each channel 0...1.
struct StripRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From 8-bit sRGB channels.
    init(bytes red: Int, _ green: Int, _ blue: Int) {
        self.init(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// The channels rounded to 8 bits.
    var byteTriple: [Int] {
        [red, green, blue].map { Int(($0 * 255).rounded()) }
    }
}

/// The colour the strip's glyphs and text are drawn in.
enum StripInk: Equatable, Sendable {
    case black, white

    var color: Color {
        self == .white ? .white : .black
    }
}

/// The strip's colour maths: what to draw on a fill, and the fill itself from a capture or the
/// appearance.
enum StripColor {
    /// WCAG 2 relative luminance of an sRGB colour.
    static func relativeLuminance(_ color: StripRGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// WCAG 2 contrast ratio between two relative luminances (1...21).
    static func contrastRatio(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Black or white, whichever contrasts more with `fill`.
    static func ink(for fill: StripRGB) -> StripInk {
        let luminance = relativeLuminance(fill)
        return contrastRatio(luminance, 1) > contrastRatio(luminance, 0) ? .white : .black
    }

    /// The mean colour of `image`'s pixels, weighted by their alpha so the result is opaque. Nil
    /// when the image is entirely clear.
    static func averageColor(of image: CGImage) -> StripRGB? {
        guard let pixels = GlyphImage.Pixels(image) else { return nil }
        return average(pixels) { _, _ in true }
    }

    /// The bar's backdrop colour from a band captured twice: `composite` (the bar's backdrop over
    /// the wallpaper) and `menuBarLayer` (the bar's own window alone, which on 27.2 also draws the
    /// app menus and the clock).
    ///
    /// The backdrop is what most of the band is. When the bar layer is translucent or clear, that
    /// is the pixels at its most common alpha: text is more opaque, and a clear gap less. When the
    /// layer is opaque ("Show menu bar background", Reduce Transparency), text has the same alpha
    /// as the backdrop, so the backdrop is the pixels near the composite's most common colour.
    static func backdropColor(composite: CGImage, menuBarLayer: CGImage) -> StripRGB? {
        guard let colors = GlyphImage.Pixels(composite), let layer = GlyphImage.Pixels(menuBarLayer),
              colors.width == layer.width, colors.height == layer.height else { return nil }
        let alpha = modalAlpha(layer)
        if alpha >= opaqueAlpha {
            let mode = modalColorBin(colors)
            return average(colors) { x, y in
                let bin = colorBin(colors[x, y])
                return abs(bin.0 - mode.0) <= 1 && abs(bin.1 - mode.1) <= 1 && abs(bin.2 - mode.2) <= 1
            }
        }
        return average(colors) { x, y in abs(Int(layer[x, y].3) - alpha) <= backdropAlphaTolerance }
    }

    /// Whether the bar layer is opaque across most of the band, hiding the wallpaper.
    static func isOpaqueBackdrop(_ layer: CGImage) -> Bool {
        guard let pixels = GlyphImage.Pixels(layer) else { return false }
        return modalAlpha(pixels) >= opaqueAlpha
    }

    /// How far from the bar layer's most common alpha (0...255) a pixel may be and still count as backdrop.
    static let backdropAlphaTolerance = 8
    /// The bar layer's most common alpha at or above which it counts as opaque.
    static let opaqueAlpha = 250
    /// Width of a colour bin, per 8-bit channel, when finding the most common colour.
    static let colorBinWidth = 8

    /// The most common alpha among `pixels`.
    private static func modalAlpha(_ pixels: GlyphImage.Pixels) -> Int {
        var counts = [Int](repeating: 0, count: 256)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width { counts[Int(pixels[x, y].3)] += 1 }
        }
        return counts.indices.max { counts[$0] < counts[$1] } ?? 0
    }

    private static func colorBin(_ pixel: (UInt8, UInt8, UInt8, UInt8)) -> (Int, Int, Int) {
        (Int(pixel.0) / colorBinWidth, Int(pixel.1) / colorBinWidth, Int(pixel.2) / colorBinWidth)
    }

    /// The colour bin holding the most of `pixels`.
    private static func modalColorBin(_ pixels: GlyphImage.Pixels) -> (Int, Int, Int) {
        var counts: [Int: Int] = [:]
        var best = (key: 0, count: 0)
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let bin = colorBin(pixels[x, y])
                let key = (bin.0 << 16) | (bin.1 << 8) | bin.2
                let count = counts[key, default: 0] + 1
                counts[key] = count
                if count > best.count { best = (key, count) }
            }
        }
        return (best.key >> 16, (best.key >> 8) & 0xFF, best.key & 0xFF)
    }

    /// The opaque neutral used when the bar can't be sampled: the window background colour as
    /// `appearance` draws it.
    @MainActor
    static func fallback(for appearance: NSAppearance) -> StripRGB {
        var resolved = StripRGB(red: 0.5, green: 0.5, blue: 0.5)
        appearance.performAsCurrentDrawingAppearance {
            if let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) {
                resolved = StripRGB(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
            }
        }
        return resolved
    }

    /// Mean of the selected pixels' un-premultiplied colour, weighted by alpha.
    private static func average(_ pixels: GlyphImage.Pixels, including: (Int, Int) -> Bool) -> StripRGB? {
        var red = 0, green = 0, blue = 0, alpha = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where including(x, y) {
                let (r, g, b, a) = pixels[x, y]
                red += Int(r); green += Int(g); blue += Int(b); alpha += Int(a)
            }
        }
        guard alpha > 0 else { return nil }
        // Premultiplied channels summed over alpha: each pixel's colour weighted by its coverage.
        let total = Double(alpha)
        return StripRGB(red: Double(red) / total, green: Double(green) / total, blue: Double(blue) / total)
    }
}
