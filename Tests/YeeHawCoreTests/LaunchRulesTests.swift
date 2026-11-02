import Foundation
import Testing
@testable import YeeHawCore

@Suite struct LaunchRulesTests {
    static func os(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    // MARK: Guards

    @Test func proceedsOnTheMinimumAndLater() {
        #expect(LaunchRules.check(os: Self.os(27, 2), running: []) == .proceed)
        #expect(LaunchRules.check(os: Self.os(27, 2, 1), running: []) == .proceed)
        #expect(LaunchRules.check(os: Self.os(27, 10), running: []) == .proceed)
        #expect(LaunchRules.check(os: Self.os(28, 0), running: ["com.apple.finder"]) == .proceed)
    }

    @Test func refusesOlderSystems() {
        for old in [Self.os(27, 1, 9), Self.os(27, 0, 1), Self.os(26, 4)] {
            guard case .refuse(let reason) = LaunchRules.check(os: old, running: []) else {
                Issue.record("\(old) should be refused")
                continue
            }
            #expect(reason == .unsupportedSystem(found: "\(old.majorVersion).\(old.minorVersion).\(old.patchVersion)"))
        }
    }

    @Test func refusesWhileThawRuns() {
        #expect(LaunchRules.check(os: Self.os(27, 2), running: ["com.stonerl.Thaw", "com.apple.finder"])
                == .refuse(.thawRunning))
    }

    @Test func anOldSystemIsReportedBeforeThaw() {
        #expect(LaunchRules.check(os: Self.os(27, 0), running: ["com.stonerl.Thaw"])
                == .refuse(.unsupportedSystem(found: "27.0.0")))
    }

    @Test func refusalsExplainThemselves() {
        let old = LaunchRules.Refusal.unsupportedSystem(found: "27.0.1")
        #expect(old.title == "YeeHaw needs macOS 27.2 or later")
        #expect(old.message.contains("27.0.1"))
        let thaw = LaunchRules.Refusal.thawRunning
        #expect(thaw.title == "Quit Thaw first")
        #expect(thaw.message.contains("both apps change the same settings"))
    }

    // MARK: Order

    @Test func firstRunOnboardsBeforeLaunching() {
        #expect(LaunchRules.steps(onboardingComplete: false) == [.onboarding, .launchController, .showStatusItem])
    }

    @Test func laterRunsSkipOnboarding() {
        #expect(LaunchRules.steps(onboardingComplete: true) == [.launchController, .showStatusItem])
        // launch() restores a reveal left by a crash itself.
        #expect(LaunchRules.steps(onboardingComplete: true, pendingReveal: true) == [.launchController, .showStatusItem])
    }

    @Test func aRevealLeftByACrashIsUndoneBeforeOnboarding() {
        #expect(LaunchRules.steps(onboardingComplete: false, pendingReveal: true)
                == [.endPendingReveal, .onboarding, .launchController, .showStatusItem])
    }

    // MARK: Termination

    @Test func quitReasonsAreReadFromTheAppleEventCode() {
        func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        #expect(LaunchRules.QuitReason(code: nil) == .ordinary)
        #expect(LaunchRules.QuitReason(code: code("logo")) == .logout)
        #expect(LaunchRules.QuitReason(code: code("rlgo")) == .logout)
        #expect(LaunchRules.QuitReason(code: code("rrst")) == .restart)
        #expect(LaunchRules.QuitReason(code: code("rest")) == .restart)
        #expect(LaunchRules.QuitReason(code: code("rsdn")) == .shutdown)
        #expect(LaunchRules.QuitReason(code: code("shut")) == .shutdown)
        #expect(LaunchRules.QuitReason(code: code("abcd")) == .ordinary)
    }

    @Test func anOrdinaryQuitSwitchesHiddenAppsBackOn() {
        #expect(LaunchRules.switchesBackOnAtTermination(.ordinary))
    }

    @Test func logoutRestartAndShutdownKeepAppsHidden() {
        for reason in [LaunchRules.QuitReason.logout, .restart, .shutdown] {
            #expect(!LaunchRules.switchesBackOnAtTermination(reason))
        }
    }
}

@Suite struct OwnIconPlacementTests {
    static let yeehaw = "com.zapps.yeehaw"

    static func item(_ id: String, x: Double, apple: Bool = false) -> MenuBarItem {
        MenuBarItem(id: id, bundleID: apple ? nil : id, appleIdentifier: apple ? id : nil, indexInApp: 0,
                    axIdentifier: "", label: id, keyNames: [], keyPrefixes: apple ? [] : [id],
                    x: x, width: 24, isPinned: apple)
    }

    static let controlCenter = item("com.apple.menuextra.controlcenter", x: 1875, apple: true)
    static let clock = item("com.apple.menuextra.clock", x: 1917, apple: true)
    static let battery = item("com.apple.menuextra.battery", x: 1833, apple: true)

    @Test func nextToControlCenterWhenItsLeftNeighbour() {
        let items = [Self.battery, Self.item(Self.yeehaw, x: 1850), Self.controlCenter, Self.clock]
        #expect(OwnIconPlacement.isNextToControlCenter(items, ownID: Self.yeehaw))
    }

    @Test func notNextToControlCenterWithAnItemBetween() {
        let items = [Self.item(Self.yeehaw, x: 1529), Self.battery, Self.controlCenter, Self.clock]
        #expect(!OwnIconPlacement.isNextToControlCenter(items, ownID: Self.yeehaw))
    }

    @Test func orderIsByPositionNotListOrder() {
        let items = [Self.clock, Self.controlCenter, Self.item(Self.yeehaw, x: 1850), Self.battery]
        #expect(OwnIconPlacement.isNextToControlCenter(items, ownID: Self.yeehaw))
    }

    @Test func notPlacedWhenNotDrawnOrRightOfIt() {
        #expect(!OwnIconPlacement.isNextToControlCenter([Self.battery, Self.controlCenter], ownID: Self.yeehaw))
        let right = [Self.controlCenter, Self.item(Self.yeehaw, x: 1900), Self.clock]
        #expect(!OwnIconPlacement.isNextToControlCenter(right, ownID: Self.yeehaw))
    }
}
