import Foundation
import Testing
import YeeHawCore
@testable import YeeHaw

/// A scripted Mac for `SpacingApplier`: preferences in dictionaries, apps that quit (or don't)
/// after a number of polls, and a log of every call in order.
@MainActor
final class FakeSpacingMac {
    /// Current-host and any-host global preferences.
    var preferences: [String: Any] = [:]
    var anyHostPreferences: [String: Any] = [:]
    /// Saving fails: nothing is stored.
    var writeFails = false
    var history: SpacingHistory?
    var now = Date(timeIntervalSince1970: 2_000_000)
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
    /// Apps that have a window open when Apply checks again.
    var windowsNow: Set<BundleID> = []
    var sleeps: [Duration] = []
    /// Runs as an app is asked to quit, mid-Apply.
    var onTerminate: (() -> Void)?
    /// The process IDs `open` hands out, from 1000 up.
    private(set) var nextPID: Int32 = 1000
    private var quitting: [BundleID: Int] = [:]
    private var drawing: [BundleID: Int] = [:]

    var system: SpacingSystem {
        SpacingSystem(
            readPreference: { [self] key, host in
                host == .current ? preferences[key] : anyHostPreferences[key]
            },
            writePreferences: { [self] writes in
                if writeFails { events.append("write failed"); return false }
                for write in writes {
                    let host = write.host == .current ? "" : "any "
                    events.append("write \(host)\(write.key)=\(write.value.map(String.init) ?? "nil")")
                    switch write.host {
                    case .current: preferences[write.key] = write.value
                    case .any: anyHostPreferences[write.key] = write.value
                    }
                }
                return true
            },
            loadHistory: { [self] in history },
            saveHistory: { [self] in history = $0 },
            now: { [self] in now },
            isRunning: { [self] app in
                if notRunning.contains(app.bundleID) { return false }
                guard let left = quitting[app.bundleID] else { return true }
                if left <= 0 { return false }
                quitting[app.bundleID] = left - 1
                return true
            },
            terminate: { [self] app in
                events.append("terminate \(app.name)")
                onTerminate?()
                if refuses.contains(app.bundleID) { return false }
                quitting[app.bundleID] = (quitAfterPolls[app.bundleID] ?? 0) ?? Int.max
                return true
            },
            open: { [self] app in
                events.append("open \(app.name)")
                drawing[app.bundleID] = (drawnAfterPolls[app.bundleID] ?? 0) ?? Int.max
                guard !failsToOpen.contains(app.bundleID) else { return nil }
                quitting[app.bundleID] = nil
                nextPID += 1
                return nextPID
            },
            isDrawn: { [self] app in
                guard let left = drawing[app.bundleID] else { return false }
                if left <= 0 { return true }
                drawing[app.bundleID] = left - 1
                return false
            },
            hide: { [self] app in
                if events.last != "hide \(app.name)" { events.append("hide \(app.name)") }
            },
            hasOpenWindows: { [self] app, _ in windowsNow.contains(app.bundleID) },
            sleep: { [self] duration in sleeps.append(duration) })
    }

    /// Lets an app that timed out finish quitting.
    func finishQuitting(_ id: BundleID) {
        quitting[id] = 0
    }
}

@MainActor
@Suite struct SpacingApplierTests {
    static let digUp = RunningMenuBarApp(bundleID: "com.abdurrahim.DigUp", bundlePath: "/Applications/DigUp.app",
                                         name: "DigUp", hasOpenWindows: false)
    static let windowed = RunningMenuBarApp(bundleID: "com.abdurrahim.DigUp", bundlePath: "/Applications/DigUp.app",
                                            name: "DigUp", hasOpenWindows: true)
    static let other = RunningMenuBarApp(bundleID: "com.example.other", bundlePath: "/Applications/Other.app",
                                         name: "Other", hasOpenWindows: false)
    /// Another app that happens to have the same name.
    static let otherNamesake = RunningMenuBarApp(bundleID: "com.example.other2", bundlePath: "/Applications/Other 2.app",
                                                 name: "Other", hasOpenWindows: false)

    static func applier(_ mac: FakeSpacingMac) -> SpacingApplier {
        SpacingApplier(system: mac.system)
    }

    // MARK: Reading

    @Test func storedValueIsSixteenWhenUnset() {
        #expect(Self.applier(FakeSpacingMac()).storedState().value == 16)
    }

