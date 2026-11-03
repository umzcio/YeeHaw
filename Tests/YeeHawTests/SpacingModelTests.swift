import AppKit
import Testing
import YeeHawCore
@testable import YeeHaw

@MainActor
@Suite struct SpacingModelTests {
    static func app(_ name: String, windows: Bool = false, hidden: Bool = false,
                    launched: Date? = nil) -> RunningMenuBarApp {
        RunningMenuBarApp(bundleID: "com.example.\(name.lowercased())", bundlePath: "/Applications/\(name).app",
                          name: name, hasOpenWindows: windows, isHidden: hidden, launchDate: launched)
    }

    static func model(_ mac: FakeSpacingMac = FakeSpacingMac()) -> SpacingModel {
        SpacingModel(applier: SpacingApplier(system: mac.system))
    }

    /// A Mac where YeeHaw stored 8 pt at `mac.now`, over the default.
    static func macAtEight() -> FakeSpacingMac {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        var history = SpacingHistory(before: 16)
        history.record(8, at: mac.now)
        mac.history = history
        return mac
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
        let model = Self.model(Self.macAtEight())
        #expect(model.current == 8)
        #expect(model.value == 8)
        #expect(!model.canApply)
    }

    @Test func aNewValueTicksEveryWindowlessApp() {
        let model = Self.model()
        model.setApps([Self.app("DigUp"), Self.app("Outlook", windows: true)])
        // Nothing to do at the value every app already has.
        #expect(model.candidates.map(\.ticked) == [false, false])
        model.value = 8
        #expect(model.candidates.map(\.ticked) == [true, false])
    }

    @Test func userTicksAreKeptAcrossReReads() {
        let model = Self.model()
        model.value = 8
        model.setApps([Self.app("DigUp"), Self.app("Outlook", windows: true)])
        model.setTicked(true, for: "com.example.outlook")
        model.setTicked(false, for: "com.example.digup")
        model.setApps([Self.app("Outlook", windows: true), Self.app("DigUp"), Self.app("Flame")])
        #expect(model.candidates.map(\.app.name) == ["Outlook", "DigUp", "Flame"])
        #expect(model.candidates.map(\.ticked) == [true, false, true])
    }

    @Test func hiddenAppWithWindowsStartsUntickedWithTheNote() {
        // Outlook hidden with Command-H, a draft still open: Accessibility lists its window.
        let facts = WindowFacts(pid: 7, isHidden: true, isRegular: true, axWindows: 1, onScreenWindows: 0,
                                windowsAnywhere: 1)
        let outlook = Self.app("Outlook", windows: SpacingPlan.hasOpenWindows(facts), hidden: true)
        let model = Self.model()
        model.value = 8
        model.setApps([outlook])
        #expect(model.candidates.map(\.ticked) == [false])
        #expect(model.note(for: model.candidates[0]) == "Has windows open")
    }

    @Test func neverListsAppleOrYeeHaw() {
        let model = Self.model()
        model.setApps([
            RunningMenuBarApp(bundleID: "com.apple.Spotlight", bundlePath: "/System/Library/CoreServices/Spotlight.app",
                              name: "Spotlight", hasOpenWindows: false),
            RunningMenuBarApp(bundleID: "com.zapps.yeehaw", bundlePath: NSHomeDirectory() + "/Applications/YeeHaw.app",
                              name: "YeeHaw", hasOpenWindows: false),
        ])
        #expect(model.candidates.isEmpty)
    }

    // MARK: Apply

    @Test func applyNeedsANewValueOrAnAppToRestart() {
        let model = Self.model()
        #expect(!model.canApply)
        model.value = 8
        #expect(model.canApply)
    }

    @Test func theDraftNamesItsChange() {
        let model = Self.model()
        model.setApps([Self.app("DigUp"), Self.app("Flame")])
        #expect(!model.isPending)
        #expect(model.pendingPhrase == nil)
        model.value = 8
        #expect(model.isPending)
        #expect(model.pendingPhrase == "Set spacing to 8 pt")
        #expect(model.restartNames == ["DigUp", "Flame"])
        model.revert()
        #expect(model.value == 16)
        #expect(!model.isPending)
        model.setTicked(true, for: "com.example.flame")
        #expect(model.pendingPhrase == "Restart Flame")
        model.revert()
        #expect(model.candidates.map(\.ticked) == [false, false])
    }

    @Test func applyRestartsOnlyTickedAppsAndReports() async {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp"), Self.app("Outlook", windows: true)])
        model.value = 8
        await model.apply()
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"])
        #expect(model.current == 8)
        #expect(model.report?.restarted.map(\.app.name) == ["DigUp"])
        #expect(model.report?.value == 8)
        #expect(model.progress == nil)
        // DigUp has the new spacing now: nothing left to do.
        #expect(model.candidates.map(\.ticked) == [false, false])
        #expect(!model.canApply)
    }

