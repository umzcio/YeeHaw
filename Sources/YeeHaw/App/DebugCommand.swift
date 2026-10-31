import ApplicationServices
import Foundation
import YeeHawCore

/// Hands-on checks run from the command line. They only read (apart from saving a grant the user
/// picks) and never start the controller. Output goes to stdout and to
/// `~/Library/Logs/YeeHaw/probe.txt`, since an app launched with `open` has no visible stdout.
enum DebugCommand {
    /// `--probe`: what's drawn and who owns it, the user-owned-off apps, and missing grants.
    case probe
    /// `--grant`: asks for both file grants in turn.
    case grant

    static let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Library/Logs/YeeHaw/probe.txt")

    init?(arguments: [String]) {
        if arguments.contains("--probe") {
            self = .probe
        } else if arguments.contains("--grant") {
            self = .grant
        } else {
            return nil
        }
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
        }
        Self.emit(lines)
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
