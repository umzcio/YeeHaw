import AppKit
import os
import YeeHawCore

/// What `SpacingApplier` needs from the Mac, so its sequencing can be tested with a fake.
@MainActor
struct SpacingSystem {
    /// A global preference on one host.
    var readPreference: (String, PreferenceHost) -> Any?
    /// Stores global preferences (a nil value deletes the key) and saves them; false if they
    /// couldn't be saved.
    var writePreferences: ([PreferenceWrite]) -> Bool
    /// The spacings YeeHaw has stored, and when.
    var loadHistory: () -> SpacingHistory?
    var saveHistory: (SpacingHistory) -> Void
    var now: () -> Date
    var isRunning: (RunningMenuBarApp) -> Bool
    /// Asks the app to quit, the way Quit in its menu would. False if it refused outright.
    var terminate: (RunningMenuBarApp) -> Bool
    /// Opens the app again with `options`: its new process ID, or nil if it couldn't be opened.
    var open: (RunningMenuBarApp, RelaunchOptions) async -> Int32?
    /// Whether the reopened app's menu bar item is back.
    var isDrawn: (RunningMenuBarApp) async -> Bool
    /// Whether the app has windows open right now.
    var hasOpenWindows: (RunningMenuBarApp) async -> Bool
    var sleep: (Duration) async -> Void
}

/// How Spacing Apply opens an app it restarted. Never hidden: a hidden app still gets its menu
/// bar item's clicks but can't show the panel or popover they open (SwiftUI `MenuBarExtra` apps
/// and AppKit popover panels both stop working), and nothing would ever show it again. Never
/// brought to the front either. An app that opens a window at launch (DigUp does) may show it;
/// that window is the app's own, and the user closes it like any other.
struct RelaunchOptions: Equatable, Sendable {
    var activates: Bool
    var hides: Bool
    var addsToRecentItems: Bool

    static let standard = RelaunchOptions(activates: false, hides: false, addsToRecentItems: false)
}

/// Applies a spacing (spec Technique 4 and "Spacing Apply"): writes both preferences, then
/// restarts the chosen apps one at a time so they pick it up. Never force-quits: an app still
/// running ten seconds after being asked to quit is skipped and left alone. It never hides an app
/// it reopens (`RelaunchOptions`).
@MainActor
final class SpacingApplier {
    enum SkipReason: Error, Equatable {
        /// It refused to quit.
        case refusedToQuit
        /// It agreed to quit but was still running ten seconds later (and by the end of Apply).
        case stillQuitting
        /// It had quit by the time its turn came.
        case notRunning
        /// It quit but couldn't be opened again.
        case didNotReopen
        /// It had no windows when the list was read, but has one open now.
        case openedWindows
    }

    struct Restart: Equatable {
        let app: RunningMenuBarApp
        /// Whether its menu bar item was back within ten seconds.
        let iconReturned: Bool
    }

    struct Skip: Equatable {
        let app: RunningMenuBarApp
        let reason: SkipReason
    }

    struct Result: Equatable {
        /// False if the preferences couldn't be saved; nothing was restarted then.
        var saved = true
        /// Whether anything needed writing (false when only restarting at the stored value).
        var wrote = false
        var restarted: [Restart] = []
        var skipped: [Skip] = []
    }

    static let log = Logger(subsystem: Log.subsystem, category: "spacing")
    /// Live appliers (not test ones), so quitting YeeHaw can wait for one that's mid-Apply.
    private static var live: [WeakApplier] = []
    static let pollInterval: Duration = .milliseconds(100)
    /// How long an app gets to quit, and a reopened app to draw its item: 10 s each.
    static let quitPolls = 100
    static let drawPolls = 100

    private let system: SpacingSystem
    private let own: BundleID
    /// Told as each app's restart begins: the app, its index and how many there are.
    var onProgress: ((RunningMenuBarApp, Int, Int) -> Void)?
    /// Whether `apply` is running.
    private(set) var isApplying = false
    /// Set by `stopAfterCurrentApp`: no further app is asked to quit.
    private var stopRequested = false
    private var whenStopped: [() -> Void] = []

    init(system: SpacingSystem, own: BundleID = OwnIconLocator.bundleID) {
        self.system = system
        self.own = own
    }

    /// Both preferences as stored on both hosts.
    func storedState() -> StoredSpacing {
        StoredSpacing(spacing: SpacingPlan.storedValue(system.readPreference(SpacingPlan.spacingKey, .current)),
                      padding: SpacingPlan.storedValue(system.readPreference(SpacingPlan.selectionPaddingKey, .current)),
                      anySpacing: SpacingPlan.storedValue(system.readPreference(SpacingPlan.spacingKey, .any)),
                      anyPadding: SpacingPlan.storedValue(system.readPreference(SpacingPlan.selectionPaddingKey, .any)))
    }

