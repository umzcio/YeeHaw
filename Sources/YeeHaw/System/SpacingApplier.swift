import AppKit
import ApplicationServices
import os
import YeeHawCore

/// What `SpacingApplier` needs from the Mac, so its sequencing can be tested with a fake.
@MainActor
struct SpacingSystem {
    /// A current-host global preference.
    var readPreference: (String) -> Any?
    /// Stores current-host global preferences; nil deletes the key.
    var writePreferences: ([String: Int?]) -> Void
    var isRunning: (RunningMenuBarApp) -> Bool
    /// Asks the app to quit, the way Quit in its menu would. False if it refused outright.
    var terminate: (RunningMenuBarApp) -> Bool
    /// Opens the app again, without bringing it to the front; false if it couldn't be opened.
    var open: (RunningMenuBarApp) async -> Bool
    /// Whether the reopened app's menu bar item is back.
    var isDrawn: (RunningMenuBarApp) async -> Bool
    /// Hides the app, like Command-H, if it isn't hidden already.
    var hide: (RunningMenuBarApp) -> Void
    var sleep: (Duration) async -> Void
}

/// Applies a spacing (spec Technique 4 and "Spacing Apply"): writes both preferences, then
/// restarts the chosen apps one at a time so they pick it up. Never force-quits: an app still
/// running ten seconds after being asked to quit is skipped and left alone.
@MainActor
final class SpacingApplier {
    enum SkipReason: Equatable {
        /// It refused to quit, or was still running ten seconds after being asked.
        case declinedToQuit
        /// It had quit by the time its turn came.
        case notRunning
        /// It quit but couldn't be opened again.
        case didNotReopen
    }

    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "spacing")
    static let pollInterval: Duration = .milliseconds(100)
    /// How long an app gets to quit, and a reopened app to draw its item: 10 s each.
    static let quitPolls = 100
    static let drawPolls = 100
    /// How long a reopened app that had no windows is kept hidden after its item is back: 1 s.
    static let settlePolls = 10

    private let system: SpacingSystem
    /// Why each app of the last `apply` was skipped, by name.
    private(set) var skipReasons: [String: SkipReason] = [:]
    /// Told as each app's restart begins: the app, its index and how many there are.
    var onProgress: ((RunningMenuBarApp, Int, Int) -> Void)?

    init(system: SpacingSystem) {
        self.system = system
    }

    /// The spacing apps launched from now on get: the stored `NSStatusItemSpacing`, or 16 when
    /// it isn't set.
    func currentValue() -> Int {
        SpacingPlan.value(fromPreference: system.readPreference(SpacingPlan.spacingKey))
    }

    /// Stores `value` (the default deletes both keys, back to stock) and restarts `relaunch` in
    /// order. Returns the names of the apps restarted and skipped; `skipReasons` says why.
    func apply(_ value: Int, relaunch: [RunningMenuBarApp]) async -> (restarted: [String], skipped: [String]) {
        let value = SpacingPlan.clamped(value)
        system.writePreferences(SpacingPlan.preferenceValues(for: value))
        Self.log.notice("Spacing set to \(value, privacy: .public); restarting \(relaunch.count, privacy: .public) app(s)")
        skipReasons = [:]
        var restarted: [String] = []
        var skipped: [String] = []
        for (index, app) in relaunch.enumerated() {
            onProgress?(app, index, relaunch.count)
            if let reason = await restart(app) {
                skipped.append(app.name)
                skipReasons[app.name] = reason
                Self.log.notice("Spacing: skipped \(app.bundleID, privacy: .public) (\(String(describing: reason), privacy: .public))")
            } else {
                restarted.append(app.name)
            }
        }
        return (restarted, skipped)
    }

    /// Quits and reopens one app; nil once it's back, else why it was skipped.
    private func restart(_ app: RunningMenuBarApp) async -> SkipReason? {
        guard system.isRunning(app) else { return .notRunning }
        guard system.terminate(app) else { return .declinedToQuit }
        guard await poll(Self.quitPolls, until: { !self.system.isRunning(app) }) else { return .declinedToQuit }
        let started = ContinuousClock.now
        guard await system.open(app) else {
            Self.log.error("Spacing: \(app.bundleID, privacy: .public) quit but didn't reopen")
            return .didNotReopen
        }
        let drawn = await poll(Self.drawPolls) { await self.system.isDrawn(app) }
        let elapsed = ContinuousClock.now - started
        Self.log.notice("Spacing: restarted \(app.bundleID, privacy: .public); item drawn: \(drawn, privacy: .public) after \(elapsed, privacy: .public)")
        if !app.hasVisibleWindows { await keepHidden(app) }
        return nil
    }

    /// An app that had no windows open comes back with none on screen. Some open their main
    /// window at launch even when launched hidden (DigUp does, and takes the focus), so the app
    /// is hidden again, the way Command-H would, for a moment while it settles. Its windows are
    /// left as they are, and it shows them the next time it's used.
    private func keepHidden(_ app: RunningMenuBarApp) async {
        for _ in 0..<Self.settlePolls {
            system.hide(app)
            await system.sleep(Self.pollInterval)
        }
        system.hide(app)
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
    }
}

