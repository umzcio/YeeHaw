import AppKit

// The picture behind the YeeHaw installer window, drawn by scripts/release.sh: a wanted-poster frame
// on saddle leather, a sunburst behind the wordmark, a rope arrow, and a desert horizon. Finder
// coordinates are in points, and release.sh places the two icons where this draws their arrow and
// label pills (the app at x=200, Applications at x=520, both at y=218 from the top). A 2x PNG stays
// sharp on Retina screens.
// Usage: swift scripts/render-dmg-background.swift output.png
let size = NSSize(width: 720, height: 440)
let scale = 2
guard CommandLine.arguments.count == 2,
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: swift scripts/render-dmg-background.swift output.png")
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func font(_ name: String, _ size: CGFloat, fallback weight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
}
// The app icon's burnt orange and cream, on dark saddle leather.
let orange = color(0xD9622F)
let cream = color(0xF3E6D0)
let tan = color(0xB8987A)
let leatherTop = color(0x2E1C11)
let leatherBottom = color(0x150C07)
let shadow = color(0x0A0503)
let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [leatherBottom, leatherTop])!.draw(in: bounds, angle: 90)

// Sunburst behind the wordmark: wedges of orange fading out from a point just above it.
let burstCenter = NSPoint(x: size.width / 2, y: size.height - 96)
let rays = 28
for ray in stride(from: 0, to: rays, by: 2) {
    let start = CGFloat(ray) / CGFloat(rays) * 360
    let wedge = NSBezierPath()
    wedge.move(to: burstCenter)
    wedge.appendArc(withCenter: burstCenter, radius: 520, startAngle: start, endAngle: start + 360 / CGFloat(rays))
    wedge.close()
    NSGraphicsContext.saveGraphicsState()
    wedge.addClip()
    NSGradient(colors: [orange.withAlphaComponent(0.13), orange.withAlphaComponent(0)])!
        .draw(fromCenter: burstCenter, radius: 0, toCenter: burstCenter, radius: 300, options: [])
    NSGraphicsContext.restoreGraphicsState()
}

// Desert horizon: a mesa ridge with two saguaros, darker than the leather.
let ridge = NSBezierPath()
ridge.move(to: NSPoint(x: 0, y: 0))
for (x, y) in [(0, 34), (70, 34), (84, 52), (150, 52), (166, 30), (300, 26), (420, 28), (470, 44),
               (520, 44), (536, 24), (610, 22), (628, 40), (676, 40), (690, 30), (720, 30), (720, 0)]
    as [(CGFloat, CGFloat)] {
    ridge.line(to: NSPoint(x: x, y: y))
}
ridge.close()
shadow.withAlphaComponent(0.55).setFill()
ridge.fill()

func saguaro(at x: CGFloat, base: CGFloat, height: CGFloat, mirrored: Bool) {
    let w = height * 0.16
    let side: CGFloat = mirrored ? -1 : 1
    let cactus = NSBezierPath(roundedRect: NSRect(x: x - w / 2, y: base, width: w, height: height),
                              xRadius: w / 2, yRadius: w / 2)
    // Two arms, one on each side, at different heights.
    for (armY, armTop, dir) in [(0.38, 0.78, side), (0.52, 0.86, -side)] as [(CGFloat, CGFloat, CGFloat)] {
        let reach = height * 0.24
        let elbowX = x + dir * reach
        let elbow = NSBezierPath()
        elbow.lineWidth = w * 0.8
        elbow.lineCapStyle = .round
        elbow.lineJoinStyle = .round
        elbow.move(to: NSPoint(x: x, y: base + height * armY))
        elbow.line(to: NSPoint(x: elbowX, y: base + height * armY))
        elbow.line(to: NSPoint(x: elbowX, y: base + height * armTop))
        shadow.withAlphaComponent(0.8).setStroke()
        elbow.stroke()
    }
    shadow.withAlphaComponent(0.8).setFill()
    cactus.fill()
}
saguaro(at: 112, base: 30, height: 64, mirrored: false)
saguaro(at: 588, base: 22, height: 50, mirrored: true)

// Wanted-poster frame: a double rule with a star in each corner.
tan.withAlphaComponent(0.32).setStroke()
for inset: CGFloat in [12, 17] {
    let rule = NSBezierPath(rect: bounds.insetBy(dx: inset, dy: inset))
    rule.lineWidth = 1
    rule.stroke()
}
func star(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    for point in 0..<10 {
        let r = point % 2 == 0 ? radius : radius * 0.42
        let angle = CGFloat.pi / 2 + CGFloat(point) * .pi / 5
        let p = NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        point == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.close()
    return path
}
for corner in [NSPoint(x: 14.5, y: 14.5), NSPoint(x: size.width - 14.5, y: 14.5),
               NSPoint(x: 14.5, y: size.height - 14.5), NSPoint(x: size.width - 14.5, y: size.height - 14.5)] {
    leatherBottom.setFill()
    NSBezierPath(ovalIn: NSRect(x: corner.x - 7, y: corner.y - 7, width: 14, height: 14)).fill()
    orange.setFill()
    star(center: corner, radius: 6).fill()
}

let center = NSMutableParagraphStyle()
center.alignment = .center

// "HOWDY, PARTNER" between two short rules and stars, like a saloon sign.
let howdy = NSAttributedString(string: "HOWDY, PARTNER", attributes: [
    .font: font("Copperplate-Bold", 12, fallback: .semibold), .foregroundColor: tan, .kern: 3,
])
let howdyY = size.height - 52
let howdySize = howdy.size()
howdy.draw(at: NSPoint(x: (size.width - howdySize.width) / 2 + 1.5, y: howdyY - howdySize.height / 2))
for dir: CGFloat in [-1, 1] {
    let inner = size.width / 2 + dir * (howdySize.width / 2 + 12)
    let outer = inner + dir * 34
    tan.withAlphaComponent(0.6).setStroke()
    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: inner, y: howdyY))
    rule.line(to: NSPoint(x: outer, y: howdyY))
    rule.lineWidth = 1
    rule.stroke()
    orange.setFill()
    star(center: NSPoint(x: outer + dir * 8, y: howdyY), radius: 4.5).fill()
}

