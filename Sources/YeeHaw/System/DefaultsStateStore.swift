import Foundation
import YeeHawCore

/// Persists `HidingState` as JSON in `UserDefaults` under `hidingState`.
struct DefaultsStateStore: StateStoring {
    static let key = "hidingState"

    /// `.empty` when nothing is saved or the saved JSON can't be decoded.
    func load() -> HidingState {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(HidingState.self, from: data)
        else { return .empty }
        return state
    }

    func save(_ s: HidingState) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
