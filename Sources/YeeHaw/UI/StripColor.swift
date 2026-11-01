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
    /// app menus and the clock). Only columns where the bar layer is at its least opaque count, so
    /// menu titles and system items are left out whether the backdrop is clear or tinted.
    static func backdropColor(composite: CGImage, menuBarLayer: CGImage) -> StripRGB? {
        guard let colors = GlyphImage.Pixels(composite), let layer = GlyphImage.Pixels(menuBarLayer),
              colors.width == layer.width, colors.height == layer.height else { return nil }
        var least = UInt8.max
        for y in 0..<layer.height {
            for x in 0..<layer.width { least = min(least, layer[x, y].3) }
        }
        let limit = Int(least) + backdropAlphaTolerance
        return average(colors) { x, y in Int(layer[x, y].3) <= limit }
    }

    /// How far above the bar layer's least alpha (0...255) a pixel may be and still count as backdrop.
    static let backdropAlphaTolerance = 8

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
