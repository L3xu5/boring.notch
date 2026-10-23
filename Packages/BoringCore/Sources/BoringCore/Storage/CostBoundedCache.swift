/// A deterministic LRU cache with explicit memory costs. Oversized entries do not evict the
/// entire working set, and replacement/removal account for their previous cost.
public struct CostBoundedCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private struct Entry: Sendable { var value: Value; var cost: Int; var age: UInt64 }
    private var entries: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    public let maximumCost: Int
    public private(set) var totalCost = 0
    public var keys: [Key] { Array(entries.keys) }
    public init(maximumCost: Int) { self.maximumCost = max(0, maximumCost) }
    public mutating func value(forKey key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1; entry.age = clock; entries[key] = entry
        return entry.value
    }
    public mutating func insert(_ value: Value, forKey key: Key, cost: Int) {
        removeValue(forKey: key)
        guard cost >= 0, cost <= maximumCost else { return }
        clock &+= 1
        entries[key] = Entry(value: value, cost: cost, age: clock)
        totalCost += cost
        while totalCost > maximumCost, let oldest = entries.min(by: { $0.value.age < $1.value.age })?.key {
            removeValue(forKey: oldest)
        }
    }
    public mutating func removeValue(forKey key: Key) {
        if let old = entries.removeValue(forKey: key) { totalCost -= old.cost }
    }
    public mutating func removeAll() { entries.removeAll(); totalCost = 0 }
}
