import Testing
@testable import YeeHawCore

@Suite struct MenuBarHealthTests {
    static let own = "com.zapps.yeehaw"
    static let home = "/Users/test"

    static func app(_ id: String, hidden: Bool = false, regular: Bool = false, path: String? = nil) -> RunningAppFacts {
        RunningAppFacts(bundleID: id, bundlePath: path ?? "/Applications/\(id).app", isHidden: hidden, isRegular: regular)
    }

    static func issue(_ health: MenuBarHealth, _ apps: [RunningAppFacts]) -> HealthIssue? {
        health.issue(among: apps, own: own, home: home)
    }

    @Test func stuckOnlyAfterTwoMissesInARow() {
        var health = MenuBarHealth()
        health.recordReveal("a", opened: false)
        #expect(!health.isStuck("a"))
        health.recordReveal("a", opened: false)
        #expect(health.isStuck("a"))
        health.recordReveal("a", opened: true)
        #expect(!health.isStuck("a"))
    }

    @Test func anOpenedRevealBetweenMissesResets() {
        var health = MenuBarHealth()
        health.recordReveal("a", opened: false)
        health.recordReveal("a", opened: true)
        health.recordReveal("a", opened: false)
        #expect(!health.isStuck("a"))
    }

    @Test func forgettingStartsAfresh() {
        var health = MenuBarHealth()
        health.recordReveal("a", opened: false)
        health.recordReveal("a", opened: false)
        health.forget("a")
        #expect(!health.isStuck("a"))
        health.recordReveal("a", opened: false)
        #expect(!health.isStuck("a"))
    }

    @Test func aHiddenMenuBarOnlyAppIsReported() {
        let found = Self.issue(MenuBarHealth(), [Self.app("a"), Self.app("b", hidden: true)])
        #expect(found == .hidden("b"))
    }

    @Test func aHiddenRegularAppAppleAppYeeHawOrStrayCopyIsNot() {
        let apps = [
            Self.app("o", hidden: true, regular: true),
            Self.app("com.apple.x", hidden: true),
            Self.app("com.zapps.yeehaw", hidden: true),
            Self.app("d", hidden: true, path: "/Users/test/dev/D.app"),
        ]
        #expect(Self.issue(MenuBarHealth(), apps) == nil)
    }

    @Test func hiddenBeatsStuckAndStuckNeedsToBeRunning() {
        var health = MenuBarHealth()
        health.recordReveal("s", opened: false)
        health.recordReveal("s", opened: false)
        #expect(Self.issue(health, [Self.app("s"), Self.app("h", hidden: true)]) == .hidden("h"))
        #expect(Self.issue(health, [Self.app("s")]) == .stuck("s"))
        #expect(Self.issue(health, []) == nil)
    }
}