    @Test func appsThatLaunchedBeforeTheChangeCanBeRestartedLater() async {
        // After an Apply at 8 that left Flame unticked, Flame still draws 16 pt.
        let mac = Self.macAtEight()
        let model = Self.model(mac)
        model.setApps([Self.app("Flame", launched: mac.now - 60), Self.app("DigUp", launched: mac.now + 5)])
        // Noted, but not ticked until the user asks: opening the window isn't a change.
        #expect(model.candidates.map(\.ticked) == [false, false])
        #expect(model.note(for: model.candidates[0]) == "Still at 16 pt")
        #expect(model.note(for: model.candidates[1]) == nil)
        #expect(!model.isPending)
        model.setTicked(true, for: "com.example.flame")
        #expect(model.canApply)
        #expect(!model.isWriting)
        #expect(model.pendingPhrase == "Restart Flame")
        await model.apply()
        #expect(!mac.events.contains { $0.hasPrefix("write") })
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate Flame"])
        #expect(model.report?.wrote == false)
        #expect(model.report?.headline == "Spacing is 8 pt.")
    }

    @Test func appsAlreadyAtTheChosenValueAreNotTicked() {
        // Back to the default from 8: Flame launched before 8 was stored and still draws 16, so
        // restarting it gains nothing.
        let mac = Self.macAtEight()
        let model = Self.model(mac)
        model.setApps([Self.app("Flame", launched: mac.now - 60), Self.app("DigUp", launched: mac.now + 5)])
        model.value = 16
        #expect(model.candidates.map(\.ticked) == [false, true])
        #expect(model.note(for: model.candidates[0]) == "Already at 16 pt")
        #expect(model.note(for: model.candidates[1]) == nil)
        #expect(model.restartNames == ["DigUp"])
    }

    @Test func appsLaunchedAfterAnOutsideChangeAreNotMarked() {
        // YeeHaw stored 8; then the keys were deleted outside YeeHaw (`defaults delete`), and
        // Fiddle and zStats opened afterwards at 16, before YeeHaw looked again.
        let mac = Self.macAtEight()
        mac.preferences = [:]
        mac.now += 600
        let model = Self.model(mac)
        model.setApps([Self.app("Fiddle", launched: mac.now - 60), Self.app("zStats", launched: mac.now - 30)])
        #expect(model.current == 16)
        #expect(model.candidates.map(\.spacingAtLaunch) == [nil, nil])
        #expect(model.candidates.map { model.note(for: $0) } == [nil, nil])
        #expect(model.candidates.map(\.ticked) == [false, false])
        #expect(!model.canApply)
        #expect(mac.history?.latest == 16)
        // Back at 8, both are ticked: as far as YeeHaw knows they draw 16.
        model.value = 8
        #expect(model.candidates.map { model.note(for: $0) } == [nil, nil])
        #expect(model.candidates.map(\.ticked) == [true, true])
    }

    @Test func reReadingNoticesAnOutsideChange() {
        let mac = Self.macAtEight()
        let model = Self.model(mac)
        model.setApps([Self.app("Fiddle", launched: mac.now + 60)])
        #expect(model.candidates[0].spacingAtLaunch == 8)
        // The keys are deleted outside YeeHaw while the window is open.
        mac.preferences = [:]
        mac.now += 600
        model.reloadCurrent()
        #expect(model.current == 16)
        #expect(model.value == 16)
        #expect(model.candidates[0].spacingAtLaunch == nil)
        #expect(model.note(for: model.candidates[0]) == nil)
        #expect(!model.candidates[0].ticked)
    }

    @Test func strayPaddingKeyEnablesApplyAtTheDefault() {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSelectionPadding": 4]
        let model = Self.model(mac)
        #expect(model.value == 16)
        #expect(model.isWriting)
        #expect(model.canApply)
    }

    @Test func failedSaveIsReported() async {
        let mac = FakeSpacingMac()
        mac.writeFails = true
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp")])
        model.value = 8
        await model.apply()
        #expect(model.report?.saved == false)
        #expect(model.report?.headline == "Couldn’t save the spacing.")
        #expect(model.current == 16)
        #expect(!mac.events.contains { $0.hasPrefix("terminate") })
    }

    @Test func applyingIsAnnouncedToTheWindow() async {
        let model = Self.model()
        var changes: [Bool] = []
        model.onApplyingChange = { changes.append($0) }
        model.value = 8
        await model.apply()
        #expect(changes == [true, false])
    }

    @Test func appsAreNotReReadWhileApplying() async {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.value = 8
        model.setApps([Self.app("DigUp")])
        mac.onTerminate = {
            // DigUp is quitting: a re-read now would drop it from the list.
            model.setApps([])
        }
        await model.apply()
        #expect(model.candidates.map(\.app.name) == ["DigUp"])
    }

