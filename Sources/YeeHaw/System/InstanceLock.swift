import Foundation

/// Lets exactly one YeeHaw run per user, whichever build it is. The bundle ID check misses a copy
/// run with `swift run` or from `.build/debug`, which has no bundle ID, and two copies would each
/// save their own record of what they switched off over the other's. An exclusive `flock` on a
/// file in Application Support is held for the life of the process; macOS releases it when the
/// process ends, crash and force quit included, so a stale lock can't block the next launch.
final class InstanceLock: Sendable {
    enum Outcome {
        /// This process holds the lock; keep the value alive for as long as YeeHaw runs.
        case acquired(InstanceLock)
        /// Another process holds it: another YeeHaw is running.
        case heldElsewhere
        /// The lock file couldn't be opened or locked for another reason (the reason is in the
        /// text). YeeHaw still starts, relying on the bundle ID check, rather than refusing to
        /// run over a missing folder.
        case unavailable(String)

        var isHeldElsewhere: Bool {
            if case .heldElsewhere = self { return true }
            return false
        }
    }

    static let defaultURL = URL.applicationSupportDirectory.appending(path: "YeeHaw/instance.lock")

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Takes the lock at `url` without waiting, creating its folder and file if needed.
    static func acquire(at url: URL = defaultURL) -> Outcome {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            return .unavailable("\(error)")
        }
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable(String(cString: strerror(errno))) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .heldElsewhere : .unavailable(String(cString: strerror(code)))
        }
        return .acquired(InstanceLock(descriptor: descriptor))
    }
}
