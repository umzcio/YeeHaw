import Foundation
import os
import YeeHawCore

/// Calls `onChange` (debounced) when the Allow list may have changed on disk.
///
/// The group container folder is protected (opening it fails with EPERM), so the granted file
/// itself is watched, under its security scope. cfprefsd replaces the file atomically, so the
/// watch is re-armed on the new file after a delete, rename or attribute change. If the file
/// can't be opened, it polls instead (`onChange` callers diff, so a poll with no change is cheap)
/// and tries the file again every `fileRetryInterval`, going back to watching it once it opens.
@MainActor
final class AllowListWatcher {
    enum Mode: String { case file, poll }

    static let debounce: Duration = .milliseconds(300)
    static let pollInterval: Duration = .seconds(2)
    /// While polling, how often to try watching the file again.
    static let fileRetryInterval: Duration = .seconds(30)
    /// Re-opening the replaced file: a few tries, a moment apart, before falling back to polling.
    static let reopenAttempts = 5
    static let reopenDelay: Duration = .milliseconds(100)
    private static let log = Logger(subsystem: Log.subsystem, category: "watcher")

    private let grants: FileGrantStore
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    /// The security-scoped URL being accessed while the file is watched.
    private var scopedURL: URL?
    private var pending: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    private var rearming: Task<Void, Never>?

    init(grants: FileGrantStore, onChange: @escaping @MainActor () -> Void) {
        self.grants = grants
        self.onChange = onChange
        if armFileWatch() {
            Self.log.notice("Watching the Allow list file")
        } else {
            startPolling()
        }
    }

    isolated deinit {
        pending?.cancel()
        poller?.cancel()
        rearming?.cancel()
        disarm()
    }

    /// Which mode a watcher would use right now, without starting one (for `--probe`).
    static func probeMode(grants: FileGrantStore) -> Mode {
        guard let url = grants.url(for: .allowList) else { return .poll }
        defer { url.stopAccessingSecurityScopedResource() }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return .poll }
        close(descriptor)
        return .file
    }

    // MARK: File watch

    private func armFileWatch() -> Bool {
        disarm()
        guard let url = grants.url(for: .allowList) else {
            Self.log.error("Cannot watch the Allow list: no grant")
            return false
        }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("Cannot watch \(url.path, privacy: .public): errno \(errno)")
            url.stopAccessingSecurityScopedResource()
            return false
        }
        scopedURL = url
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename, .attrib, .revoke], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let events = source?.data ?? []
            MainActor.assumeIsolated { self?.handle(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    private func disarm() {
        source?.cancel()
        source = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        schedule()
        guard !events.isDisjoint(with: [.delete, .rename, .attrib, .revoke]) else { return }
        // The watched inode was replaced (or may have been); follow the file at its path.
        rearming?.cancel()
        rearming = Task { [weak self] in
            for _ in 0..<Self.reopenAttempts {
                guard let self, !Task.isCancelled else { return }
                if self.armFileWatch() {
                    self.schedule() // the new file may have changed between the event and the re-arm
                    return
                }
                try? await Task.sleep(for: Self.reopenDelay)
            }
            guard let self, !Task.isCancelled else { return }
            Self.log.error("Allow list file could not be re-opened; polling instead")
            self.startPolling()
        }
    }

    // MARK: Polling

    private func startPolling() {
        Self.log.notice("Polling the Allow list every \(Self.pollInterval, privacy: .public)")
        poller?.cancel()
        poller = Task { [weak self] in
            var sinceRetry: Duration = .zero
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                sinceRetry += Self.pollInterval
                if sinceRetry >= Self.fileRetryInterval {
                    sinceRetry = .zero
                    if self.armFileWatch() {
                        Self.log.notice("Watching the Allow list file again; polling stopped")
                        self.poller = nil
                        self.onChange() // anything missed between the last poll and the watch
                        return
                    }
                }
                self.onChange()
            }
        }
    }

    private func schedule() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
