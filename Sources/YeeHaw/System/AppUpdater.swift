import AppKit
import Observation
import os
import Sparkle
import YeeHawCore

/// Finds, downloads and installs new versions of YeeHaw with Sparkle. The feed is the newest
/// GitHub release's appcast.xml, and Sparkle installs only an update signed with the key whose
/// public half is in Info.plist. Installing quits YeeHaw the ordinary way, which switches hidden
/// apps back on; the new version hides them again when it opens.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()
    private nonisolated static let log = Logger(subsystem: Log.subsystem, category: "updates")

    /// Nil when this build has no update feed (an unbundled run, a test) or Sparkle couldn't start.
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    /// Whether Sparkle looks for a new version on its own, once a day. On unless turned off in
    /// Settings (`SUEnableAutomaticChecks`).
    var checksAutomatically: Bool {
        get {
            access(keyPath: \.checksAutomatically)
            return controller?.updater.automaticallyChecksForUpdates ?? false
        }
        set {
            withMutation(keyPath: \.checksAutomatically) {
                controller?.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    private init(bundle: Bundle = .main) {
        guard UpdateFeed(feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                         publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) != nil else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try controller.updater.start()
            self.controller = controller
        } catch {
            Self.log.error("Updates couldn't start: \(error.localizedDescription, privacy: .public)")
            self.controller = nil
        }
    }

    /// Checks now and shows what Sparkle finds, "You're up to date" included. Asked again once the
    /// status menu has closed, as `AppWindows.bringForward` does: on 27.2 an activation request
    /// made while the menu is closing is refused, and Sparkle's window would open behind others.
    func checkForUpdates() {
        guard let controller else {
            Self.showUnavailable()
            return
        }
        Task {
            try? await Task.sleep(for: AppWindows.activationRetryDelay)
            NSApp.activate(ignoringOtherApps: true)
            controller.checkForUpdates(nil)
        }
    }

    private static func showUnavailable() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "This copy of YeeHaw can’t update itself"
        alert.informativeText = "It was built without an update feed. Download the newest YeeHaw from "
            + "github.com/umzcio/YeeHaw/releases."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
