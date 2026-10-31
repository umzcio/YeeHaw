public typealias BundleID = String

public protocol StateStoring: Sendable {
    func load() -> HidingState
    func save(_ s: HidingState)
}
