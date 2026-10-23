import Foundation
import Testing
@testable import BoringCore

private actor CameraFixture: CameraCaptureBackend {
    var configurationStarted = false
    var starts = 0
    var stops = 0
    var barrier: CheckedContinuation<Void, Never>?
    var suspended = true
    func configure() async throws {
        configurationStarted = true
        if suspended { await withCheckedContinuation { barrier = $0 } }
    }
    func finishConfiguration() { suspended = false; barrier?.resume(); barrier = nil }
    func start() async throws { starts += 1 }
    func stop() async { stops += 1 }
}
private actor CameraEvents {
    var events: [CameraSessionEvent] = []
    func append(_ event: CameraSessionEvent) { events.append(event) }
}
private func cameraEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw NSError(domain: "CameraTests", code: 1)
}
struct CameraTests {
    @Test func stopDuringSetupPreventsLaterStart() async throws {
        let backend = CameraFixture()
        let controller = CameraSessionController(backend: backend)
        await controller.update(.init(revision: 1, shouldRun: true))
        try await cameraEventually { await backend.configurationStarted }
        await controller.update(.init(revision: 2, shouldRun: false))
        await backend.finishConfiguration()
        try await cameraEventually { await backend.stops > 0 }
        #expect(await backend.starts == 0)
    }
    @Test func staleQueuedIntentCannotRestartCamera() async throws {
        let backend = CameraFixture()
        await backend.finishConfiguration()
        let controller = CameraSessionController(backend: backend)
        await controller.update(.init(revision: 3, shouldRun: false))
        await controller.update(.init(revision: 2, shouldRun: true))
        try await Task.sleep(for: .milliseconds(10))
        #expect(await backend.starts == 0)
    }
    @Test func consumersHaveIndependentLifetimesAndReopenRequiresAnotherTap() {
        var usage = CameraUsageIntent()
        usage.setAvailable(true); usage.setAuthorized(true)
        let first = usage.acquireConsumer(); let second = usage.acquireConsumer()
        usage.requestRunning(true)
        #expect(usage.snapshot.shouldRun)
        usage.releaseConsumer(first)
        #expect(usage.snapshot.shouldRun)
        usage.releaseConsumer(second)
        #expect(!usage.snapshot.shouldRun)
        _ = usage.acquireConsumer()
        #expect(!usage.snapshot.shouldRun)
        usage.requestRunning(true)
        usage.setAuthorized(false)
        #expect(!usage.snapshot.shouldRun)
    }
}

struct CameraDeliveryTests {
    @Test func latePreparationCannotHideAnAlreadyRunningCamera() {
        var gate = CameraEventGate()
        let running = CameraSessionEvent(revision: 1, phase: .running, sequence: 2)
        let preparation = CameraSessionEvent(revision: 1, phase: .preparing, sequence: 1)
        let acceptedRunning = gate.accept(running, currentRevision: 1)
        let acceptedStale = gate.accept(preparation, currentRevision: 1)
        #expect(acceptedRunning)
        #expect(!acceptedStale)
        #expect(gate.isCurrent(running, currentRevision: 1))
        #expect(!gate.isCurrent(running, currentRevision: 2))
    }
    @Test func revocationAndDeviceRemovalRequireAnotherExplicitStart() {
        var usage = CameraUsageIntent()
        _ = usage.acquireConsumer()
        usage.setAuthorized(true); usage.setAvailable(true); usage.requestRunning(true)
        usage.setAuthorized(false); usage.setAuthorized(true)
        #expect(!usage.snapshot.shouldRun)
        usage.requestRunning(true)
        usage.setAvailable(false); usage.setAvailable(true)
        #expect(!usage.snapshot.shouldRun)
    }
}
