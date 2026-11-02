import AppKit
import Testing
import YeeHawCore
@testable import YeeHaw

@Suite struct StripPlacementTests {
    /// The owner's screen: 2056×1329 with a 39 pt menu bar.
    static let screen = NSRect(x: 0, y: 0, width: 2056, height: 1329)
    static let visible = NSRect(x: 0, y: 0, width: 2056, height: 1290)
    static let barHeight: CGFloat = 39
    /// YeeHaw's hat button: only 22×22, inside the bar.
    static let hat = NSRect(x: 1517, y: 1298.5, width: 22, height: 22)

    @Test func hangsCentredUnderTheHatOnePointBelowTheBar() {
        let frame = StripPanel.stripFrame(size: NSSize(width: 48, height: 39), under: Self.hat, screen: Self.screen,
                                          barHeight: Self.barHeight, inset: 6)
        #expect(frame == NSRect(x: 1528 - 24, y: 1329 - 39 - 1 - 39, width: 48, height: 39))
        #expect(frame.maxY == 1289)
        #expect(StripPanel.gap == 1)
        #expect(StripPanel.screenInset == 6)
    }

    @Test func heightComesFromTheScreensTopInsetNotTheAnchor() {
        #expect(StripPanel.barHeight(screenFrame: Self.screen, visibleFrame: Self.visible, fallback: 37) == 39)
        let secondary = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        #expect(StripPanel.barHeight(screenFrame: secondary, visibleFrame: NSRect(x: -1440, y: 80, width: 1440, height: 796),
                                     fallback: 24) == 24)
    }

    @Test func aHiddenMenuBarUsesTheFallbackHeight() {
        // The caller passes max(safe-area top inset, status bar thickness).
        #expect(StripPanel.barHeight(screenFrame: Self.screen, visibleFrame: Self.screen, fallback: 37) == 37)
    }

    @Test func cornerRadiusIsAQuarterOfTheHeight() {
        #expect(StripPanel.cornerRadius(barHeight: 39) == 9.75)
        #expect(StripPanel.cornerRadius(barHeight: 24) == 6)
    }

    @Test func staysInsideTheRightEdge() {
        let anchor = NSRect(x: 2030, y: 1298.5, width: 22, height: 22)
        let frame = StripPanel.stripFrame(size: NSSize(width: 200, height: 39), under: anchor, screen: Self.screen,
                                          barHeight: Self.barHeight, inset: 6)
        #expect(frame.maxX == 2050)
        #expect(frame.width == 200)
    }

    @Test func staysInsideTheLeftEdgeOfADisplayAtNegativeX() {
        let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let anchor = NSRect(x: -1430, y: 877, width: 22, height: 22)
        let frame = StripPanel.stripFrame(size: NSSize(width: 200, height: 24), under: anchor, screen: screen,
                                          barHeight: 24, inset: 6)
        #expect(frame.minX == -1434)
        let barBottom: CGFloat = 900 - 24 - 1
        #expect(frame.maxY == barBottom)
    }

    @Test func neverWiderThanTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 300, height: 800)
        let frame = StripPanel.stripFrame(size: NSSize(width: 900, height: 24),
                                          under: NSRect(x: 150, y: 777, width: 22, height: 22), screen: screen,
                                          barHeight: 24, inset: 6)
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
    static let barHeight: CGFloat = 39

    static func model(entries: Int, glyph: NSSize = NSSize(width: 16, height: 16),
                      maxWidth: CGFloat = .greatestFiniteMagnitude) -> StripModel {
        let model = StripModel(onSelect: { _ in })
        let image = NSImage(size: glyph)
        model.entries = (0..<entries).map { StripEntry(id: "com.example.app\($0)", image: image, name: "App \($0)") }
        model.maxWidth = maxWidth
        model.barHeight = barHeight
        return model
    }

    @Test func oneGlyphIsOneBarItemAsTallAsTheBar() {
        let size = StripPanel.measure(Self.model(entries: 1))
        #expect(size == NSSize(width: 16 + 20 + 2 * 6, height: Self.barHeight))
    }

    @Test func tilesTouchLikeTheBarsItems() {
        let size = StripPanel.measure(Self.model(entries: 3))
        let expected: CGFloat = 3 * (16 + 20) + 2 * 6
        #expect(size.width == expected)
    }

    @Test func glyphsScaleDownButNeverUp() {
        #expect(GlyphMetrics.size(NSSize(width: 10, height: 12)) == NSSize(width: 10, height: 12))
        #expect(GlyphMetrics.size(NSSize(width: 20, height: 36)) == NSSize(width: 10, height: 18))
        #expect(GlyphMetrics.size(NSSize(width: 30, height: 18)) == NSSize(width: 30, height: 18))
        let tall = StripPanel.measure(Self.model(entries: 1, glyph: NSSize(width: 40, height: 40)))
        #expect(tall == NSSize(width: 18 + 20 + 2 * 6, height: Self.barHeight))
    }

    @Test func theEmptyStateIsOneBarHighRow() {
        let size = StripPanel.measure(Self.model(entries: 0))
        #expect(size.width > 200)
        #expect(size.height == Self.barHeight)
    }

    @Test func aNoticeAddsABarHighRow() {
        let model = Self.model(entries: 1)
        model.notice = StripNotice(message: "YeeHaw needs access to the Menu Bar Allow List.", action: .openSettings)
        #expect(StripPanel.measure(model).height == 2 * Self.barHeight)
        model.entries = []
        #expect(StripPanel.measure(model).height == 2 * Self.barHeight)
    }

    @Test func tooManyTilesScrollWithinTheScreen() {
        let model = Self.model(entries: 60, maxWidth: 800)
        #expect(StripView.tilesWidth(model.entries) > 800)
        let size = StripPanel.measure(model)
        #expect(size.width <= 800)
        #expect(size.width > 700)
        #expect(size.height == Self.barHeight)
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

@Suite @MainActor struct StripKeyboardTests {
    @Test func arrowsWalkTheTilesAndWrapLikeAMenu() {
        let ids = ["a", "b", "c"]
        #expect(StripModel.moved(nil, in: ids, by: 1) == "a")
        #expect(StripModel.moved(nil, in: ids, by: -1) == "c")
        #expect(StripModel.moved("a", in: ids, by: 1) == "b")
        #expect(StripModel.moved("c", in: ids, by: 1) == "a")
        #expect(StripModel.moved("a", in: ids, by: -1) == "c")
        #expect(StripModel.moved("gone", in: ids, by: 1) == "a")
        #expect(StripModel.moved("a", in: [], by: 1) == nil)
    }

    @Test func onlyAStripOpenedWithoutThePointerLightsItsFirstTile() {
        #expect(StatusItemController.isPointerEvent(.leftMouseDown))
        #expect(StatusItemController.isPointerEvent(.leftMouseUp))
        #expect(!StatusItemController.isPointerEvent(.keyDown))
        #expect(!StatusItemController.isPointerEvent(nil))
    }
}

@Suite @MainActor struct StripNoticeTests {
    static func notice(_ grants: Set<GrantedFile> = [], _ problem: StatusItemController.RevealProblem? = nil,
                       ownIconMissing: Bool = false) -> StripNotice? {
        StatusItemController.notice(needsGrant: grants, problem: problem, ownIconMissing: ownIconMissing,
                                    name: { $0 == "dig" ? "DigUp" : $0 })
    }

    @Test func nothingWrongShowsNothing() {
        #expect(Self.notice() == nil)
    }

    @Test func onlyAMissingGrantOffersSettings() {
        let one = Self.notice([.positions])
        #expect(one == StripNotice(message: "YeeHaw needs access to the Menu Bar Layout.", action: .openSettings))
        #expect(one?.actionTitle == "Fix…")
        #expect(Self.notice([.positions, .allowList])?.message
            == "YeeHaw needs access to the Menu Bar Allow List and the Menu Bar Layout.")
        // It comes before any reveal problem.
        #expect(Self.notice([.allowList], .didNotAppear("dig"))?.action == .openSettings)
    }

    @Test func aSlowRevealOffersToTryAgain() {
        let notice = Self.notice([], .didNotAppear("dig"))
        #expect(notice == StripNotice(message: "DigUp didn’t appear in the menu bar in time.", action: .retry("dig")))
        #expect(notice?.actionTitle == "Try Again")
    }

    @Test func anAppThatIsntRunningOffersToOpenIt() {
        let notice = Self.notice([], .notRunning("dig"))
        #expect(notice?.action == .openApp("dig"))
        #expect(notice?.actionTitle == "Open")
    }

    @Test func problemsSettingsCantFixHaveNoButton() {
        #expect(Self.notice([], .failed("dig"))?.action == nil)
        #expect(Self.notice([], .failed("dig"))?.actionTitle == nil)
        #expect(Self.notice(ownIconMissing: true) == StripNotice(message: "YeeHaw can’t find its own menu bar icon."))
    }
}
