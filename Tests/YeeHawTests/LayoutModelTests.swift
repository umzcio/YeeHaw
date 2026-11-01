import Testing
@testable import YeeHaw
import YeeHawCore

@MainActor @Suite struct LayoutModelTests {
    static func item(_ id: String, label: String = "", bundle: Bool = true) -> MenuBarItem {
        MenuBarItem(id: id, bundleID: bundle ? id : nil, appleIdentifier: bundle ? nil : id, indexInApp: 0,
                    axIdentifier: "", label: label, keyNames: [], keyPrefixes: [], x: 0, width: 20, isPinned: false)
    }

    @Test func aMoveIsAppliedOnceTheItemSitsBetweenItsNeighbours() {
        let row = ["a", "b", "c", "d"].map { Self.item($0) }
        #expect(LayoutModel.isOrdered("c", after: "b", before: "d", in: row))
        #expect(LayoutModel.isOrdered("a", after: nil, before: "b", in: row))
        #expect(LayoutModel.isOrdered("d", after: "c", before: nil, in: row))
        #expect(!LayoutModel.isOrdered("b", after: "c", before: "d", in: row))
        #expect(!LayoutModel.isOrdered("z", after: nil, before: nil, in: row))
    }

    @Test func appleItemsAreNamedUpToTheFirstComma() {
        #expect(LayoutModel.name(of: Self.item("com.apple.menuextra.wifi", label: "Wi‑Fi, connected, 3 bars", bundle: false))
            == "Wi‑Fi")
        #expect(LayoutModel.name(of: Self.item("com.apple.menuextra.clock", label: "Clock", bundle: false)) == "Clock")
        #expect(LayoutModel.name(of: Self.item("unknown@3", label: "", bundle: false)) == "Unknown icon")
    }

    @Test func failuresReadAsInlineMessages() {
        #expect(LayoutModel.message(for: ControllerError.needsGrant(.positions)).grant == .positions)
        #expect(!LayoutModel.message(for: ControllerError.unresolvedNeighbor).offersFix)
        #expect(LayoutModel.message(for: LayoutModel.LayoutError.moveNotApplied).text.contains("didn’t apply"))
    }

    @Test func refusalsSayWhy() {
        #expect(LayoutView.refusalText(.apple, name: "Wi‑Fi") == "Wi‑Fi belongs to macOS and stays in the menu bar.")
        #expect(LayoutView.refusalText(.notTrackedYet, name: "Tailscale").hasPrefix("Tailscale isn’t hideable yet."))
    }
}
