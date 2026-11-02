import Foundation
import os
import YeeHawCore

/// Persists `HidingState` as JSON in `UserDefaults` under `hidingState`.
struct DefaultsStateStore: StateStoring {
    static let key = "hidingState"
    /// Where a saved state that can't be read is kept, so the next save doesn't lose it for good.
    static let unreadableKey = "hidingStateUnreadable"
    private static let log = Logger(subsystem: Log.subsystem, category: "state")

    /// `.empty` when nothing is saved. A saved state that can't be decoded is copied to
    /// `unreadableKey` and reported as a fault before `.empty` is returned: the journal in it
    /// may name apps YeeHaw switched off, which then need switching on by hand.
    func load() -> HidingState {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else { return .empty }
        do {
            return try JSONDecoder().decode(HidingState.self, from: data)
        } catch {
            UserDefaults.standard.set(data, forKey: Self.unreadableKey)
            Self.log.fault("Saved state unreadable (\(error, privacy: .public)); kept under \(Self.unreadableKey, privacy: .public)")
            return .empty
        }
    }

    func save(_ s: HidingState) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
