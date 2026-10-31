import Foundation
import os
import YeeHawCore

/// Calls `onChange` (debounced) when the Allow list changes on disk. cfprefsd replaces the file
/// atomically, so the watch is on its folder rather than the file itself.
@MainActor
final class AllowListWatcher {
    static let debounce: Duration = .milliseconds(300)
    private static let log = Logger(subsystem: "com.zapps.yeehaw", category: "watcher")

    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let folder = GrantedFile.allowList.url.deletingLastPathComponent()
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.log.error("Cannot watch \(folder.path, privacy: .public): errno \(errno)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    isolated deinit {
        pending?.cancel()
        source?.cancel()
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
