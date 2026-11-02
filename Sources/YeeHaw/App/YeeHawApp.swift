import AppKit
import os
import YeeHawCore

@main
@MainActor
final class YeeHawApp: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "app")

    private var controller: MenuBarController?
    private var grants: FileGrantStore?
    private var icons: IconImageProvider?
    private var statusItem: StatusItemController?
    private var watcher: AllowListWatcher?
    /// Why this quit is happening, read from the quit Apple event in `applicationShouldTerminate`.
    private var quitReason = LaunchRules.QuitReason.ordinary

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

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if case .refuse(let refusal) = LaunchRules.check(os: ProcessInfo.processInfo.operatingSystemVersion,
                                                         running: running) {
            refuseToStart(refusal)
            return
        }
        Self.log.notice("YeeHaw started")

        let grants = FileGrantStore()
        let controller = MenuBarController(
            allowFile: GrantedPreferencesFile(file: .allowList, grants: grants),
            positionFile: GrantedPreferencesFile(file: .positions, grants: grants),
            reader: AXMenuBarReader(), store: DefaultsStateStore(), sleeper: TaskSleeper())
        self.grants = grants
        self.controller = controller
        icons = IconImageProvider()
        AppWindows.openSettings = { [weak self] in self?.openSettings() }

        let steps = LaunchRules.steps(onboardingComplete: OnboardingRecord.isComplete,
                                      pendingReveal: controller.state.pendingReveal != nil)
        Task {
            for step in steps { await perform(step) }
        }
    }

    // MARK: Launch steps

    private func perform(_ step: LaunchRules.Step) async {
        guard let controller, let grants, let icons else { return }
        switch step {
        case .endPendingReveal:
            do {
                try await controller.endReveal()
                Self.log.notice("Undid a reveal left by a crash before onboarding")
            } catch {
                Self.log.error("Could not undo the reveal left by a crash: \(error, privacy: .public)")
            }

        case .onboarding:
            let model = OnboardingModel(system: LiveOnboardingSystem(controller: controller, grants: grants))
            let finished = await OnboardingWindowController.run(model: model)
            if finished { OnboardingRecord.isComplete = true }
            Self.log.notice("Onboarding \(finished ? "finished" : "closed early; it opens again next launch", privacy: .public)")

        case .launchController:
            // Started before the launch: the controller's gate runs calls in order, so a change
            // seen while launching is applied right after it (ruling M9).
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
            await StatusItemController.captureHiddenBeforeLaunch(controller: controller, icons: icons)
            do {
                try await controller.launch()
            } catch {
                // A missing grant is recorded in state.needsGrant, which the strip's notice shows.
                Self.log.error("Launch failed: \(error, privacy: .public)")
            }

        case .showStatusItem:
            let status = StatusItemController(
                controller: controller,
                reveal: RevealCoordinator(controller: controller),
                icons: icons,
                openLayout: {
                    showLayoutWindow(controller: controller, images: icons) { await grants.requestGrant(for: $0) }
                },
                openSettings: { [weak self] in self?.openSettings() })
            statusItem = status
            await status.start(grants: grants)
        }
    }

    /// Opens Settings. A file grant fixed there relaunches the controller once YeeHaw is running,
    /// so whatever couldn't be hidden without it is hidden now.
    private func openSettings() {
        guard let controller, let grants else { return }
        let source = LiveOnboardingSystem(controller: controller, grants: grants)
        SettingsWindowController.show(model: {
            let model = SettingsModel(loginItem: LoginItemModel(service: MainAppLoginItem()),
                                      permissions: LivePermissions(files: .live(grants: grants, controller: controller)),
                                      review: SwitchedOffReviewModel(source: source))
            model.onGrantFixed = { [weak self] _ in
                guard self?.statusItem != nil else { return }
                Task {
                    do {
                        try await controller.launch()
                        LayoutWindowController.current?.allowListChanged()
                    } catch {
                        Self.log.error("Launch after a fixed grant failed: \(error, privacy: .public)")
                    }
                }
            }
            return model
        }())
    }

    /// The macOS-version and Thaw guards: says why, then quits. Nothing has been written.
    private func refuseToStart(_ refusal: LaunchRules.Refusal) {
        Self.log.error("Not starting: \(refusal.title, privacy: .public)")
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = refusal.title
        alert.informativeText = refusal.message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Reads why YeeHaw is quitting while the quit Apple event is still the current one. Logout,
    /// restart and shutdown carry a `kAEQuitReason`; the app menu's Quit, the status menu's Quit
    /// YeeHaw and an ordinary quit event don't. Decided per quit, so a logout another app
    /// cancelled leaves nothing behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let code = event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        quitReason = LaunchRules.QuitReason(code: code)
        return .terminateNow
    }

    /// Every ordinary quit goes through the controller, which switches back on everything YeeHaw
    /// switched off. A second call, after the status menu's own, finds nothing to do. At logout,
    /// restart and shutdown hidden apps stay hidden (`LaunchRules.switchesBackOnAtTermination`).
    /// Debug runs exit before this.
    func applicationWillTerminate(_ notification: Notification) {
        guard let controller else { return }
        guard LaunchRules.switchesBackOnAtTermination(quitReason) else {
            Self.log.notice("Quitting for \(String(describing: self.quitReason), privacy: .public); hidden apps stay hidden until next launch")
            return
        }
        do {
            try controller.quit()
        } catch {
            Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
        }
    }
}
