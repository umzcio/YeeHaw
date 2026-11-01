import AppKit
import Testing
import YeeHawCore
@testable import YeeHaw

@MainActor
@Suite struct SpacingModelTests {
    static func app(_ name: String, windows: Bool = false) -> RunningMenuBarApp {
        RunningMenuBarApp(bundleID: "com.example.\(name.lowercased())", bundlePath: "/Applications/\(name).app",
                          name: name, hasVisibleWindows: windows)
    }

    static func model(_ mac: FakeSpacingMac = FakeSpacingMac()) -> SpacingModel {
        SpacingModel(applier: SpacingApplier(system: mac.system))
    }

    // MARK: Preview geometry

    @Test func previewItemIsTheGlyphPlusTheSpacing() {
        // On 27.2, DigUp's item narrowed by exactly the spacing removed (16 → 4: 12 pt).
        #expect(SpacingPreview.itemWidth(glyph: 18, spacing: 16) == 34)
        #expect(SpacingPreview.itemWidth(glyph: 18, spacing: 4) == 22)
        #expect(SpacingPreview.itemWidth(glyph: 18, spacing: 0) == 18)
    }

    // MARK: Candidates and ticks

    @Test func startsAtTheCurrentValue() {
        let mac = FakeSpacingMac()
        mac.preferences["NSStatusItemSpacing"] = 8
        let model = Self.model(mac)
        #expect(model.current == 8)
        #expect(model.value == 8)
        #expect(!model.canApply)
    }

    @Test func ticksFollowTheDefaultsUntilTheUserChangesThem() {
        let model = Self.model()
        model.setApps([Self.app("DigUp"), Self.app("Outlook", windows: true)])
        #expect(model.candidates.map(\.ticked) == [true, false])
        model.setTicked(true, for: "com.example.outlook")
        model.setTicked(false, for: "com.example.digup")
        // A re-read keeps the user's choices.
        model.setApps([Self.app("Outlook", windows: true), Self.app("DigUp"), Self.app("Flame")])
        #expect(model.candidates.map(\.app.name) == ["Outlook", "DigUp", "Flame"])
        #expect(model.candidates.map(\.ticked) == [true, false, true])
    }

    @Test func neverListsAppleOrYeeHaw() {
        let model = Self.model()
        model.setApps([
            RunningMenuBarApp(bundleID: "com.apple.Spotlight", bundlePath: "/System/Library/CoreServices/Spotlight.app",
                              name: "Spotlight", hasVisibleWindows: false),
            RunningMenuBarApp(bundleID: "com.zapps.yeehaw", bundlePath: NSHomeDirectory() + "/Applications/YeeHaw.app",
                              name: "YeeHaw", hasVisibleWindows: false),
        ])
        #expect(model.candidates.isEmpty)
    }

    @Test func applyNeedsANewValue() {
        let model = Self.model()
        #expect(!model.canApply)
        model.value = 8
        #expect(model.canApply)
    }

    @Test func applyTitleNamesTheRestarts() {
        #expect(SpacingModel.applyTitle(restarting: 0) == "Apply")
        #expect(SpacingModel.applyTitle(restarting: 1) == "Apply and Restart 1 App")
        #expect(SpacingModel.applyTitle(restarting: 3) == "Apply and Restart 3 Apps")
    }

    @Test func applyRestartsOnlyTickedAppsAndReports() async {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp"), Self.app("Outlook", windows: true)])
        model.value = 8
        await model.apply()
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"])
        #expect(model.current == 8)
        #expect(!model.canApply)
        #expect(model.report?.restarted == ["DigUp"])
        #expect(model.report?.value == 8)
        #expect(model.progress == nil)
    }

    @Test func appsAreNotReReadWhileApplying() async {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp")])
        model.value = 8
        model.applier.onProgress = { _, _, _ in
            // DigUp has quit: a re-read now would drop it from the list.
            model.setApps([])
        }
        await model.apply()
        #expect(model.candidates.map(\.app.name) == ["DigUp"])
    }

    // MARK: Report text

    @Test func reportHeadline() {
        #expect(SpacingReport(value: 8, restarted: ["DigUp"], skipped: []).headline == "Spacing set to 8 pt.")
        #expect(SpacingReport(value: 16, restarted: [], skipped: []).headline
            == "Spacing set back to the macOS default, 16 pt.")
    }

    @Test func reportDetailListsRestartedAndSkipped() {
        let report = SpacingReport(value: 8, restarted: ["DigUp", "Flame"],
                                   skipped: [.init(name: "Outlook", reason: .declinedToQuit),
                                             .init(name: "Teams", reason: .notRunning),
                                             .init(name: "Foo", reason: .didNotReopen)])
        #expect(report.detail == [
            "Restarted DigUp and Flame.",
            "Outlook didn’t quit, so it keeps the old spacing until it next opens.",
            "Teams wasn’t running any more; it uses the new spacing when it opens.",
            "Foo quit but didn’t reopen. Open it again from Applications.",
        ])
    }

    @Test func reportWithNothingRestarted() {
        #expect(SpacingReport(value: 8, restarted: [], skipped: []).detail
            == ["No apps were restarted. Apps use the new spacing the next time they open."])
    }
}