    /// The spacings YeeHaw has stored, and when. If the stored value no longer matches (it was
    /// changed outside YeeHaw), the history starts again from now and is saved that way.
    func reconcileHistory() -> SpacingHistory? {
        let history = system.loadHistory()
        let stored = storedState().value
        guard let fresh = SpacingHistory.reconciled(history, stored: stored, at: system.now()),
              fresh != history else { return history }
        Self.log.notice("Spacing: changed outside YeeHaw to \(stored, privacy: .public); history starts again")
        system.saveHistory(fresh)
        return fresh
    }

    /// Stores `value` (the default deletes the keys, back to stock; keys already right are left
    /// alone) and restarts `relaunch` in order. Apple's apps, apps outside an Applications folder
    /// and YeeHaw are never restarted, whoever asks. If saving fails, nothing is restarted.
    func apply(_ value: Int, relaunch: [RunningMenuBarApp]) async -> Result {
        isApplying = true
        defer { finishApplying() }
        let value = SpacingPlan.clamped(value)
        let allowed = SpacingPlan.candidates(relaunch, own: own).map(\.app)
        for app in relaunch where !allowed.contains(app) {
            Self.log.error("Spacing: refused to restart \(app.bundleID, privacy: .public) at \(app.bundlePath, privacy: .public)")
        }
        var result = Result()
        let history = reconcileHistory()
        let stored = storedState()
        let writes = stored.writes(for: value)
        if !writes.isEmpty {
            guard system.writePreferences(writes), storedState().isCanonical(for: value) else {
                Self.log.error("Spacing: couldn't save \(value, privacy: .public); restarting nothing")
                result.saved = false
                return result
            }
            result.wrote = true
            if value != stored.value {
                var history = history ?? SpacingHistory(before: stored.value)
                history.record(value, at: system.now())
                system.saveHistory(history)
            }
        }
        Self.log.notice("Spacing set to \(value, privacy: .public) (wrote: \(result.wrote, privacy: .public)); restarting \(allowed.count, privacy: .public) app(s)")

        var stillQuitting: [RunningMenuBarApp] = []
        for (index, app) in allowed.enumerated() {
            if stopRequested {
                Self.log.notice("Spacing: YeeHaw is quitting; \(allowed.count - index, privacy: .public) app(s) left as they are")
                break
            }
            onProgress?(app, index, allowed.count)
            switch await restart(app) {
            case .success(let restart):
                result.restarted.append(restart)
            case .failure(.stillQuitting):
                stillQuitting.append(app)
            case .failure(let reason):
                result.skipped.append(Skip(app: app, reason: reason))
                Self.log.notice("Spacing: skipped \(app.bundleID, privacy: .public) (\(String(describing: reason), privacy: .public))")
            }
        }
        // An app that took longer than ten seconds may have quit since: open it again rather
        // than leave it closed.
        for app in stillQuitting {
            if !system.isRunning(app), let restart = await reopen(app) {
                result.restarted.append(restart)
            } else {
                let reason: SkipReason = system.isRunning(app) ? .stillQuitting : .didNotReopen
                result.skipped.append(Skip(app: app, reason: reason))
                Self.log.notice("Spacing: skipped \(app.bundleID, privacy: .public) (\(String(describing: reason), privacy: .public))")
            }
        }
        return result
    }

    /// Asks a running Apply to stop once the app it's restarting is open again (later apps are
    /// left running, as they were), then calls `done`; at once when nothing is applying. Quitting
    /// YeeHaw waits on this, so an app it just quit isn't left closed.
    func stopAfterCurrentApp(then done: @escaping () -> Void) {
        guard isApplying else { return done() }
        stopRequested = true
        whenStopped.append(done)
    }

    /// Whether any live applier is mid-Apply.
    static var anyApplying: Bool { live.contains { $0.applier?.isApplying == true } }

    /// `stopAfterCurrentApp` for every live applier that's applying; `done` once all have stopped.
    static func stopAllAfterCurrentApp(then done: @escaping () -> Void) {
        let applying = live.compactMap(\.applier).filter(\.isApplying)
        guard !applying.isEmpty else { return done() }
        var left = applying.count
        for applier in applying {
            applier.stopAfterCurrentApp {
                left -= 1
                if left == 0 { done() }
            }
        }
    }

    private func finishApplying() {
        isApplying = false
        stopRequested = false
        let waiting = whenStopped
        whenStopped = []
        waiting.forEach { $0() }
    }

