import AppKit
import os
import YeeHawCore

@main
@MainActor
final class YeeHawApp: NSObject, NSApplicationDelegate {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "app")

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
    }
}
