import Foundation
import Testing
@testable import BoringCore

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite("Notification lifetime")
struct NotificationObservationTests {
    @Test func cancelStopsDeliveryAndCanBeRepeated() {
        let center = NotificationCenter(), counter = ObservationCounter()
        let name = Notification.Name("fixture.event")
        let observation = NotificationObservation(center: center, name: name) { _ in counter.increment() }
        center.post(name: name, object: nil)
        #expect(counter.value == 1)
        observation.cancel()
        observation.cancel()
        center.post(name: name, object: nil)
        #expect(counter.value == 1)
    }

    @Test func releasingRegistrationStopsDelivery() {
        let center = NotificationCenter(), counter = ObservationCounter()
        let name = Notification.Name("fixture.event")
        var observation: NotificationObservation? = NotificationObservation(center: center, name: name) { _ in counter.increment() }
        #expect(observation != nil)
        observation = nil
        center.post(name: name, object: nil)
        #expect(counter.value == 0)
    }
}
