import AppKit
import ApplicationServices
import Foundation
import YeeHawCore

/// Hands-on checks run from the command line. `--probe` and `--grant` only read (apart from saving
/// a grant the user picks) and never start the controller; `--hide`, `--show` and `--reveal` do.
/// Output goes to stdout and to `~/Library/Logs/YeeHaw/probe.txt`, since an app launched with
/// `open` has no visible stdout.
enum DebugCommand {
    /// `--probe`: what's drawn and who owns it, the user-owned-off apps, and missing grants.
    case probe
    /// `--grant`: asks for both file grants in turn.
    case grant
    /// `--hide <bundleID>`: launches the controller and hides the app.
    case hide(BundleID)
    /// `--show <bundleID>`: launches the controller and shows the app.
    case show(BundleID)
    /// `--reveal <bundleID>`: shows a placeholder YeeHaw icon and runs one reveal next to it.
    case reveal(BundleID)
    /// One of the bundle ID arguments was given without a bundle ID.
    case missingBundleID(flag: String)

    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Logs/YeeHaw/probe.txt")
    static let yeehawBundleID = "com.zapps.yeehaw"
    /// How long `--reveal` waits for its placeholder icon to be drawn and get a position key.
    static let iconTimeout: Double = 5
    static let iconPollInterval: Double = 0.1

    init?(arguments: [String]) {
        if arguments.contains("--probe") {
            self = .probe
            return
        }
        if arguments.contains("--grant") {
            self = .grant
            return
        }
        let flags: [(String, (BundleID) -> DebugCommand)] = [
            ("--hide", DebugCommand.hide), ("--show", DebugCommand.show), ("--reveal", DebugCommand.reveal),
        ]
        for (flag, command) in flags {
            guard let index = arguments.firstIndex(of: flag) else { continue }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("-") else {
                self = .missingBundleID(flag: flag)
                return
            }
            self = command(arguments[next])
            return
        }
        return nil
    }

    @MainActor
    func run() async {
        let grants = FileGrantStore()
        var lines: [String] = []
        switch self {
        case .probe:
            lines = await Self.probe(grants: grants)
        case .grant:
            for file in [GrantedFile.allowList, .positions] {
                lines.append("grant \(file.rawValue): \(await grants.requestGrant(for: file))")
            }
        case .hide(let id):
            lines = await Self.setHidden(id, true, grants: grants)
        case .show(let id):
            lines = await Self.setHidden(id, false, grants: grants)
        case .reveal(let id):
            lines = await Self.reveal(id, grants: grants)
        case .missingBundleID(let flag):
            lines = ["\(flag) needs a bundle ID, for example \(flag) com.example.app"]
        }
        Self.emit(lines)
    }

    @MainActor
    private static func makeController(grants: FileGrantStore) -> MenuBarController {
        MenuBarController(
            allowFile: GrantedPreferencesFile(file: .allowList, grants: grants),
            positionFile: GrantedPreferencesFile(file: .positions, grants: grants),
            reader: AXMenuBarReader(), store: DefaultsStateStore(), sleeper: TaskSleeper())
    }

    /// `--hide` / `--show`. The process exits right after, without `quit()`, so a hidden app stays hidden.
    @MainActor
    private static func setHidden(_ id: BundleID, _ hide: Bool, grants: FileGrantStore) async -> [String] {
        let verb = hide ? "hide" : "show"
        let controller = makeController(grants: grants)
        do {
            try await controller.launch()
        } catch {
            return ["launch failed: \(error)"]
        }
        do {
            if hide { try await controller.hide(id) } else { try await controller.show(id) }
        } catch {
            return ["\(verb) \(id) failed: \(error)"]
        }
        return ["\(verb) \(id): ok", "hidden: \(listed(controller.state.hidden))"]
    }

    /// `--reveal`. Shows a placeholder YeeHaw icon, waits until it's drawn and has a position key,
    /// then runs one reveal next to it. Nothing is written until the icon is ready.
    @MainActor
    private static func reveal(_ id: BundleID, grants: FileGrantStore) async -> [String] {
        guard AXIsProcessTrusted() else { return ["accessibility: not trusted"] }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "YeeHaw"
        statusItem.button?.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "YeeHaw")
        defer { withExtendedLifetime(statusItem) {} }

