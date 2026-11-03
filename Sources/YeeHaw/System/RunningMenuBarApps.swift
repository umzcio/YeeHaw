import AppKit
import ApplicationServices
import os
import YeeHawCore

/// Which running apps own a third-party menu bar item, and whether each has windows open (spec
/// "Spacing Apply" 1). The decisions are `SpacingPlan.appOrder` and `SpacingPlan.hasOpenWindows`;
/// this gathers the facts they need from the Mac.
enum RunningMenuBarApps {
    private static let log = Logger(subsystem: Log.subsystem, category: "spacing")
    /// Per-app messaging timeout for Accessibility's window list.
    static let timeout: Float = 0.3
    /// Windows smaller than this either way are strips and overlays, not windows a user works in.
    static let minimumWindowSide: Double = 100

    /// The running apps owning a third-party item: those drawn, in the bar's order, then the
    /// hidden ones that are running.
    @concurrent
    static func list(drawn: [MenuBarItem], hidden: [BundleID]) async -> [RunningMenuBarApp] {
        let running = NSWorkspace.shared.runningApplications
        let windows = WindowCounts.read()
        var summary: [String] = []
        defer { log.notice("Spacing apps: \(summary.joined(separator: "; "), privacy: .public)") }
        return SpacingPlan.appOrder(drawn: drawn.map(\.bundleID), hidden: hidden).compactMap { id in
            guard let app = running.first(where: { $0.bundleIdentifier == id && !$0.isTerminated
                      && $0.bundleURL?.pathExtension == "app" }),
                  let url = app.bundleURL else { return nil }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            let facts = facts(for: app, windows: windows)
            let open = SpacingPlan.hasOpenWindows(facts)
            summary.append("\(id) ax \(facts.axWindows.map(String.init) ?? "-") on \(facts.onScreenWindows) all \(facts.windowsAnywhere)"
                           + "\(facts.isHidden ? " hidden" : "")\(facts.isRegular ? " regular" : "") -> \(open ? "windows" : "none")")
            return RunningMenuBarApp(bundleID: id, bundlePath: url.path, name: name, hasOpenWindows: open,
                                     isHidden: app.isHidden, launchDate: app.launchDate)
        }
    }

    /// Whether `app` has windows open right now (any of its instances).
    @concurrent
    static func hasOpenWindows(_ app: RunningMenuBarApp) async -> Bool {
        let windows = WindowCounts.read()
        return instances(of: app).contains { instance in
            !instance.isTerminated && SpacingPlan.hasOpenWindows(facts(for: instance, windows: windows))
        }
    }

    /// The app's running instances from its own bundle (not a helper sharing its bundle ID).
    nonisolated static func instances(of app: RunningMenuBarApp) -> [NSRunningApplication] {
        let path = (app.bundlePath as NSString).standardizingPath
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).filter {
            $0.bundleURL.map { ($0.path as NSString).standardizingPath == path } ?? false
        }
    }

    private static func facts(for app: NSRunningApplication, windows: WindowCounts) -> WindowFacts {
        let pid = app.processIdentifier
        return WindowFacts(pid: pid, isHidden: app.isHidden, isRegular: app.activationPolicy == .regular,
                           axWindows: accessibilityWindowCount(pid), onScreenWindows: windows.onScreen[pid, default: 0],
                           windowsAnywhere: windows.anywhere[pid, default: 0])
    }

    /// Accessibility's window list for the current Space (hidden and minimized windows included),
    /// or nil if it can't be read.
    private static func accessibilityWindowCount(_ pid: pid_t) -> Int? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [CFTypeRef] else { return nil }
        return windows.count
    }

    /// Normal-level windows per process: on screen now, and anywhere the window server knows of
    /// (other Spaces, minimized, hidden, ordered out).
    private struct WindowCounts {
        var onScreen: [pid_t: Int] = [:]
        var anywhere: [pid_t: Int] = [:]

        static func read() -> WindowCounts {
            var counts = WindowCounts()
            let all = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            for window in all {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                      let pid = (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                      let bounds = window[kCGWindowBounds as String] as? [String: Double],
                      (bounds["Width"] ?? 0) >= minimumWindowSide, (bounds["Height"] ?? 0) >= minimumWindowSide
                else { continue }
                counts.anywhere[pid, default: 0] += 1
                if window[kCGWindowIsOnscreen as String] as? Bool == true {
                    counts.onScreen[pid, default: 0] += 1
                }
            }
            return counts
        }
    }
}