    @Test func aSnapshotIgnoresLaterReReadsAndClosing() async throws {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp")])
        model.value = 8
        let snapshot = try #require(model.snapshotForApply())
        model.setApps([Self.app("DigUp"), Self.app("Flame")])
        model.windowClosed()
        #expect(model.isApplying)
        #expect(model.value == 8)
        #expect(model.candidates.map(\.app.name) == ["DigUp"])
        await model.apply(snapshot)
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"])
        #expect(model.current == 8)
        #expect(!model.isApplying)
    }

    @Test func aFailedSaveKeepsTheUsersTicks() async {
        let mac = FakeSpacingMac()
        mac.writeFails = true
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp"), Self.app("Flame")])
        model.value = 8
        model.setTicked(false, for: "com.example.flame")
        await model.apply()
        #expect(model.report?.saved == false)
        #expect(model.candidates.map(\.ticked) == [true, false])
    }

    @Test func nothingToApplyGivesNoSnapshot() {
        let model = Self.model()
        #expect(model.snapshotForApply() == nil)
        #expect(!model.isApplying)
    }

    // MARK: The slider, re-reads and closing

    @Test func reloadCurrentKeepsAMovedSlider() {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.value = 4
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        model.reloadCurrent()
        #expect(model.value == 4)
        #expect(model.current == 8)
    }

    @Test func reloadCurrentFollowsAnUnmovedSlider() {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        model.reloadCurrent()
        #expect(model.value == 8)
        #expect(model.current == 8)
    }

    @Test func closingTheWindowDropsAnUnappliedValueAndTheReport() async {
        let model = Self.model()
        model.value = 8
        await model.apply()
        #expect(model.report != nil)
        model.value = 4
        model.windowClosed()
        #expect(model.value == model.current)
        #expect(model.report == nil)
    }

    @Test func closingTheWindowWhileApplyingChangesNothing() async {
        let mac = FakeSpacingMac()
        let model = Self.model(mac)
        model.setApps([Self.app("DigUp")])
        model.value = 8
        var during: (value: Int, applying: Bool)?
        mac.onTerminate = {
            model.windowClosed()
            during = (model.value, model.isApplying)
        }
        await model.apply()
        #expect(during?.value == 8)
        #expect(during?.applying == true)
    }

    @Test func movingTheSliderClearsTheReport() async {
        let model = Self.model()
        model.value = 8
        await model.apply()
        #expect(model.report != nil)
        model.value = 12
        #expect(model.report == nil)
    }

    // MARK: Report text

    static let digUp = app("DigUp")

    @Test func reportHeadline() {
        #expect(SpacingReport(value: 8, result: .init(wrote: true)).headline == "Spacing set to 8 pt.")
        #expect(SpacingReport(value: 16, result: .init(wrote: true)).headline
            == "Spacing set back to the macOS default, 16 pt.")
        #expect(SpacingReport(value: 8, result: .init(wrote: false)).headline == "Spacing is 8 pt.")
        #expect(SpacingReport(value: 16, result: .init(wrote: false)).headline == "Spacing is the macOS default, 16 pt.")
        #expect(SpacingReport(value: 8, result: .init(saved: false)).headline == "Couldn’t save the spacing.")
    }

    @Test func reportDetailListsRestartedAndSkipped() {
        let names = ["DigUp", "Flame", "Outlook", "Teams", "Foo", "Bar", "Baz", "Qux"].map { Self.app($0) }
        let report = SpacingReport(value: 8, result: .init(
            wrote: true,
            restarted: [.init(app: names[0], iconReturned: true), .init(app: names[1], iconReturned: true),
                        .init(app: names[7], iconReturned: false)],
            skipped: [.init(app: names[2], reason: .refusedToQuit), .init(app: names[3], reason: .notRunning),
                      .init(app: names[4], reason: .didNotReopen), .init(app: names[5], reason: .stillQuitting),
                      .init(app: names[6], reason: .openedWindows)]))
        #expect(report.detail == [
            "Restarted DigUp and Flame.",
            "Qux restarted, but its icon hasn’t come back yet.",
            "Outlook didn’t quit, so it keeps the old spacing until it next opens.",
            "Teams wasn’t running any more; it uses the new spacing when it opens.",
            "Foo quit but didn’t reopen. Open it again from Applications.",
            "Bar hadn’t quit after 10 seconds. If it quits later, open it again to use the new spacing.",
            "Baz has a window open now, so it wasn’t restarted.",
        ])
        #expect(report.isWarning)
    }

    @Test func reportWithNothingRestarted() {
        let report = SpacingReport(value: 8, result: .init(wrote: true))
        #expect(report.detail == ["No apps were restarted. Apps use the new spacing the next time they open."])
        #expect(!report.isWarning)
    }

    @Test func reportOfAFailedSave() {
        let report = SpacingReport(value: 8, result: .init(saved: false))
        #expect(report.detail == ["Nothing was changed, and no apps were restarted."])
        #expect(report.isWarning)
    }
}