// YeeHaw's hat (the menu bar glyph, StatusGlyph.hat in the app: an 18x18 box, y up).
func hat(in box: NSRect) -> NSBezierPath {
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
    var transform = AffineTransform(translationByX: box.minX, byY: box.minY)
    transform.scale(box.width / 18)
    p.transform(using: transform)
    return p
}

// Wordmark: the hat, then "YeeHaw" in a Clarendon, with a pressed-in shadow; centred as one unit.
let word = NSAttributedString(string: "YeeHaw", attributes: [
    .font: font("Superclarendon-Black", 40, fallback: .heavy), .foregroundColor: cream,
])
let wordShadow = NSAttributedString(string: "YeeHaw", attributes: [
    .font: font("Superclarendon-Black", 40, fallback: .heavy), .foregroundColor: shadow.withAlphaComponent(0.7),
])
let markSize: CGFloat = 54
let gap: CGFloat = 8
let wordSize = word.size()
let totalWidth = markSize + gap + wordSize.width
let originX = (size.width - totalWidth) / 2
let wordmarkMidY = size.height - 102
let hatBox = NSRect(x: originX, y: wordmarkMidY - markSize / 2 + 2, width: markSize, height: markSize)
shadow.withAlphaComponent(0.7).setFill()
hat(in: hatBox.offsetBy(dx: 2, dy: -2)).fill()
orange.setFill()
hat(in: hatBox).fill()
let wordOrigin = NSPoint(x: originX + markSize + gap, y: wordmarkMidY - wordSize.height / 2)
wordShadow.draw(at: NSPoint(x: wordOrigin.x + 2, y: wordOrigin.y - 2))
word.draw(at: wordOrigin)

// The arrow is artwork, a rope with an orange head; both icons stay real, draggable items. The
// rope arcs up and back down, centred between the icons, and runs into the head's notch; the
// head points the way the rope is heading where it ends.
let arrowY: CGFloat = size.height - 218
let ropeEnd = NSPoint(x: 388, y: arrowY - 2)
let ropeControl2 = NSPoint(x: 364, y: arrowY + 8)
let rope = NSBezierPath()
rope.move(to: NSPoint(x: 318, y: arrowY - 2))
rope.curve(to: ropeEnd, controlPoint1: NSPoint(x: 342, y: arrowY + 8), controlPoint2: ropeControl2)
rope.lineCapStyle = .round
rope.lineWidth = 4
tan.setStroke()
rope.stroke()
// The twist: short dark dashes along the rope.
rope.lineCapStyle = .butt
rope.setLineDash([1.6, 3.2], count: 2, phase: 0)
color(0x6E5440).setStroke()
rope.stroke()
// Drawn pointing along +x with the notch at the origin, then turned and moved onto the rope's end.
let head = NSBezierPath()
head.move(to: NSPoint(x: 12, y: 0))
head.line(to: NSPoint(x: -4, y: 7.5))
head.line(to: NSPoint(x: 0, y: 0))
head.line(to: NSPoint(x: -4, y: -7.5))
head.close()
var place = AffineTransform(translationByX: ropeEnd.x, byY: ropeEnd.y)
place.rotate(byRadians: atan2(ropeEnd.y - ropeControl2.y, ropeEnd.x - ropeControl2.x))
head.transform(using: place)
orange.setFill()
head.fill()

// Finder always draws dark filename text over a custom picture; cream pills behind the real
// filenames keep them readable without faking the labels.
for (centerX, width): (CGFloat, CGFloat) in [(200, 100), (520, 140)] {
    let pill = NSBezierPath(roundedRect: NSRect(x: centerX - width / 2, y: size.height - 309, width: width, height: 30),
                            xRadius: 10, yRadius: 10)
    cream.setFill()
    pill.fill()
    orange.withAlphaComponent(0.55).setStroke()
    pill.lineWidth = 1
    pill.stroke()
}

let line = NSMutableAttributedString(string: "Drag YeeHaw to Applications, partner. ", attributes: [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: tan, .paragraphStyle: center,
])
line.append(NSAttributedString(string: "Yeeeehaw!", attributes: [
    .font: font("Superclarendon-Bold", 15, fallback: .bold), .foregroundColor: orange, .paragraphStyle: center,
]))
line.draw(in: NSRect(x: 30, y: size.height - 343 - 40, width: size.width - 60, height: 40))

NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode the background") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