        var lines: [String] = []
        guard let yeehaw = await waitForIcon(grants: grants, log: { lines.append($0) }) else { return lines }

        let controller = makeController(grants: grants)
        do {
            try await controller.launch()
        } catch {
            lines.append("launch failed: \(error)")
            return lines
        }
        let coordinator = RevealCoordinator(controller: controller) { lines.append($0) }
        await coordinator.open(id, nextTo: yeehaw)
        return lines
    }

    /// YeeHaw's drawn item once the position key `beginReveal` will resolve for it exists, or nil
    /// (with the reason logged) after `iconTimeout`.
    @MainActor
    private static func waitForIcon(grants: FileGrantStore, log: (String) -> Void) async -> MenuBarItem? {
        let reader = AXMenuBarReader()
        let positions = GrantedPreferencesFile(file: .positions, grants: grants)
        let polls = Int((iconTimeout / iconPollInterval).rounded())
        var drawn: MenuBarItem?
        var keys: [String] = []
        var readError: Error?
        for poll in 0...polls {
            drawn = await reader.items().first { $0.bundleID == yeehawBundleID }
            do {
                let table = PositionTable(try positions.read(MenuBarController.positionsKey) as? [String: Double] ?? [:])
                readError = nil
                keys = table.values.keys.filter { $0.hasPrefix("status:\(yeehawBundleID)::") }.sorted()
                if let drawn,
                   let key = PositionKey.keys(bundleID: yeehawBundleID, names: drawn.keyNames,
                                              indexInApp: drawn.indexInApp, table: table).first,
                   table.values[key] != nil {
                    log("YeeHaw icon ready at x \(format(drawn.x)) width \(format(drawn.width)), key \(key)")
                    return drawn
                }
            } catch {
                readError = error
            }
            if poll < polls { try? await Task.sleep(for: .seconds(iconPollInterval)) }
        }
        if let readError {
            log("YeeHaw icon not ready: positions unreadable (\(readError)); nothing written")
        } else if let drawn {
            log("YeeHaw icon drawn (names \(listed(drawn.keyNames)), index \(drawn.indexInApp)) but its "
                + "position key is missing after \(format(iconTimeout)) s; YeeHaw keys: \(listed(keys)); nothing written")
        } else {
            log("YeeHaw icon not drawn after \(format(iconTimeout)) s; YeeHaw keys: \(listed(keys)); nothing written")
        }
        return nil
    }

    @MainActor
    private static func probe(grants: FileGrantStore) async -> [String] {
        var lines: [String] = []
        // The value of kAXTrustedCheckOptionPrompt, which Swift 6 can't read from a global var.
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            lines.append("accessibility: not trusted")
        }
        for item in await AXMenuBarReader().items() {
            let owner = item.bundleID ?? item.appleIdentifier ?? "unknown"
            lines.append("\(owner)|\(item.label) @\(format(item.x)) \(format(item.width))")
        }

        var needsGrant: [GrantedFile] = []
        let allowFile = GrantedPreferencesFile(file: .allowList, grants: grants)
        do {
            let value = try allowFile.read(MenuBarController.allowKey)
            if let data = value as? Data, let list = try? AllowList(data: data) {
                let off = Reconciler.userOwnedOff(DefaultsStateStore().load(), allow: list.snapshot)
                lines.append("userOwnedOff: \(listed(off.sorted()))")
            } else {
                lines.append("userOwnedOff: unreadable (malformed Allow list)")
            }
        } catch {
            needsGrant.append(.allowList)
            lines.append("userOwnedOff: unavailable")
        }
        do {
            _ = try GrantedPreferencesFile(file: .positions, grants: grants).read(MenuBarController.positionsKey)
        } catch {
            needsGrant.append(.positions)
        }
        lines.append("needsGrant: \(listed(needsGrant.map(\.rawValue)))")
        return lines
    }

    private static func emit(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        print(text, terminator: "")
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            print("could not write \(logURL.path): \(error)")
        }
    }

    private static func listed(_ values: [String]) -> String {
        "[" + values.joined(separator: ", ") + "]"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
