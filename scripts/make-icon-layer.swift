// Draws the app icon's hat layer: YeeHaw's status glyph (StatusGlyph.hat), white on clear,
// centred in a 1024 px canvas. Usage: swift scripts/make-icon-layer.swift Resources/AppIcon.icon/Assets/Hat.png
// Resources/AppIcon.icon is an Icon Composer icon; build-app.sh compiles it with actool.
import AppKit
let size = 1024.0
let scale = 44.0 // 18 pt box → 792 px
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let p = NSBezierPath()
p.windingRule = .evenOdd
p.move(to: NSPoint(x: 4.9, y: 8.0))
p.curve(to: NSPoint(x: 5.9, y: 14.9), controlPoint1: NSPoint(x: 4.9, y: 10.6), controlPoint2: NSPoint(x: 5.0, y: 13.9))
p.curve(to: NSPoint(x: 9.0, y: 13.2), controlPoint1: NSPoint(x: 7.0, y: 16.2), controlPoint2: NSPoint(x: 8.2, y: 13.2))
p.curve(to: NSPoint(x: 12.1, y: 14.9), controlPoint1: NSPoint(x: 9.8, y: 13.2), controlPoint2: NSPoint(x: 11.0, y: 16.2))
p.curve(to: NSPoint(x: 13.1, y: 8.0), controlPoint1: NSPoint(x: 13.0, y: 13.9), controlPoint2: NSPoint(x: 13.1, y: 10.6))
p.close()
p.move(to: NSPoint(x: 0.4, y: 11.0))
p.curve(to: NSPoint(x: 9.0, y: 7.0), controlPoint1: NSPoint(x: 1.6, y: 7.9), controlPoint2: NSPoint(x: 5.2, y: 7.0))
p.curve(to: NSPoint(x: 17.6, y: 11.0), controlPoint1: NSPoint(x: 12.8, y: 7.0), controlPoint2: NSPoint(x: 16.4, y: 7.9))
p.curve(to: NSPoint(x: 9.0, y: 5.0), controlPoint1: NSPoint(x: 16.9, y: 6.8), controlPoint2: NSPoint(x: 13.2, y: 5.0))
p.curve(to: NSPoint(x: 0.4, y: 11.0), controlPoint1: NSPoint(x: 4.8, y: 5.0), controlPoint2: NSPoint(x: 1.1, y: 6.8))
p.close()
p.appendRect(NSRect(x: 4.95, y: 9.1, width: 8.1, height: 1.0))
// The glyph's ink spans y 5.0–~15.4, x 0.4–17.6; centre that box in the canvas.
let ink = p.bounds
var t = AffineTransform()
t.translate(x: size / 2 - ink.midX * scale, y: size / 2 - ink.midY * scale)
t.scale(scale)
p.transform(using: t)
NSColor.white.setFill()
p.fill()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
