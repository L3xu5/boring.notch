import Foundation

@MainActor
public final class EventObservers<Event: Sendable> {
    private var callbacks: [UUID: @MainActor (Event) -> Void] = [:]
    public init() {}
    public func add(_ callback: @escaping @MainActor (Event) -> Void) -> UUID {
        let id = UUID(); callbacks[id] = callback; return id
    }
    public func remove(_ id: UUID) { callbacks[id] = nil }
    public func send(_ event: Event) {
        // Subscribers may remove themselves without mutating an active dictionary iteration.
        for callback in Array(callbacks.values) { callback(event) }
    }
}

public struct BatteryCharge: Sendable, Equatable {
    public let percent: Float
    public init?(currentCapacity: Double, maximumCapacity: Double) {
        guard currentCapacity.isFinite, maximumCapacity.isFinite, maximumCapacity > 0 else { return nil }
        percent = Float(min(100, max(0, currentCapacity / maximumCapacity * 100)))
    }
}
