import Foundation
import Testing
import YeeHawCore
@testable import YeeHaw

/// A scripted Mac for `SpacingApplier`: preferences in a dictionary, apps that quit (or don't)
/// after a number of polls, and a log of every call in order.
@MainActor
final class FakeSpacingMac {
    var preferences: [String: Any] = [:]
    var events: [String] = []
    /// Apps that refuse `terminate()` outright.
    var refuses: Set<BundleID> = []
    /// Polls an app keeps running for after agreeing to quit (nil: never quits).
    var quitAfterPolls: [BundleID: Int?] = [:]
    /// Apps not running when Apply reaches them.
    var notRunning: Set<BundleID> = []
    /// Apps that fail to reopen.
    var failsToOpen: Set<BundleID> = []
    /// Polls before a reopened app's item is drawn (nil: never).
    var drawnAfterPolls: [BundleID: Int?] = [:]
    var sleeps: [Duration] = []
    private var quitting: [BundleID: Int] = [:]
    private var drawing: [BundleID: Int] = [:]

    var system: SpacingSystem {
        SpacingSystem(
            readPreference: { [unowned self] key in preferences[key] },
            writePreferences: { [unowned self] values in
                for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                    if let value { preferences[key] = value } else { preferences.removeValue(forKey: key) }
                    events.append("write \(key)=\(value.map(String.init) ?? "nil")")
                }
            },
            isRunning: { [unowned self] app in
                if notRunning.contains(app.bundleID) { return false }
                guard let left = quitting[app.bundleID] else { return true }
                if left <= 0 { return false }
                quitting[app.bundleID] = left - 1
                return true
            },
            terminate: { [unowned self] app in
                events.append("terminate \(app.name)")
                if refuses.contains(app.bundleID) { return false }
                quitting[app.bundleID] = (quitAfterPolls[app.bundleID] ?? 0) ?? Int.max
                return true
            },
            open: { [unowned self] app in
                events.append("open \(app.name)")
                drawing[app.bundleID] = (drawnAfterPolls[app.bundleID] ?? 0) ?? Int.max
                return !failsToOpen.contains(app.bundleID)
            },
            isDrawn: { [unowned self] app in
                guard let left = drawing[app.bundleID] else { return false }
                if left <= 0 { return true }
                drawing[app.bundleID] = left - 1
                return false
            },
            hide: { [unowned self] app in
                if events.last != "hide \(app.name)" { events.append("hide \(app.name)") }
            },
            sleep: { [unowned self] duration in sleeps.append(duration) })
    }
}

@MainActor
@Suite struct SpacingApplierTests {
    static let digUp = RunningMenuBarApp(bundleID: "com.abdurrahim.DigUp", bundlePath: "/Applications/DigUp.app",
                                         name: "DigUp", hasVisibleWindows: false)
    static let windowed = RunningMenuBarApp(bundleID: "com.abdurrahim.DigUp", bundlePath: "/Applications/DigUp.app",
                                            name: "DigUp", hasVisibleWindows: true)
    static let other = RunningMenuBarApp(bundleID: "com.example.other", bundlePath: "/Applications/Other.app",
                                         name: "Other", hasVisibleWindows: false)

    @Test func currentValueIsSixteenWhenUnset() {
        let mac = FakeSpacingMac()
        #expect(SpacingApplier(system: mac.system).currentValue() == 16)
    }

    @Test func currentValueReadsTheSpacingKey() {
        let mac = FakeSpacingMac()
        mac.preferences["NSStatusItemSpacing"] = 8
        #expect(SpacingApplier(system: mac.system).currentValue() == 8)
    }

