import AppKit
import Testing
@testable import YeeHaw

@Suite struct StripPlacementTests {
    static let visible = NSRect(x: 0, y: 0, width: 2056, height: 1290)
    static let size = NSSize(width: 200, height: 36)

    @Test func centresUnderTheIconJustBelowTheMenuBar() {
        let anchor = NSRect(x: 1000, y: 1290, width: 30, height: 39)
        let frame = StripPanel.stripFrame(size: Self.size, below: anchor, within: Self.visible, inset: 8)
        #expect(frame == NSRect(x: 915, y: 1290 - StripPanel.gap - 36, width: 200, height: 36))
    }

    @Test func staysInsideTheRightEdge() {
        let anchor = NSRect(x: 2000, y: 1290, width: 30, height: 39)
        let frame = StripPanel.stripFrame(size: Self.size, below: anchor, within: Self.visible, inset: 8)
        #expect(frame.maxX == 2048)
    }

    @Test func staysInsideTheLeftEdgeOfASecondDisplay() {
        let visible = NSRect(x: -1440, y: 0, width: 1440, height: 875)
        let anchor = NSRect(x: -1430, y: 875, width: 30, height: 24)
        let frame = StripPanel.stripFrame(size: Self.size, below: anchor, within: visible, inset: 8)
        #expect(frame.minX == -1432)
        #expect(frame.maxY == 875 - StripPanel.gap)
    }

    @Test func neverWiderThanTheScreen() {
        let visible = NSRect(x: 0, y: 0, width: 300, height: 800)
        let frame = StripPanel.stripFrame(size: NSSize(width: 900, height: 36),
                                          below: NSRect(x: 150, y: 800, width: 30, height: 24), within: visible, inset: 8)
        #expect(frame.minX == 8)
        #expect(frame.width == 284)
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
    static func model(entries: Int, maxWidth: CGFloat = .greatestFiniteMagnitude) -> StripModel {
        let model = StripModel(onSelect: { _ in }, onFix: {})
        let image = NSImage(size: NSSize(width: 18, height: 18))
        model.entries = (0..<entries).map { StripEntry(id: "com.example.app\($0)", image: image, name: "App \($0)") }
        model.maxWidth = maxWidth
        return model
    }

    @Test func measuresOneEntry() {
        let size = StripPanel.measure(Self.model(entries: 1))
        // One 32 pt tile + "…" + padding, one 28 pt row + padding.
        #expect(size.width >= StripView.minTileWidth + StripView.moreWidth)
        #expect(size.height == StripView.tileHeight + 2 * StripView.padding)
    }

    @Test func measuresTheEmptyState() {
        let size = StripPanel.measure(Self.model(entries: 0))
        #expect(size.width > 100)
        #expect(size.height == StripView.tileHeight + 2 * StripView.padding)
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
        #expect(size.height == StripView.tileHeight + 2 * StripView.padding)
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

@Suite(.serialized) @MainActor struct HighlightKeeperTests {
    final class Button { var highlighted = false; var sets = 0 }

    /// Runs the main run loop in `mode` for a moment. A timer keeps it from returning at once
    /// for want of sources, so it really waits (and fires before-waiting observers).
    static func spin(_ mode: RunLoop.Mode) {
        let timer = Timer(timeInterval: 0.02, repeats: false) { _ in }
        RunLoop.main.add(timer, forMode: mode)
        RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: 0.05))
        timer.invalidate()
    }

    static func keeper(_ button: Button) -> HighlightKeeper {
        HighlightKeeper(isHighlighted: { button.highlighted },
                        setHighlighted: { button.highlighted = $0; button.sets += 1 })
    }

    @Test func restoresAHighlightClearedByTrackingOnlyOutsideTracking() {
        let button = Button()
        let keeper = Self.keeper(button)
        keeper.start()
        #expect(button.highlighted)
        button.highlighted = false // the button's tracking ended and cleared it
        Self.spin(.eventTracking)
        #expect(!button.highlighted)
        Self.spin(.default)
        #expect(button.highlighted)
        keeper.stop()
        #expect(!button.highlighted)
        #expect(!keeper.isActive)
    }

    @Test func stoppedKeeperLeavesTheButtonAlone() {
        let button = Button()
        let keeper = Self.keeper(button)
        keeper.start()
        keeper.stop()
        let sets = button.sets
        button.highlighted = true
        Self.spin(.default)
        #expect(button.highlighted)
        #expect(button.sets == sets)
    }
}
