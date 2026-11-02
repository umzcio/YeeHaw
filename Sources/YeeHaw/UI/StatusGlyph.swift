import AppKit

/// YeeHaw's menu bar glyph: the owner's chosen cowboy hat (glyph A). A template image, so the menu
/// bar tints it for light, dark and highlighted states; drawn from a vector path, so it's sharp at
/// every scale.
enum StatusGlyph {
    static let size = NSSize(width: 18, height: 18)

    static func image() -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            hat().fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "YeeHaw"
        return image
    }

    /// 18×18 pt box, y up. Filled with even-odd winding, so the hat band is knocked out.
    static func hat() -> NSBezierPath {
        let p = NSBezierPath()
        p.windingRule = .evenOdd
        // Crown: tapered sides, deep center crease, two lobes.
        p.move(to: NSPoint(x: 4.9, y: 8.0))
        p.curve(to: NSPoint(x: 5.9, y: 14.9), controlPoint1: NSPoint(x: 4.9, y: 10.6), controlPoint2: NSPoint(x: 5.0, y: 13.9))
        p.curve(to: NSPoint(x: 9.0, y: 13.2), controlPoint1: NSPoint(x: 7.0, y: 16.2), controlPoint2: NSPoint(x: 8.2, y: 13.2))
        p.curve(to: NSPoint(x: 12.1, y: 14.9), controlPoint1: NSPoint(x: 9.8, y: 13.2), controlPoint2: NSPoint(x: 11.0, y: 16.2))
        p.curve(to: NSPoint(x: 13.1, y: 8.0), controlPoint1: NSPoint(x: 13.0, y: 13.9), controlPoint2: NSPoint(x: 13.1, y: 10.6))
        p.close()
        // Brim: thin in the middle, tips swept up.
        p.move(to: NSPoint(x: 0.4, y: 11.0))
        p.curve(to: NSPoint(x: 9.0, y: 7.0), controlPoint1: NSPoint(x: 1.6, y: 7.9), controlPoint2: NSPoint(x: 5.2, y: 7.0))
        p.curve(to: NSPoint(x: 17.6, y: 11.0), controlPoint1: NSPoint(x: 12.8, y: 7.0), controlPoint2: NSPoint(x: 16.4, y: 7.9))
        p.curve(to: NSPoint(x: 9.0, y: 5.0), controlPoint1: NSPoint(x: 16.9, y: 6.8), controlPoint2: NSPoint(x: 13.2, y: 5.0))
        p.curve(to: NSPoint(x: 0.4, y: 11.0), controlPoint1: NSPoint(x: 4.8, y: 5.0), controlPoint2: NSPoint(x: 1.1, y: 6.8))
        p.close()
        // Hat band knocked out of the crown.
        p.appendRect(NSRect(x: 4.95, y: 9.1, width: 8.1, height: 1.0))
        return p
    }
}

/// How menu bar glyphs are sized wherever YeeHaw draws them (the strip, the Layout window, the
/// spacing preview): at their own size, scaled down to `maxHeight` if taller, never up.
enum GlyphMetrics {
    static let maxHeight: CGFloat = 18

    static func size(_ size: NSSize) -> NSSize {
        guard size.height > maxHeight, size.height > 0 else { return size }
        return NSSize(width: size.width * maxHeight / size.height, height: maxHeight)
    }
}