    @Test func writesBothKeysBeforeRestartingAnything() async {
        let mac = FakeSpacingMac()
        let result = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.digUp])
        #expect(mac.events.prefix(2) == ["write NSStatusItemSelectionPadding=8", "write NSStatusItemSpacing=8"])
        #expect(mac.events.dropFirst(2) == ["terminate DigUp", "open DigUp", "hide DigUp"])
        #expect(result.restarted == ["DigUp"])
        #expect(result.skipped.isEmpty)
        #expect(mac.preferences["NSStatusItemSpacing"] as? Int == 8)
    }

    @Test func defaultValueDeletesBothKeys() async {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        let applier = SpacingApplier(system: mac.system)
        _ = await applier.apply(16, relaunch: [])
        #expect(mac.preferences.isEmpty)
        #expect(applier.currentValue() == 16)
    }

    @Test func restartsOneAtATimeInOrder() async {
        let mac = FakeSpacingMac()
        mac.quitAfterPolls = [Self.digUp.bundleID: 3]
        let result = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.digUp, Self.other])
        #expect(mac.events.dropFirst(2)
            == ["terminate DigUp", "open DigUp", "hide DigUp", "terminate Other", "open Other", "hide Other"])
        #expect(result.restarted == ["DigUp", "Other"])
    }

    @Test func refusingAppIsSkippedAndNotReopened() async {
        let mac = FakeSpacingMac()
        mac.refuses = [Self.digUp.bundleID]
        let applier = SpacingApplier(system: mac.system)
        let result = await applier.apply(8, relaunch: [Self.digUp, Self.other])
        #expect(!mac.events.contains("open DigUp"))
        #expect(result.restarted == ["Other"])
        #expect(result.skipped == ["DigUp"])
        #expect(applier.skipReasons["DigUp"] == .declinedToQuit)
    }

    @Test func appStillRunningAfterTenSecondsIsSkippedWithoutForce() async {
        let mac = FakeSpacingMac()
        mac.quitAfterPolls = [Self.digUp.bundleID: nil]
        let applier = SpacingApplier(system: mac.system)
        let result = await applier.apply(8, relaunch: [Self.windowed])
        #expect(result.skipped == ["DigUp"])
        #expect(applier.skipReasons["DigUp"] == .declinedToQuit)
        #expect(!mac.events.contains("open DigUp"))
        // Ten seconds of polling, and only the one polite request.
        #expect(mac.sleeps.reduce(.zero, +) == .seconds(10))
        #expect(mac.events.filter { $0.hasPrefix("terminate") }.count == 1)
    }

    @Test func appNoLongerRunningIsSkipped() async {
        let mac = FakeSpacingMac()
        mac.notRunning = [Self.digUp.bundleID]
        let applier = SpacingApplier(system: mac.system)
        let result = await applier.apply(8, relaunch: [Self.digUp])
        #expect(result.skipped == ["DigUp"])
        #expect(applier.skipReasons["DigUp"] == .notRunning)
        #expect(!mac.events.contains("terminate DigUp"))
    }

    @Test func appThatFailsToReopenIsReported() async {
        let mac = FakeSpacingMac()
        mac.failsToOpen = [Self.digUp.bundleID]
        let applier = SpacingApplier(system: mac.system)
        let result = await applier.apply(8, relaunch: [Self.digUp])
        #expect(result.restarted.isEmpty)
        #expect(result.skipped == ["DigUp"])
        #expect(applier.skipReasons["DigUp"] == .didNotReopen)
    }

    @Test func waitsUntilTheItemIsDrawnAgain() async {
        let mac = FakeSpacingMac()
        mac.drawnAfterPolls = [Self.digUp.bundleID: 5]
        _ = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.windowed])
        #expect(mac.sleeps.count == 5)
    }

    @Test func windowlessAppIsKeptHiddenWhileItSettles() async {
        // DigUp opens its main window when it launches, even launched hidden: an app that had
        // no windows open is hidden again for a second after its item is back.
        let mac = FakeSpacingMac()
        _ = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.digUp])
        #expect(mac.events.last == "hide DigUp")
        #expect(mac.sleeps.reduce(.zero, +) == SpacingApplier.pollInterval * SpacingApplier.settlePolls)
    }

    @Test func appWithWindowsIsNotHidden() async {
        let mac = FakeSpacingMac()
        _ = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.windowed])
        #expect(!mac.events.contains { $0.hasPrefix("hide") })
        #expect(mac.sleeps.isEmpty)
    }

    @Test func itemNeverDrawnStopsWaitingAfterTenSeconds() async {
        let mac = FakeSpacingMac()
        mac.drawnAfterPolls = [Self.digUp.bundleID: nil]
        let result = await SpacingApplier(system: mac.system).apply(8, relaunch: [Self.windowed, Self.other])
        // Ten seconds for DigUp's item, then Other settles hidden.
        #expect(mac.sleeps.reduce(.zero, +) == .seconds(10) + SpacingApplier.pollInterval * SpacingApplier.settlePolls)
        // It did restart; the next app still gets its turn.
        #expect(result.restarted == ["DigUp", "Other"])
    }

    @Test func reportsProgressForEachApp() async {
        let mac = FakeSpacingMac()
        let applier = SpacingApplier(system: mac.system)
        var steps: [String] = []
        applier.onProgress = { app, index, count in steps.append("\(app.name) \(index + 1)/\(count)") }
        _ = await applier.apply(8, relaunch: [Self.digUp, Self.other])
        #expect(steps == ["DigUp 1/2", "Other 2/2"])
    }
}
