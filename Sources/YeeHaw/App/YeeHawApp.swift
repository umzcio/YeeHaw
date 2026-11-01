import AppKit
import os
import YeeHawCore

@main
@MainActor
final class YeeHawApp: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "app")

    private var controller: MenuBarController?
    private var statusItem: StatusItemController?
    private var watcher: AllowListWatcher?

    static func main() {
        let app = NSApplication.shared
        let delegate = YeeHawApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let command = DebugCommand(arguments: CommandLine.arguments) {
            Task {
                await command.run()
                // exit, not terminate: a debug run must never reach any quit-time writes.
                exit(0)
            }
            return
        }
        Self.log.notice("YeeHaw started")

        let grants = FileGrantStore()
        let controller = MenuBarController(
            allowFile: GrantedPreferencesFile(file: .allowList, grants: grants),
            positionFile: GrantedPreferencesFile(file: .positions, grants: grants),
            reader: AXMenuBarReader(), store: DefaultsStateStore(), sleeper: TaskSleeper())
        let icons = IconImageProvider()
        // A stub until Settings exists (ruling R37).
        let openSettings = { Self.log.notice("Settings… chosen; Settings isn't built yet") }
        let status = StatusItemController(
            controller: controller,
            reveal: RevealCoordinator(controller: controller),
            icons: icons,
            openLayout: {
                showLayoutWindow(controller: controller, images: icons) { await grants.requestGrant(for: $0) }
            },
            openSettings: openSettings)
        self.controller = controller
        statusItem = status

        // Started before the launch: the controller's gate runs calls in order, so a change seen
        // while launching is applied right after it (ruling M9).
        watcher = AllowListWatcher(grants: grants) {
            Task {
                do {
                    try await controller.allowListChanged()
                    LayoutWindowController.current?.allowListChanged()
                } catch {
                    Self.log.error("Allow list change not applied: \(error, privacy: .public)")
                }
            }
        }
        Task {
            await status.captureHiddenBeforeLaunch()
            do {
                try await controller.launch()
            } catch {
                // A missing grant is recorded in state.needsGrant, which the strip's notice shows.
                Self.log.error("Launch failed: \(error, privacy: .public)")
            }
            await status.start(grants: grants)
        }
    }

    /// Every ordinary quit (the menu's Quit YeeHaw, logout, a quit Apple event) goes through the
    /// controller, which switches back on everything YeeHaw switched off. A second call, after
    /// the menu's own, finds nothing to do. Debug runs exit before this and never get here.
    func applicationWillTerminate(_ notification: Notification) {
        guard let controller else { return }
        do {
            try controller.quit()
        } catch {
            Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
        }
    }
}
