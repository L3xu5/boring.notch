import Foundation

public protocol ScalarHardwareBackend: Sendable {
    func read() async -> Float?
    func write(_ value: Float) async -> Bool
}
public enum ScalarAdjustment: Sendable { case relative(Float), absolute(Float), refresh }
public struct ScalarHardwareUpdate: Sendable {
    public let value: Float?
    public let changedByUser: Bool
}

/// Actor isolation alone does not serialize a read/await/write transaction. One worker owns
/// the whole transaction, drains queued adjustments after reading, and accumulates every key.
public actor ScalarHardwareController {
    private let backend: any ScalarHardwareBackend
    private let onUpdate: @Sendable (ScalarHardwareUpdate) -> Void
    private var pending: [ScalarAdjustment] = []
    private var worker: Task<Void, Never>?
    private var lastKnown: Float?
    public init(backend: any ScalarHardwareBackend,
                onUpdate: @escaping @Sendable (ScalarHardwareUpdate) -> Void = { _ in }) {
        self.backend = backend; self.onUpdate = onUpdate
    }
    public func submit(_ command: ScalarAdjustment) {
        switch command {
        case .absolute(let value), .relative(let value): guard value.isFinite else { return }
        case .refresh: break
        }
        pending.append(command)
        if worker == nil { worker = Task { await drain() } }
    }
    public func flush() async { await worker?.value }
    private func drain() async {
        while !pending.isEmpty {
            let reading = await backend.read().flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            if let reading { lastKnown = reading }
            let commands = pending
            pending.removeAll()
            let userChange = commands.contains { if case .refresh = $0 { false } else { true } }
            guard userChange else { onUpdate(.init(value: reading, changedByUser: false)); continue }
            let hasAbsolute = commands.contains { if case .absolute = $0 { true } else { false } }
            guard lastKnown != nil || hasAbsolute else { onUpdate(.init(value: nil, changedByUser: false)); continue }
            var target = lastKnown ?? 0
            for command in commands {
                switch command {
                case .relative(let delta): target = min(1, max(0, target + delta))
                case .absolute(let value): target = min(1, max(0, value))
                case .refresh: break
                }
            }
            if await backend.write(target) {
                lastKnown = target
                onUpdate(.init(value: target, changedByUser: true))
            } else { onUpdate(.init(value: nil, changedByUser: false)) }
        }
        worker = nil
    }
}

public struct ConnectionEpoch: Sendable {
    public private(set) var current: UUID?
    public init() {}
    public mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    public func isCurrent(_ id: UUID) -> Bool { current == id }
    @discardableResult public mutating func invalidate(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }; current = nil; return true
    }
}
