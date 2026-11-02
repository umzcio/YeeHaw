import Foundation
import YeeHawCore

/// Finds YeeHaw's own drawn status item, ready to be a reveal neighbour: drawn, and with the
/// position key `beginReveal` will resolve for it present in the layout file. Shared by the app
/// and `--reveal`.
enum OwnIconLocator {
    static let bundleID = Log.subsystem
    /// How long `waitUntilReady` waits for the icon to be drawn and get a position key.
    static let timeout: Double = 5
    static let pollInterval: Double = 0.1

    /// YeeHaw's drawn item in `items` (any display's copy; they share one position key).
    static func drawn(in items: [MenuBarItem]) -> MenuBarItem? {
        items.first { $0.bundleID == bundleID }
    }

    /// YeeHaw's drawn item once its position key exists, or nil (with the reason logged) after
    /// `timeout`. Only reads; nothing is written.
    @MainActor
    static func waitUntilReady(grants: FileGrantStore, timeout: Double = timeout,
                               log: (String) -> Void) async -> MenuBarItem? {
        let reader = AXMenuBarReader()
        let positions = GrantedPreferencesFile(file: .positions, grants: grants)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var drawn: MenuBarItem?
        var keys: [String] = []
        var readError: Error?
        while true {
            drawn = Self.drawn(in: await reader.items())
            do {
                let table = PositionTable(try positions.read(MenuBarController.positionsKey) as? [String: Double] ?? [:])
                readError = nil
                let prefixes = drawn?.keyPrefixes ?? [bundleID]
                keys = PositionKey.existingKeys(prefixes: prefixes, table: table)
                if let drawn, let key = PositionKey.keys(for: drawn, table: table).first, table.values[key] != nil {
                    log("YeeHaw icon ready at x \(format(drawn.x)) width \(format(drawn.width)), key \(key)")
                    return drawn
                }
            } catch {
                readError = error
            }
            guard ContinuousClock.now < deadline else { break }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        if let readError {
            log("YeeHaw icon not ready: positions unreadable (\(readError)); nothing written")
        } else if let drawn {
            log("YeeHaw icon drawn (prefixes \(listed(drawn.keyPrefixes)), names \(listed(drawn.keyNames)), "
                + "index \(drawn.indexInApp)) but its "
                + "position key is missing after \(format(timeout)) s; YeeHaw keys: \(listed(keys)); nothing written")
        } else {
            log("YeeHaw icon not drawn after \(format(timeout)) s; YeeHaw keys: \(listed(keys)); nothing written")
        }
        return nil
    }

    static func listed(_ values: [String]) -> String {
        "[" + values.joined(separator: ", ") + "]"
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}
