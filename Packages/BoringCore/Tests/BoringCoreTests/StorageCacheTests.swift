import Testing
@testable import BoringCore

struct StorageCacheTests {
    @Test func boundedCacheEvictsLeastRecentlyUsedAndTracksReplacementCosts() {
        var cache = CostBoundedCache<String, String>(maximumCost: 5)
        cache.insert("one", forKey: "one", cost: 2)
        cache.insert("two", forKey: "two", cost: 2)
        let read = cache.value(forKey: "one")
        #expect(read == "one")
        cache.insert("three", forKey: "three", cost: 2)
        #expect(cache.keys.contains("one"))
        #expect(!cache.keys.contains("two"))
        #expect(cache.totalCost == 4)
        cache.insert("replaced", forKey: "one", cost: 1)
        #expect(cache.totalCost == 3)
        cache.insert("oversized", forKey: "large", cost: 6)
        #expect(cache.totalCost == 3)
        cache.removeAll()
        #expect(cache.totalCost == 0 && cache.keys.isEmpty)
    }
}
