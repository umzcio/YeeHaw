import AppKit
import Security
import Synchronization
import YeeHawCore

/// Whether a running copy of an app is notarized, which decides how the Allow list names it
/// (`RunningCopy.location`) and which key prefix its items get (`PositionKey.prefixes`). Checked
/// in-process against the `notarized` requirement; team signing alone doesn't pass it. Measured
/// on 27.2: /Applications' DigUp, Fiddle and zWhisper pass; a Developer ID debug build of Fiddle
/// and an ad hoc zWhisper build don't.
enum Notarization {
    /// Answers per process and path, since bar reads ask for every running app many times a second.
    private static let cache = Mutex<[CacheKey: Bool]>([:])

    private struct CacheKey: Hashable {
        let pid: pid_t
        let path: String
    }

    /// The app's running copies, each with its notarization.
    static func runningCopies(of id: BundleID) -> [RunningCopy] {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap { app in
            guard !app.isTerminated, let executable = app.executableURL else { return nil }
            return RunningCopy(bundleID: id, executableURL: executable, notarized: isNotarized(app))
        }
    }

    /// The bundle's signature (or the executable's, for a process outside a bundle).
    static func isNotarized(_ app: NSRunningApplication) -> Bool {
        let url = app.bundleURL.flatMap { $0.pathExtension == "app" ? $0 : nil } ?? app.executableURL
        guard let url else { return false }
        let key = CacheKey(pid: app.processIdentifier, path: url.path)
        if let known = cache.withLock({ $0[key] }) { return known }
        let notarized = isNotarized(at: url)
        cache.withLock { $0[key] = notarized }
        return notarized
    }

    /// Checks the code directory and the requirement only, not every file's hash: a few
    /// milliseconds rather than a hundred for a large app.
    static func isNotarized(at url: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("notarized" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
