import AppKit
import os
import ServiceManagement
import YeeHawCore

@main
@MainActor
final class YeeHawApp: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: Log.subsystem, category: "app")

    private var controller: MenuBarController?
    private var grants: FileGrantStore?
    private var icons: IconImageProvider?
    private var statusItem: StatusItemController?
    private var watcher: AllowListWatcher?
    /// Why this quit is happening, read from the quit Apple event in `applicationShouldTerminate`.
    private var quitReason = LaunchRules.QuitReason.ordinary
    /// One per signal in `quitSignals`, each turned into an ordinary quit so hidden apps are
    /// switched back on.
    private var terminationSignals: [DispatchSourceSignal] = []
    /// Watches for Thaw starting while YeeHaw runs.
    private var thawObserver: NSObjectProtocol?
    /// Watches for hidden apps opening from a copy their Allow-list entry doesn't list.
    private var launchObserver: NSObjectProtocol?

    static func main() {
        let app = NSApplication.shared
        let delegate = YeeHawApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let command = DebugCommand(arguments: CommandLine.arguments)
        if let command, command.isReadOnly {
            run(command)
            return
        }

        // Before anything is written, debug runs that write included.
        let apps = NSWorkspace.shared.runningApplications
        if case .refuse(let refusal) = LaunchRules.check(os: ProcessInfo.processInfo.operatingSystemVersion,
                                                         running: Set(apps.compactMap(\.bundleIdentifier)),
                                                         anotherInstance: Self.anotherInstanceRuns(among: apps)) {
            if command != nil {
                DebugCommand.refused(refusal)
                exit(1)
            }
            refuseToStart(refusal)
            return
        }
        if let command {
            run(command)
            return
        }
        Self.log.notice("YeeHaw started")
        quitOnTerminationSignals()
        watchForThaw()
        // Earlier Spacing Applies left the apps they restarted hidden; show them again, once.
        Task { await HiddenMenuBarApps.unhideOnce() }

        let grants = FileGrantStore()
        let controller = MenuBarController.live(grants: grants)
        self.grants = grants
        self.controller = controller
        let icons = IconImageProvider()
        icons.barWrites = { [weak controller] in controller?.writeCount ?? 0 }
        icons.proveOwnership = { [weak controller] items in
            guard let controller else { return [] }
            await controller.refresh()
            return ItemMatcher.photographable(items, reread: controller.items, offApps: controller.switchedOff)
        }
        self.icons = icons
        AppWindows.openSettings = { [weak self] in self?.openSettings() }

        let steps = LaunchRules.steps(onboardingComplete: OnboardingRecord.isComplete,
                                      pendingReveal: controller.state.pendingReveal != nil)
        Task {
            for step in steps { await perform(step) }
        }
    }

    /// A debug command, then exit; `exit`, not `terminate`, so it never reaches quit-time writes.
    private func run(_ command: DebugCommand) {
        Task {
            await command.run()
            exit(0)
        }
    }

    /// Whether another copy of YeeHaw (a build run from elsewhere, or `open -n`) is the one that
    /// keeps running. Two copies would each save their own record of what they switched off over
    /// the other's.
    private static func anotherInstanceRuns(among apps: [NSRunningApplication]) -> Bool {
        let me = NSRunningApplication.current
        let ownID = Bundle.main.bundleIdentifier ?? OwnIconLocator.bundleID
        return apps.contains { app in
            app.bundleIdentifier == ownID && !app.isTerminated
                && LaunchRules.isAnotherInstance(mine: (me.processIdentifier, me.launchDate),
                                                 other: (app.processIdentifier, app.launchDate))
        }
    }

    /// What `kill` and `pkill` (SIGTERM), Control-C (SIGINT), closing the Terminal window YeeHaw
    /// runs in (SIGHUP) and Control-\ (SIGQUIT) send. By default each ends the process on the
    /// spot, leaving hidden apps switched off. SIGKILL and crashes can't be caught; `--restore` is
    /// for those.
    nonisolated static let quitSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

    /// Each of `quitSignals` is ignored as a signal and handled on the main queue as an ordinary
    /// quit instead, which switches hidden apps back on.
    private func quitOnTerminationSignals() {
        for number in Self.quitSignals {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    Self.log.notice("Signal \(number, privacy: .public) received; quitting the ordinary way")
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            terminationSignals.append(source)
        }
    }

    /// Thaw edits the same two files. If it starts while YeeHaw runs, YeeHaw stops editing: it
    /// switches back on what it hid, says why, and quits.
    private func watchForThaw() {
        thawObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == LaunchRules.thawBundleID else { return }
            MainActor.assumeIsolated { self?.thawStarted() }
        }
    }

    private func thawStarted() {
        Self.log.notice("Thaw started; switching hidden apps back on and quitting")
        watcher = nil
        launchObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        launchObserver = nil
        if let controller {
            do {
                try controller.quit()
            } catch {
                Self.log.error("Quit could not switch hidden apps back on: \(error, privacy: .public)")
            }
        }
        refuseToStart(.thawRunning)
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
            // seen while launching is applied right after it.
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
            watchForHiddenAppLaunches(controller)

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

    /// A hidden app opened from a copy its Allow-list entry doesn't list (another build, another
    /// folder) would draw its icon again; the controller lists that copy and switches the app off.
    /// The launch did the same for the hidden apps already running.
    private func watchForHiddenAppLaunches(_ controller: MenuBarController) {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                guard controller.state.hidden.contains(id) else { return }
                Task {
                    do {
                        try await controller.appLaunched(id)
                    } catch {
                        Self.log.error("Could not keep \(id, privacy: .public) hidden after it opened: \(error, privacy: .public)")
                    }
                }
            }
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

    /// The launch guards (and Thaw starting later): says why, then quits.
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
        // An app Spacing Apply just quit is opened again before YeeHaw goes; the rest are left
        // running, as they were.
        if SpacingApplier.anyApplying {
            Self.log.notice("Quit waits for Spacing Apply to reopen the app it's restarting")
            SpacingApplier.stopAllAfterCurrentApp { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateNow
    }

    /// Every ordinary quit goes through the controller, which switches back on everything YeeHaw
    /// switched off. A second call, after the status menu's own, finds nothing to do. At logout,
    /// restart and shutdown hidden apps stay hidden when YeeHaw opens at login
    /// (`LaunchRules.switchesBackOnAtTermination`). Debug runs exit before this.
    func applicationWillTerminate(_ notification: Notification) {
        guard let controller else { return }
        let opensAtLogin = SMAppService.mainApp.status == .enabled
        guard LaunchRules.switchesBackOnAtTermination(quitReason, opensAtLogin: opensAtLogin) else {
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