    @Test func storedValueReadsTheSpacingKey() {
        let mac = FakeSpacingMac()
        mac.preferences["NSStatusItemSpacing"] = 8
        #expect(Self.applier(mac).storedState().value == 8)
    }

    @Test func storedValueFallsBackToTheAnyHostKey() {
        let mac = FakeSpacingMac()
        mac.anyHostPreferences["NSStatusItemSpacing"] = 6
        #expect(Self.applier(mac).storedState().value == 6)
        #expect(Self.applier(mac).storedState() == StoredSpacing(anySpacing: 6))
    }

    // MARK: Writing

    @Test func writesBothKeysBeforeRestartingAnything() async {
        let mac = FakeSpacingMac()
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp])
        #expect(mac.events.prefix(2) == ["write NSStatusItemSpacing=8", "write NSStatusItemSelectionPadding=8"])
        #expect(mac.events.dropFirst(2) == ["terminate DigUp", "open DigUp", "hide DigUp"])
        #expect(result.saved && result.wrote)
        #expect(result.restarted == [.init(app: Self.digUp, iconReturned: true)])
        #expect(result.skipped.isEmpty)
        #expect(mac.preferences["NSStatusItemSpacing"] as? Int == 8)
    }

    @Test func defaultValueDeletesBothKeysOnBothHosts() async {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        mac.anyHostPreferences = ["NSStatusItemSpacing": 4]
        let applier = Self.applier(mac)
        _ = await applier.apply(16, relaunch: [])
        #expect(mac.preferences.isEmpty)
        #expect(mac.anyHostPreferences.isEmpty)
        #expect(applier.storedState().value == 16)
    }

    @Test func strayPaddingKeyIsDeletedAtTheDefault() async {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSelectionPadding": 4]
        let applier = Self.applier(mac)
        #expect(applier.storedState().value == 16)
        #expect(!applier.storedState().isCanonical(for: 16))
        _ = await applier.apply(16, relaunch: [])
        #expect(mac.preferences.isEmpty)
        #expect(applier.storedState().isCanonical(for: 16))
    }

    @Test func sameValueWritesNothingButStillRestarts() async {
        let mac = FakeSpacingMac()
        mac.preferences = ["NSStatusItemSpacing": 8, "NSStatusItemSelectionPadding": 8]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp])
        #expect(!mac.events.contains { $0.hasPrefix("write") })
        #expect(result.saved && !result.wrote)
        #expect(result.restarted.map(\.app) == [Self.digUp])
    }

    @Test func failedSaveRestartsNothing() async {
        let mac = FakeSpacingMac()
        mac.writeFails = true
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp])
        #expect(!result.saved)
        #expect(result.restarted.isEmpty && result.skipped.isEmpty)
        #expect(!mac.events.contains { $0.hasPrefix("terminate") })
        #expect(mac.history == nil)
    }

    @Test func applyAfterAnOutsideChangeRecordsOntoAFreshHistory() async {
        // YeeHaw stored 8, then `defaults write -g NSStatusItemSpacing 4` changed it outside.
        let mac = FakeSpacingMac()
        var history = SpacingHistory(before: 16)
        history.record(8, at: mac.now)
        mac.history = history
        mac.preferences = ["NSStatusItemSpacing": 4, "NSStatusItemSelectionPadding": 4]
        mac.now += 600
        _ = await Self.applier(mac).apply(12, relaunch: [])
        #expect(mac.history?.before == 4)
        #expect(mac.history?.since == mac.now)
        #expect(mac.history?.changes.map(\.value) == [12])
    }

    @Test func recordsEachChangeOfValue() async {
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        _ = await applier.apply(8, relaunch: [])
        #expect(mac.history?.before == 16)
        #expect(mac.history?.changes.map(\.value) == [8])
        #expect(mac.history?.changes.first?.date == mac.now)
        // Restarting at the same value isn't a change.
        _ = await applier.apply(8, relaunch: [])
        #expect(mac.history?.changes.count == 1)
        #expect(applier.reconcileHistory() == mac.history)
    }

    // MARK: Restarting

    @Test func quittingYeeHawMidApplyFinishesTheCurrentAppAndLeavesTheRest() async {
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        var stopped = false
        // YeeHaw is asked to quit while DigUp is being restarted.
        mac.onTerminate = { [applier] in
            if mac.events.last == "terminate DigUp" { applier.stopAfterCurrentApp { stopped = true } }
        }
        #expect(applier.isApplying == false)
        let result = await applier.apply(8, relaunch: [Self.digUp, Self.other])
        // DigUp, already quit, is opened again; Other is never touched.
        #expect(mac.events.dropFirst(2) == ["terminate DigUp", "open DigUp", "hide DigUp"])
        #expect(result.restarted.map(\.app) == [Self.digUp])
        #expect(stopped)
        #expect(applier.isApplying == false)
    }

    @Test func stoppingWhileIdleRunsAtOnce() {
        var stopped = false
        Self.applier(FakeSpacingMac()).stopAfterCurrentApp { stopped = true }
        #expect(stopped)
    }

    @Test func restartsOneAtATimeInOrder() async {
        let mac = FakeSpacingMac()
        mac.quitAfterPolls = [Self.digUp.bundleID: 3]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp, Self.other])
        #expect(mac.events.dropFirst(2)
            == ["terminate DigUp", "open DigUp", "hide DigUp", "terminate Other", "open Other", "hide Other"])
        #expect(result.restarted.map(\.app) == [Self.digUp, Self.other])
    }

    @Test func appleAndOutsideAppsAreNeverTerminated() async {
        let mac = FakeSpacingMac()
        let spotlight = RunningMenuBarApp(bundleID: "com.apple.Spotlight",
                                          bundlePath: "/System/Library/CoreServices/Spotlight.app",
                                          name: "Spotlight", hasOpenWindows: false)
        let music = RunningMenuBarApp(bundleID: "com.apple.Music", bundlePath: "/Applications/Music.app",
                                      name: "Music", hasOpenWindows: false)
        let downloaded = RunningMenuBarApp(bundleID: "com.example.dl", bundlePath: "/Users/x/Downloads/D.app",
                                           name: "D", hasOpenWindows: false)
        let own = RunningMenuBarApp(bundleID: OwnIconLocator.bundleID,
                                    bundlePath: NSHomeDirectory() + "/Applications/YeeHaw.app",
                                    name: "YeeHaw", hasOpenWindows: false)
        let result = await Self.applier(mac).apply(8, relaunch: [spotlight, music, downloaded, own, Self.digUp])
        #expect(mac.events.filter { $0.hasPrefix("terminate") } == ["terminate DigUp"])
        #expect(result.restarted.map(\.app) == [Self.digUp])
    }

    @Test func refusingAppIsSkippedAndNotReopened() async {
        let mac = FakeSpacingMac()
        mac.refuses = [Self.digUp.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp, Self.other])
        #expect(!mac.events.contains("open DigUp"))
        #expect(result.restarted.map(\.app) == [Self.other])
        #expect(result.skipped == [.init(app: Self.digUp, reason: .refusedToQuit)])
    }

    @Test func skipsAreKeptPerAppNotPerName() async {
        let mac = FakeSpacingMac()
        mac.refuses = [Self.other.bundleID]
        mac.notRunning = [Self.otherNamesake.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.other, Self.otherNamesake])
        #expect(result.skipped == [.init(app: Self.other, reason: .refusedToQuit),
                                   .init(app: Self.otherNamesake, reason: .notRunning)])
    }

    @Test func appStillRunningAfterTenSecondsIsSkippedWithoutForce() async {
        let mac = FakeSpacingMac()
        mac.quitAfterPolls = [Self.digUp.bundleID: nil]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.windowed])
        #expect(result.skipped == [.init(app: Self.windowed, reason: .stillQuitting)])
        #expect(!mac.events.contains("open DigUp"))
        // Ten seconds of polling, and only the one polite request.
        #expect(mac.sleeps.reduce(.zero, +) == .seconds(10))
        #expect(mac.events.filter { $0.hasPrefix("terminate") }.count == 1)
    }

    @Test func appThatQuitsLateIsReopenedBeforeApplyEnds() async {
        // DigUp takes longer than ten seconds; by the time Other is done it has quit, so it's
        // opened again rather than left closed.
        let mac = FakeSpacingMac()
        mac.quitAfterPolls = [Self.digUp.bundleID: nil]
        let applier = Self.applier(mac)
        applier.onProgress = { app, _, _ in
            if app == Self.other { mac.finishQuitting(Self.digUp.bundleID) }
        }
        let result = await applier.apply(8, relaunch: [Self.windowed, Self.other])
        #expect(result.skipped.isEmpty)
        #expect(result.restarted.map(\.app) == [Self.other, Self.windowed])
        #expect(mac.events.filter { $0.hasPrefix("open") } == ["open Other", "open DigUp"])
    }

    @Test func appNoLongerRunningIsSkipped() async {
        let mac = FakeSpacingMac()
        mac.notRunning = [Self.digUp.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp])
        #expect(result.skipped == [.init(app: Self.digUp, reason: .notRunning)])
        #expect(!mac.events.contains("terminate DigUp"))
    }

    @Test func appThatFailsToReopenIsReported() async {
        let mac = FakeSpacingMac()
        mac.failsToOpen = [Self.digUp.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp])
        #expect(result.restarted.isEmpty)
        #expect(result.skipped == [.init(app: Self.digUp, reason: .didNotReopen)])
    }

    @Test func windowlessAppThatOpenedAWindowIsNotRestarted() async {
        // The list said no windows, but one is open now: restarting would close it.
        let mac = FakeSpacingMac()
        mac.windowsNow = [Self.digUp.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.digUp, Self.other])
        #expect(!mac.events.contains("terminate DigUp"))
        #expect(result.skipped == [.init(app: Self.digUp, reason: .openedWindows)])
        #expect(result.restarted.map(\.app) == [Self.other])
    }

    @Test func appTheUserTickedDespiteItsWindowsIsRestarted() async {
        let mac = FakeSpacingMac()
        mac.windowsNow = [Self.windowed.bundleID]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.windowed])
        #expect(result.restarted.map(\.app) == [Self.windowed])
    }

    // MARK: After the restart

    @Test func waitsUntilTheItemIsDrawnAgain() async {
        let mac = FakeSpacingMac()
        mac.drawnAfterPolls = [Self.digUp.bundleID: 5]
        _ = await Self.applier(mac).apply(8, relaunch: [Self.windowed])
        #expect(mac.sleeps.count == 5)
    }

    @Test func itemNeverDrawnStopsWaitingAfterTenSecondsAndIsReported() async {
        let mac = FakeSpacingMac()
        mac.drawnAfterPolls = [Self.digUp.bundleID: nil]
        let result = await Self.applier(mac).apply(8, relaunch: [Self.windowed, Self.other])
        // Ten seconds for DigUp's item, then Other settles hidden.
        #expect(mac.sleeps.reduce(.zero, +) == .seconds(10) + SpacingApplier.pollInterval * SpacingApplier.settlePolls)
        // It did restart, without its icon; the next app still gets its turn.
        #expect(result.restarted == [.init(app: Self.windowed, iconReturned: false),
                                     .init(app: Self.other, iconReturned: true)])
    }

    @Test func windowlessAppIsKeptHiddenWhileItSettlesAndIsExempt() async {
        // DigUp opens its main window when it launches, even launched hidden: an app that had
        // no windows open is hidden again for a second after its item is back, and that hidden
        // window doesn't count as open while it stays hidden.
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        _ = await applier.apply(8, relaunch: [Self.digUp])
        #expect(mac.events.last == "hide DigUp")
        #expect(mac.sleeps.reduce(.zero, +) == SpacingApplier.pollInterval * SpacingApplier.settlePolls)
        #expect(applier.hiddenAfterRestart == [mac.nextPID])
        applier.forgetHidden(mac.nextPID)
        #expect(applier.hiddenAfterRestart.isEmpty)
    }

    @Test func appWithWindowsIsNotHidden() async {
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        _ = await applier.apply(8, relaunch: [Self.windowed])
        #expect(!mac.events.contains { $0.hasPrefix("hide") })
        #expect(mac.sleeps.isEmpty)
        #expect(applier.hiddenAfterRestart.isEmpty)
    }

    @Test func hiddenAppWithWindowsComesBackHidden() async {
        var hidden = Self.windowed
        hidden.isHidden = true
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        _ = await applier.apply(8, relaunch: [hidden])
        #expect(mac.events.last == "hide DigUp")
        // Its windows are real: it isn't exempt.
        #expect(applier.hiddenAfterRestart.isEmpty)
        #expect(SpacingApplier.reopensHidden(hidden))
        #expect(SpacingApplier.reopensHidden(Self.digUp))
        #expect(!SpacingApplier.reopensHidden(Self.windowed))
    }

    @Test func reportsProgressForEachApp() async {
        let mac = FakeSpacingMac()
        let applier = Self.applier(mac)
        var steps: [String] = []
        applier.onProgress = { app, index, count in steps.append("\(app.name) \(index + 1)/\(count)") }
        _ = await applier.apply(8, relaunch: [Self.digUp, Self.other])
        #expect(steps == ["DigUp 1/2", "Other 2/2"])
    }
}
