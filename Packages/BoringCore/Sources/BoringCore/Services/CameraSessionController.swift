import Foundation

public struct CameraSessionIntent: Sendable, Equatable {
    public let revision: UInt64
    public let shouldRun: Bool
    public init(revision: UInt64, shouldRun: Bool) { self.revision = revision; self.shouldRun = shouldRun }
}

/// A visible preview owns a consumer lease. Removing the final preview clears the user's
/// run request, so reopening the UI never turns the camera on implicitly.
public struct CameraUsageIntent: Sendable {
    public private(set) var revision: UInt64 = 0
    private var consumers = Set<UUID>()
    private var requested = false
    private var authorized = false
    private var available = false
    public init() {}
    public var snapshot: CameraSessionIntent {
        .init(revision: revision, shouldRun: requested && authorized && available && !consumers.isEmpty)
    }
    public mutating func acquireConsumer() -> UUID {
        let id = UUID(); consumers.insert(id); revision &+= 1; return id
    }
    public mutating func releaseConsumer(_ id: UUID) {
        guard consumers.remove(id) != nil else { return }
        if consumers.isEmpty { requested = false }
        revision &+= 1
    }
    public mutating func requestRunning(_ value: Bool) { requested = value; revision &+= 1 }
    public mutating func setAuthorized(_ value: Bool) {
        guard authorized != value else { return }
        authorized = value
        if !value { requested = false }
        revision &+= 1
    }
    public mutating func setAvailable(_ value: Bool) {
        guard available != value else { return }
        available = value
        if !value { requested = false }
        revision &+= 1
    }
}

public protocol CameraCaptureBackend: Sendable {
    func configure() async throws
    func start() async throws
    func stop() async
}

public enum CameraSessionPhase: Sendable, Equatable { case idle, preparing, running, failed(String) }
public struct CameraSessionEvent: Sendable {
    public let revision: UInt64
    public let phase: CameraSessionPhase
    public let sequence: UInt64
    public init(revision: UInt64, phase: CameraSessionPhase, sequence: UInt64) {
        self.revision = revision; self.phase = phase; self.sequence = sequence
    }
}

public struct CameraEventGate: Sendable {
    private var latestSequence: UInt64 = 0
    public init() {}
    public mutating func accept(_ event: CameraSessionEvent, currentRevision: UInt64) -> Bool {
        guard event.revision == currentRevision, event.sequence > latestSequence else { return false }
        latestSequence = event.sequence
        return true
    }
    public func isCurrent(_ event: CameraSessionEvent, currentRevision: UInt64) -> Bool {
        event.revision == currentRevision && event.sequence == latestSequence
    }
}

/// One reconciliation worker serializes backend operations. Intent updates can arrive while
/// setup is suspended; a stale setup is stopped before start is ever called.
public actor CameraSessionController {
    private let backend: any CameraCaptureBackend
    private let onState: @Sendable (CameraSessionEvent) -> Void
    private var intent = CameraSessionIntent(revision: 0, shouldRun: false)
    private var worker: Task<Void, Never>?
    private var configured = false
    private var running = false
    private var eventSequence: UInt64 = 0

    public init(backend: any CameraCaptureBackend, onState: @escaping @Sendable (CameraSessionEvent) -> Void = { _ in }) {
        self.backend = backend; self.onState = onState
    }
    public func update(_ intent: CameraSessionIntent) {
        guard intent.revision >= self.intent.revision else { return }
        self.intent = intent
        if worker == nil { worker = Task { await reconcile() } }
    }
    private func publish(_ phase: CameraSessionPhase) {
        eventSequence &+= 1
        onState(.init(revision: intent.revision, phase: phase, sequence: eventSequence))
    }
    private func reconcile() async {
        while true {
            let revision = intent.revision
            if intent.shouldRun {
                do {
                    if !configured {
                        publish(.preparing)
                        try await backend.configure()
                        configured = true
                        guard intent.revision == revision, intent.shouldRun else {
                            await backend.stop(); configured = false; running = false
                            continue
                        }
                    }
                    if !running { try await backend.start(); running = true }
                    if !intent.shouldRun {
                        await backend.stop(); configured = false; running = false
                        continue
                    }
                    publish(.running)
                } catch {
                    await backend.stop(); configured = false; running = false
                    if intent.revision != revision { continue }
                    publish(.failed(String(describing: error)))
                }
            } else {
                if configured || running { await backend.stop() }
                configured = false; running = false
                publish(.idle)
            }
            if intent.revision == revision { worker = nil; return }
        }
    }
}
