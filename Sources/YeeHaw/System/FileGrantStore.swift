import AppKit
import os
import YeeHawCore

extension GrantedFile {
    /// The protected preference file (spec Techniques 2 and 3).
    var url: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch self {
        case .allowList:
            return home.appending(
                path: "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")
        case .positions:
            return home.appending(
                path: "Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")
        }
    }

    fileprivate var panelMessage: String {
        switch self {
        case .allowList:
            "YeeHaw needs to read and change which apps are allowed in the menu bar. Select this file and click Allow."
        case .positions:
            "YeeHaw needs to read and change the order of your menu bar icons. Select this file and click Allow."
        }
    }
}

/// Keeps one security-scoped bookmark per protected file, in `UserDefaults` under `grant.<file>`.
/// YeeHaw isn't sandboxed; the bookmark records the user's one-time pick in an open panel.
final class FileGrantStore: Sendable {
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "grants")

    private static func key(_ file: GrantedFile) -> String { "grant.\(file.rawValue)" }

    /// Resolves the bookmark and starts accessing it. The caller must call
    /// `stopAccessingSecurityScopedResource()` when done. Nil means there's no usable grant.
    /// A stale bookmark is re-created from the resolved URL.
    func url(for file: GrantedFile) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Self.key(file)) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource()
        else {
            Self.log.error("Grant for \(file.rawValue, privacy: .public) did not resolve")
            return nil
        }
        if isStale {
            do {
                try save(url, for: file)
            } catch {
                url.stopAccessingSecurityScopedResource()
                Self.log.error("Stale grant for \(file.rawValue, privacy: .public) could not be renewed: \(error, privacy: .public)")
                return nil
            }
        }
        return url
    }

    /// Whether the file has a grant that resolves (without keeping access open).
    func hasGrant(_ file: GrantedFile) -> Bool {
        guard let url = url(for: file) else { return false }
        url.stopAccessingSecurityScopedResource()
        return true
    }

    /// Asks the user to pick the file in an open panel pointed at it. Returns true only if they
    /// picked exactly that file and its bookmark was saved.
    @MainActor
    func requestGrant(for file: GrantedFile) async -> Bool {
        let expected = file.url
        let panel = NSOpenPanel()
        panel.message = file.panelMessage
        panel.prompt = "Allow"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // A file URL opens the panel at its folder with the file selected.
        panel.directoryURL = expected

        NSApp.activate()
        guard panel.runModal() == .OK, let picked = panel.url else { return false }
        guard Self.isSameFile(picked, expected) else {
            Self.log.notice("Grant for \(file.rawValue, privacy: .public) refused: another file was picked")
            return false
        }
        do {
            try save(picked, for: file)
            return true
        } catch {
            Self.log.error("Could not bookmark \(file.rawValue, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    private func save(_ url: URL, for file: GrantedFile) throws {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: Self.key(file))
    }

    private static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