    /// Quits and reopens one app.
    private func restart(_ app: RunningMenuBarApp) async -> Swift.Result<Restart, SkipReason> {
        guard system.isRunning(app) else { return .failure(.notRunning) }
        // The list may be minutes old: an app that opened a window since isn't interrupted.
        if !app.hasOpenWindows, await system.hasOpenWindows(app) {
            return .failure(.openedWindows)
        }
        guard system.terminate(app) else { return .failure(.refusedToQuit) }
        guard await poll(Self.quitPolls, until: { !self.system.isRunning(app) }) else {
            return .failure(.stillQuitting)
        }
        guard let restart = await reopen(app) else { return .failure(.didNotReopen) }
        return .success(restart)
    }

    /// Opens an app that has quit and waits for its item; nil if it couldn't be opened.
    private func reopen(_ app: RunningMenuBarApp) async -> Restart? {
        let started = ContinuousClock.now
        guard await system.open(app, .standard) != nil else {
            Self.log.error("Spacing: \(app.bundleID, privacy: .public) quit but didn't reopen")
            return nil
        }
        let drawn = await poll(Self.drawPolls) { await self.system.isDrawn(app) }
        let elapsed = ContinuousClock.now - started
        Self.log.notice("Spacing: restarted \(app.bundleID, privacy: .public); item drawn: \(drawn, privacy: .public) after \(elapsed, privacy: .public)")
        return Restart(app: app, iconReturned: drawn)
    }

    /// Checks `done` up to `polls` + 1 times, `pollInterval` apart; whether it came true.
    private func poll(_ polls: Int, until done: () async -> Bool) async -> Bool {
        for _ in 0..<polls {
            if await done() { return true }
            await system.sleep(Self.pollInterval)
        }
        return await done()
    }
}

// MARK: - The real Mac

extension SpacingApplier {
    /// An applier for this Mac. `hidden` gives the apps YeeHaw keeps hidden: their item is never
    /// drawn, so for them "back" means finished launching.
    convenience init(hidden: @escaping @MainActor () -> Set<BundleID>) {
        self.init(system: .live(hidden: hidden))
        Self.live.removeAll { $0.applier == nil }
        Self.live.append(WeakApplier(applier: self))
    }
}

private struct WeakApplier {
    weak var applier: SpacingApplier?
}

extension SpacingSystem {
    /// YeeHaw's own defaults key for the spacing history.
    static let historyKey = "SpacingHistory"

    static func live(hidden: @escaping @MainActor () -> Set<BundleID>) -> SpacingSystem {
        let domain = kCFPreferencesAnyApplication, user = kCFPreferencesCurrentUser
        func host(_ host: PreferenceHost) -> CFString {
            host == .current ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost
        }
        return SpacingSystem(
            readPreference: { key, which in CFPreferencesCopyValue(key as CFString, domain, user, host(which)) },
            writePreferences: { writes in
                for write in writes {
                    CFPreferencesSetValue(write.key as CFString, write.value.map { $0 as CFNumber }, domain, user,
                                          host(write.host))
                }
                return Set(writes.map(\.host)).allSatisfy { CFPreferencesSynchronize(domain, user, host($0)) }
            },
            loadHistory: {
                UserDefaults.standard.data(forKey: historyKey)
                    .flatMap { try? JSONDecoder().decode(SpacingHistory.self, from: $0) }
            },
            saveHistory: { history in
                if let data = try? JSONEncoder().encode(history) {
                    UserDefaults.standard.set(data, forKey: historyKey)
                }
            },
            now: { Date() },
            isRunning: { app in RunningMenuBarApps.instances(of: app).contains { !$0.isTerminated } },
            terminate: { app in
                let running = RunningMenuBarApps.instances(of: app).filter { !$0.isTerminated }
                return !running.isEmpty && running.map { $0.terminate() }.allSatisfy(\.self)
            },
            open: { app, options in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = options.activates
                configuration.hides = options.hides
                configuration.addsToRecentItems = options.addsToRecentItems
                do {
                    let running = try await NSWorkspace.shared.openApplication(at: URL(filePath: app.bundlePath),
                                                                               configuration: configuration)
                    return running.processIdentifier
                } catch {
                    SpacingApplier.log.error("Couldn't open \(app.bundlePath, privacy: .public): \(error, privacy: .public)")
                    return nil
                }
            },
            isDrawn: { app in
                if hidden().contains(app.bundleID) {
                    return RunningMenuBarApps.instances(of: app).contains { $0.isFinishedLaunching }
                }
                return await AXMenuBarReader().drawnBar(owning: app.bundleID).contains { $0.bundleID == app.bundleID }
            },
            hasOpenWindows: { app in await RunningMenuBarApps.hasOpenWindows(app) },
            sleep: { duration in try? await Task.sleep(for: duration) })
    }
}
