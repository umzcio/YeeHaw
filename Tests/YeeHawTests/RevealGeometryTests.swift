import AppKit
import Testing
@testable import YeeHaw

@Suite struct RevealGeometryTests {
    /// The owner's screen (as in `StripPlacementTests`): 2056 × 1329 with a 39 pt bar.
    static let main = RevealGeometry.Screen(frame: NSRect(x: 0, y: 0, width: 2056, height: 1329), barHeight: 39)

    @Test func theScreensTopRowIsInTheMenuBar() {
        // NSRect.contains leaves out y == maxY; a click on the top row still counts.
        #expect(RevealGeometry.isInMenuBar(NSPoint(x: 1538, y: 1329), screens: [Self.main]))
        #expect(RevealGeometry.isInMenuBar(NSPoint(x: 1538, y: 1300), screens: [Self.main]))
        #expect(!RevealGeometry.isInMenuBar(NSPoint(x: 1538, y: 1289), screens: [Self.main]))
    }

    @Test func aClickOnTheRevealedIconIsOnIt() {
        let icon = 1521.0...1559.0
        #expect(RevealGeometry.isOnIcon(NSPoint(x: 1538, y: 1317), icon: icon, screens: [Self.main]))
        #expect(!RevealGeometry.isOnIcon(NSPoint(x: 1600, y: 1317), icon: icon, screens: [Self.main]))
        #expect(!RevealGeometry.isOnIcon(NSPoint(x: 1538, y: 1200), icon: icon, screens: [Self.main]))
    }

    @Test func aSecondDisplaysBarCounts() {
        let left = RevealGeometry.Screen(frame: NSRect(x: -1440, y: 0, width: 1440, height: 900), barHeight: 24)
        let screens = [Self.main, left]
        #expect(RevealGeometry.isInMenuBar(NSPoint(x: -700, y: 900), screens: screens))
        #expect(!RevealGeometry.isInMenuBar(NSPoint(x: -700, y: 870), screens: screens))
    }
}
