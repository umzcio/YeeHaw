import Testing
import YeeHawCore
@testable import YeeHaw

/// Two running copies of one app: YeeHaw acts on the one that draws the icon.
@Suite struct CopyTrackingTests {
    static func item(pid: Int32?) -> MenuBarItem {
        MenuBarItem(id: "com.example.swarm#0", bundleID: "com.example.swarm", appleIdentifier: nil, indexInApp: 0,
                    label: "", keyNames: [], keyPrefixes: [], x: 100, width: 20, isPinned: false, pid: pid)
    }

    @Test func theRevealPressesTheCopyThatDrawsTheIcon() {
        #expect(RevealCoordinator.pressTarget(for: Self.item(pid: 22), running: [11, 22]) == 22)
    }

    @Test func aCopyThatQuitFallsBackToTheFirstRunning() {
        #expect(RevealCoordinator.pressTarget(for: Self.item(pid: 33), running: [11, 22]) == 11)
    }

    @Test func noPidFallsBackToTheFirstRunning() {
        #expect(RevealCoordinator.pressTarget(for: Self.item(pid: nil), running: [11]) == 11)
        #expect(RevealCoordinator.pressTarget(for: Self.item(pid: nil), running: []) == nil)
    }
}