extension SpacingSystem {
    static func live(hidden: @escaping @MainActor () -> Set<BundleID>) -> SpacingSystem {
        let domain = kCFPreferencesAnyApplication, user = kCFPreferencesCurrentUser, host = kCFPreferencesCurrentHost
        return SpacingSystem(
            readPreference: { key in CFPreferencesCopyValue(key as CFString, domain, user, host) },
            writePreferences: { values in
                for (key, value) in values {
                    CFPreferencesSetValue(key as CFString, value.map { $0 as CFNumber }, domain, user, host)
                }
                CFPreferencesSynchronize(domain, user, host)
            },
            isRunning: { app in instances(of: app).contains { !$0.isTerminated } },
            terminate: { app in
                let running = instances(of: app).filter { !$0.isTerminated }
                return !running.isEmpty && running.map { $0.terminate() }.allSatisfy(\.self)
            },
            open: { app in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.addsToRecentItems = false
                // An app that had no windows open comes back the same way: launched hidden, like
                // a login item, so one that opens its main window at launch (DigUp does) doesn't
                // put it on screen or take the focus.
                configuration.hides = !app.hasVisibleWindows
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: URL(filePath: app.bundlePath),
                                                                     configuration: configuration)
                    return true
                } catch {
                    Logger(subsystem: "com.zapps.yeehaw", category: "spacing")
                        .error("Couldn't open \(app.bundlePath, privacy: .public): \(error, privacy: .public)")
                    return false
                }
            },
            isDrawn: { app in
                if hidden().contains(app.bundleID) {
                    return instances(of: app).contains { $0.isFinishedLaunching }
                }
                return !(await AXMenuBarReader().items(of: app.bundleID)).isEmpty
            },
            hide: { app in
                for instance in instances(of: app) where !instance.isHidden && !instance.isTerminated {
                    instance.hide()
                }
            },
            sleep: { duration in try? await Task.sleep(for: duration) })
    }

    /// The app's running instances from its own bundle (not a helper sharing its bundle ID).
    private static func instances(of app: RunningMenuBarApp) -> [NSRunningApplication] {
        let path = (app.bundlePath as NSString).standardizingPath
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).filter {
            $0.bundleURL.map { ($0.path as NSString).standardizingPath == path } ?? false
        }
    }
}

// MARK: - Which apps own an item

enum RunningMenuBarApps {
    /// Per-app messaging timeout for the window check.
    static let timeout: Float = 0.3

    /// The running apps owning a third-party item: those drawn, in the bar's order, then the
    /// hidden ones that are running.
    @concurrent
    static func list(drawn: [MenuBarItem], hidden: [BundleID]) async -> [RunningMenuBarApp] {
        var order: [BundleID] = []
        for id in drawn.compactMap(\.bundleID) + hidden where !order.contains(id) {
            order.append(id)
        }
        let running = NSWorkspace.shared.runningApplications
        let onScreen = onScreenWindowOwners()
        return order.compactMap { id -> RunningMenuBarApp? in
            guard let app = running.first(where: { $0.bundleIdentifier == id && !$0.isTerminated
                      && $0.bundleURL?.pathExtension == "app" }),
                  let url = app.bundleURL else { return nil }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            // A hidden app shows nothing; it's restarted hidden too.
            let visible = !app.isHidden && hasWindows(app.processIdentifier, onScreen: onScreen)
            return RunningMenuBarApp(bundleID: id, bundlePath: url.path, name: name, hasVisibleWindows: visible)
        }
    }

    /// Whether the app has a window open: Accessibility's window list (which includes minimized
    /// windows), or, if that can't be read, a normal-level window on screen.
    private static func hasWindows(_ pid: pid_t, onScreen: Set<pid_t>) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [CFTypeRef] else { return onScreen.contains(pid) }
        return !windows.isEmpty
    }

    /// Owners of on-screen windows at the normal window level.
    private static func onScreenWindowOwners() -> Set<pid_t> {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return Set(info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
        })
    }
}
