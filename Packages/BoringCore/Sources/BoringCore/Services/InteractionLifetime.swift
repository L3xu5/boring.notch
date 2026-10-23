/// Explicit user interaction lifetime. No elapsed time can stand in for a sharing provider's
/// completion: an editor or transfer may legitimately remain open for many minutes.
public struct InteractionLifetime: Sendable, Equatable {
    public enum Phase: Sendable { case idle, picker, service, finished }
    public private(set) var phase: Phase = .idle
    public init() {}
    @discardableResult public mutating func beginPicker() -> Bool {
        guard phase != .finished else { return false }
        let shouldBegin = phase == .idle
        if phase != .service { phase = .picker }
        return shouldBegin
    }
    @discardableResult public mutating func beginService() -> Bool {
        guard phase != .finished else { return false }
        let shouldBegin = phase == .idle
        phase = .service
        return shouldBegin
    }
    /// nil means already finished; the Bool indicates whether a matching begin must be ended.
    public mutating func finish() -> Bool? {
        guard phase != .finished else { return nil }
        let wasActive = phase != .idle
        phase = .finished
        return wasActive
    }
}
