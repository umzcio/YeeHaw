/// Model of `TrailingItemPreferredPositions`: a larger value sits further left, `module:Clock` is 0.
public struct PositionTable: Equatable, Sendable {
    public var values: [String: Double]

    public init(_ values: [String: Double]) {
        self.values = values
    }

    public static let minimumGap: Double = 1.0

    /// Changed entries only, for icons placed side by side between two neighbours. Each group is
    /// one icon's keys (its aliases), which share a value; groups get distinct values, the first
    /// furthest left. `leftNeighbor` nil = the far left; `rightNeighbor` nil = immediately left of
    /// the clock. The clock counts as 0 even when the table has no key for it.
    ///
    /// The values go in the widest free stretch between the neighbours, so none lands on a key
    /// that's already there (often a hidden app's). With no room, the groups take the values just
    /// left of the right neighbour and every key in the way moves left, keeping its order. Throws
    /// `.unresolvedNeighbor` when the left neighbour isn't left of the right one: the table and the
    /// caller disagree, so any value would be a guess.
    public func placement(ofGroups groups: [[String]], leftNeighbor: String?,
                          rightNeighbor: String?) throws -> [String: Double] {
        let groups = groups.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return [:] }
        let moved = Set(groups.joined())
        let others = values.filter { !moved.contains($0.key) }
        func value(of key: String) -> Double? { others[key] ?? (key == PositionKey.clock ? 0 : nil) }

        let leftValue = leftNeighbor.flatMap(value(of:))
        let upper = leftValue ?? ((others.values.max() ?? 0) + 20)
        let lower = rightNeighbor.flatMap(value(of:)) ?? 0
        if leftValue != nil, upper <= lower { throw ControllerError.unresolvedNeighbor }
        let count = Double(groups.count)

        // The widest stretch between neighbouring values; on a tie, the one nearest the left neighbour.
        let edges = [lower] + Set(others.values.filter { $0 > lower && $0 < upper }).sorted() + [upper]
        var gap = (low: lower, high: lower)
        for (low, high) in zip(edges, edges.dropFirst()) where high - low >= gap.high - gap.low {
            gap = (low, high)
        }

        var result: [String: Double] = [:]
        if gap.high - gap.low >= (count + 1) * Self.minimumGap {
            let step = (gap.high - gap.low) / (count + 1)
            for (index, group) in groups.enumerated() {
                for key in group { result[key] = gap.high - step * Double(index + 1) }
            }
            return result
        }

        for (index, group) in groups.enumerated() {
            for key in group { result[key] = lower + Self.minimumGap * (count - Double(index)) }
        }
        // Entries tied at one original value (aliases of one icon) move as a group.
        let inTheWay = Dictionary(grouping: others.filter { $0.value > lower }, by: { $0.value })
        var previous = lower + Self.minimumGap * count
        for value in inTheWay.keys.sorted() {
            let needed = previous + Self.minimumGap
            guard value < needed else { break }
            for entry in inTheWay[value]! { result[entry.key] = needed }
            previous = needed
        }
        return result
    }

    /// `placement(ofGroups:)` for one icon: all of `keys` name it, so they share one value.
    public func placement(of keys: [String], leftNeighbor: String?, rightNeighbor: String?) throws -> [String: Double] {
        try placement(ofGroups: [keys], leftNeighbor: leftNeighbor, rightNeighbor: rightNeighbor)
    }

    /// `keys` split into one group per icon, furthest left first: keys with the same value are
    /// aliases of one icon. Keys the table doesn't have form a last group.
    public func groupedByValue(_ keys: [String]) -> [[String]] {
        let unique = Array(Set(keys)).sorted()
        let byValue = Dictionary(grouping: unique.filter { values[$0] != nil }, by: { values[$0]! })
        var groups = byValue.keys.sorted(by: >).map { byValue[$0]! }
        let missing = unique.filter { values[$0] == nil }
        if !missing.isEmpty { groups.append(missing) }
        return groups
    }

    /// A value immediately left of `key`: midpoint to the next larger value, or value(key) + 20 if none.
    /// An absent key counts as 0.
    public func slotValue(leftOf key: String) -> Double {
        let current = values[key] ?? 0
        guard let next = values.values.filter({ $0 > current }).min() else { return current + 20 }
        return (current + next) / 2
    }
}
