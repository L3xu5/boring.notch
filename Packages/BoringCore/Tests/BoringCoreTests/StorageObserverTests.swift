import Testing
@testable import BoringCore

struct StorageObserverTests {
    @Test @MainActor func observerTokensRemainStableAfterOtherSubscribersLeave() {
        let observers = EventObservers<Int>()
        var first: [Int] = []
        var second: [Int] = []
        var third: [Int] = []
        let a = observers.add { first.append($0) }
        let b = observers.add { second.append($0) }
        let c = observers.add { third.append($0) }
        observers.remove(a)
        observers.remove(c)
        observers.send(7)
        #expect(first.isEmpty && second == [7] && third.isEmpty)
        observers.remove(b)
        observers.send(8)
        #expect(second == [7])
    }
    @Test func batteryCapacityIsNormalizedAndUnavailableReadingsStayUnavailable() {
        #expect(BatteryCharge(currentCapacity: 25, maximumCapacity: 50)?.percent == 50)
        #expect(BatteryCharge(currentCapacity: 200, maximumCapacity: 100)?.percent == 100)
        #expect(BatteryCharge(currentCapacity: 1, maximumCapacity: 0) == nil)
        #expect(BatteryCharge(currentCapacity: .nan, maximumCapacity: 100) == nil)
    }
}
