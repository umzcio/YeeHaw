import Foundation
import Testing
@testable import YeeHaw
import YeeHawCore

/// The menu bar as it was on 2026-11-03: Tailscale, switched off, still reports the frame its icon
/// last had, which is where YeeHaw's hat is drawn now. Tailscale comes first, so it wins the tie
/// unless the reader is told it's off.
private struct TiedBar: MenuBarReading {
    static let hat = DrawnItem(x: 1841.5, width: 24, label: "YeeHaw")
    let extras = [
        AppExtra(bundleID: "io.tailscale.ipn.macsys", indexInApp: 0, x: 1841.5, width: 24, executableName: "Tailscale"),
        AppExtra(bundleID: OwnIconLocator.bundleID, indexInApp: 0, x: 1841.5, width: 24, identifier: "YeeHaw",
                 executableName: "YeeHaw"),
    ]

    func items() async -> [MenuBarItem] { ItemMatcher.match(drawn: [Self.hat], extras: extras) }
    func items(offApps: Set<BundleID>, revealed: BundleID?) async -> [MenuBarItem] {
        ItemMatcher.match(drawn: [Self.hat], extras: extras, offApps: offApps, revealed: revealed)
    }
    func runningBundleIDs() async -> Set<BundleID> { [] }
    func runningCopies(of id: BundleID) async -> [RunningCopy] { [] }
    func keyPrefixes(of id: BundleID) async -> [String] { [id] }
}

private struct Positions: PreferencesFile {
    let table: [String: Double]
    func read(_ key: String) throws -> Any? { table }
    func write(_ key: String, _ value: Any) throws {}
}

@Suite struct OwnIconLocatorTests {
    @Test @MainActor func findsItsIconWhenASwitchedOffAppReportsTheSameFrame() async {
        var lines: [String] = []
        let item = await OwnIconLocator.waitUntilReady(
            reader: TiedBar(), positions: Positions(table: ["status:YeeHaw::YeeHaw": 148.5]),
            offApps: ["io.tailscale.ipn.macsys"], timeout: 0) { lines.append($0) }
        #expect(item?.bundleID == OwnIconLocator.bundleID, "\(lines)")
        #expect(item?.x == 1841.5)
    }
}
