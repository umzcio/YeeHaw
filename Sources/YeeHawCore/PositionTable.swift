/// Model of `TrailingItemPreferredPositions`: a larger value sits further left, `module:Clock` is 0.
public struct PositionTable: Equatable, Sendable {
    public var values: [String: Double]

    public init(_ values: [String: Double]) {
        self.values = values
    }

    public static let minimumGap: Double = 1.0

    /// Changed entries only. `leftNeighbor` has the larger value; nil = moving to the far left.
    /// `rightNeighbor` nil = immediately left of module:Clock (value 0).
    /// The moved keys are excluded from every lookup and all receive the same value.
    public func placement(of keys: [String], leftNeighbor: String?, rightNeighbor: String?) -> [String: Double] {
        let moved = Set(keys)
        let others = values.filter { !moved.contains($0.key) }

        let leftValue = leftNeighbor.flatMap { others[$0] }
        let upper = leftValue ?? ((others.values.max() ?? 0) + 20)
        let lower = rightNeighbor.flatMap { others[$0] } ?? 0

        if upper - lower >= 2 * Self.minimumGap {
            let v = (upper + lower) / 2
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, v) })
        }

        let v = lower + Self.minimumGap
        var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, v) })
        guard let leftValue else { return result }

        var previous = v
        let walk = others
            .filter { $0.value >= leftValue }
            .sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        for (key, value) in walk {
            let needed = previous + Self.minimumGap
            guard value < needed else { break }
            result[key] = needed
            previous = needed
        }
        return result
    }

    /// A value immediately left of `key`: midpoint to the next larger value, or value(key) + 20 if none.
    /// An absent key counts as 0.
    public func slotValue(leftOf key: String) -> Double {
        let current = values[key] ?? 0
        guard let next = values.values.filter({ $0 > current }).min() else { return current + 20 }
        return (current + next) / 2
    }
}
