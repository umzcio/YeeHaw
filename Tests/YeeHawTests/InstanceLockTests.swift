import Foundation
import Testing
@testable import YeeHaw

@Suite struct InstanceLockTests {
    /// A folder that doesn't exist yet, so `acquire` has to create it.
    private static func lockURL() -> (folder: URL, file: URL) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "InstanceLockTests-\(UUID().uuidString)")
        return (folder, folder.appending(path: "instance.lock"))
    }

    @Test func aSecondCopyFindsTheLockHeld() {
        let (folder, url) = Self.lockURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        guard case .acquired(let first) = InstanceLock.acquire(at: url) else {
            Issue.record("first copy didn't get the lock")
            return
        }
        #expect(InstanceLock.acquire(at: url).isHeldElsewhere)
        withExtendedLifetime(first) {}
    }

    @Test func theLockIsFreeAgainOnceReleased() {
        let (folder, url) = Self.lockURL()
        defer { try? FileManager.default.removeItem(at: folder) }
        var first: InstanceLock?
        if case .acquired(let held) = InstanceLock.acquire(at: url) {
            first = held
        } else {
            Issue.record("first copy didn't get the lock")
            return
        }
        first = nil
        guard case .acquired = InstanceLock.acquire(at: url) else {
            Issue.record("the lock wasn't free after the first copy let go")
            return
        }
        _ = first
    }

    @Test func anUncreatableFolderIsUnavailableNotHeld() {
        let outcome = InstanceLock.acquire(at: URL(filePath: "/dev/null/YeeHaw/instance.lock"))
        guard case .unavailable = outcome else {
            Issue.record("expected unavailable")
            return
        }
        #expect(!outcome.isHeldElsewhere)
    }
}
