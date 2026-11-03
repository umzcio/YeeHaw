import AppKit
import os
import YeeHawCore

/// Quits an app the polite way and opens it again, for the strip's Restart: an app whose icon
/// stopped opening anything usually works again after a restart. Never force-quits. Reopens shown
/// and in the background, never hidden: apps reopened hidden are what broke icons on 2026-11-02.
@MainActor
enum AppRestarter {
    /// How long an app gets to quit before the restart gives up and leaves it running.
    static let quitTimeout: Duration = .seconds(10)
    static let pollInterval: Duration = .milliseconds(250)
    private static let log = Logger(subsystem: Log.subsystem, category: "health")

    /// True once every copy quit and every bundle opened again.
    static func restart(_ id: BundleID) async -> Bool {
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
            !$0.isTerminated && $0.bundleURL?.pathExtension == "app"
        }
        let bundles = Array(Set(copies.compactMap(\.bundleURL)))
        guard !bundles.isEmpty else { return false }
        for copy in copies {
            guard copy.terminate() else {
                log.error("\(id, privacy: .public) refused to quit; not restarting it")
                return false
            }
        }
        let deadline = ContinuousClock.now + quitTimeout
        while copies.contains(where: { !$0.isTerminated }) {
            guard ContinuousClock.now < deadline else {
                log.error("\(id, privacy: .public) hadn't quit after 10 s; not reopening it")
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = false
        var reopened = true
        for bundle in bundles {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
            } catch {
                reopened = false
                log.error("Couldn't reopen \(bundle.path, privacy: .public): \(error, privacy: .public)")
            }
        }
        if reopened { log.notice("Restarted \(id, privacy: .public)") }
        return reopened
    }
}
