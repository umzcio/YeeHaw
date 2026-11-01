import AppKit
import Testing
@testable import YeeHaw

@Suite struct StripPlacementTests {
    static let visible = NSRect(x: 0, y: 0, width: 2056, height: 1290)
    static let size = NSSize(width: 200, height: 34)

    @Test func hangsFromTheBarWithItsLeadingEdgeUnderTheIcon() {
        // YeeHaw's icon on the owner's Mac: x 1514, 24 wide, in a 39 pt bar.
        let anchor = NSRect(x: 1514, y: 1290, width: 24, height: 39)
        let frame = StripPanel.stripFrame(size: NSSize(width: 45, height: 34), below: anchor, within: Self.visible, inset: 6)
        #expect(frame == NSRect(x: 1509.5, y: 1290 - 1 - 34, width: 45, height: 34))
        #expect(StripPanel.gap == 1)
        #expect(StripPanel.leadingInset == 4.5)
    }

    @Test func staysInsideTheRightEdge() {
        let anchor = NSRect(x: 2000, y: 1290, width: 30, height: 39)
        let frame = StripPanel.stripFrame(size: Self.size, below: anchor, within: Self.visible, inset: 6)
        #expect(frame.maxX == 2050)
    }

    @Test func staysInsideTheLeftEdgeOfASecondDisplay() {
        let visible = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: -1438, y: 875, width: 30, height: 24)
        let frame = StripPanel.stripFrame(size: Self.size, below: anchor, within: visible, inset: 6)
        #expect(frame.minX == -1434)
        #expect(frame.maxY == 875 - StripPanel.gap)
    }

    @Test func neverWiderThanTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 300, height: 800)
        let frame = StripPanel.stripFrame(size: NSSize(width: 900, height: 34),
                                          below: NSRect(x: 150, y: 800, width: 30, height: 24), within: visible, inset: 6)
        #expect(frame.minX == 6)
        #expect(frame.width == 288)
    }
}

@Suite struct StatusIconTests {
    @Test func glyphIsAnEighteenPointTemplate() {
        let image = StatusGlyph.image()
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.isTemplate)
    }

    @Test func glyphFillsTheCrownAndKnocksOutTheBand() throws {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = StatusGlyph.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        StatusGlyph.image().draw(in: NSRect(origin: .zero, size: StatusGlyph.size))
        NSGraphicsContext.restoreGraphicsState()
        // colorAt uses a top-left origin in pixels; the glyph is y-up in points.
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            rep.colorAt(x: Int(x * 2), y: Int((18 - y) * 2))?.alphaComponent ?? 0
        }
        #expect(alpha(9, 11.5) > 0.9)  // crown
        #expect(alpha(9, 6) > 0.9)     // brim
        #expect(alpha(9, 9.6) < 0.1)   // band
        #expect(alpha(1, 1) < 0.1)     // outside
    }

    @Test(arguments: [
        (NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags(), true),
        (.leftMouseDown, .control, true),
        (.leftMouseDown, .option, true),
        (.leftMouseDown, .command, false),
        (.leftMouseDown, NSEvent.ModifierFlags(), false),
    ])
    func secondaryClicks(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags, secondary: Bool) {
        #expect(StatusItemController.isSecondaryClick(type: type, modifiers: modifiers) == secondary)
    }
}

@Suite @MainActor struct StripMeasureTests {
    static let rowHeight = StripView.tileHeight + 2 * StripView.verticalPadding

    static func model(entries: Int, maxWidth: CGFloat = .greatestFiniteMagnitude) -> StripModel {
        let model = StripModel(onSelect: { _ in }, onFix: {})
        let image = NSImage(size: NSSize(width: 16, height: 16))
        model.entries = (0..<entries).map { StripEntry(id: "com.example.app\($0)", image: image, name: "App \($0)") }
        model.maxWidth = maxWidth
        return model
    }

    @Test func oneEntryIsOneBarItemWide() {
        let size = StripPanel.measure(Self.model(entries: 1))
        // A 36 pt tile (like DigUp's item) between the padding; one 24 pt row.
        #expect(size == NSSize(width: 36 + 2 * StripPanel.leadingInset, height: Self.rowHeight))
        #expect(Self.rowHeight == 34)
    }

    @Test func tilesAbutLikeTheBarsItems() {
        let size = StripPanel.measure(Self.model(entries: 3))
        #expect(size.width == 3 * 36 + 2 * StripPanel.leadingInset)
    }

    @Test func measuresTheEmptyState() {
        let size = StripPanel.measure(Self.model(entries: 0))
        #expect(size.width > 200)
        #expect(size.height == Self.rowHeight)
    }

    @Test func aNoticeAddsALine() {
        let model = Self.model(entries: 1)
        let plain = StripPanel.measure(model)
        model.notice = "YeeHaw needs access to the menu bar settings files."
        #expect(StripPanel.measure(model).height > plain.height)
    }

    @Test func tooManyTilesScrollWithinTheScreen() {
        let model = Self.model(entries: 60, maxWidth: 800)
        #expect(StripView.tilesWidth(model.entries) > 800)
        let size = StripPanel.measure(model)
        #expect(size.width <= 800)
        #expect(size.width > 700)
        #expect(size.height == Self.rowHeight)
    }
}

@Suite struct IconClickTests {
    @Test func plainClicksToggleButNeverReopenWhatTheyJustClosed() {
        #expect(StatusItemController.clickAction(stripShown: true, sinceAutoDismissal: nil) == .close)
        #expect(StatusItemController.clickAction(stripShown: false, sinceAutoDismissal: nil) == .open)
        #expect(StatusItemController.clickAction(stripShown: false, sinceAutoDismissal: .milliseconds(50)) == .stayClosed)
        #expect(StatusItemController.clickAction(stripShown: false, sinceAutoDismissal: .milliseconds(400)) == .open)
    }
}

@Suite struct IconHitRectTests {
    @Test func coversTheIconsEdgesAndTheTopOfTheScreen() {
        let rect = StripPanel.iconHitRect(NSRect(x: 1514, y: 1290, width: 24, height: 39))
        #expect(rect.contains(NSPoint(x: 1538, y: 1317)))   // the right edge, where a click lands
        #expect(rect.contains(NSPoint(x: 1514, y: 1328.5))) // the left edge, top row
        #expect(!rect.contains(NSPoint(x: 1300, y: 1317)))  // elsewhere in the menu bar
        #expect(!rect.contains(NSPoint(x: 1526, y: 1250)))  // the strip area below
    }
}

@Suite struct ClickLocationTests {
    @Test func quartzPointsFlipIntoAppKitScreenCoordinates() {
        #expect(StripPanel.appKitScreenPoint(CGPoint(x: 1538, y: 12), primaryHeight: 1329) == NSPoint(x: 1538, y: 1317))
        #expect(StripPanel.appKitScreenPoint(nil, primaryHeight: 1329) == nil)
    }
}
