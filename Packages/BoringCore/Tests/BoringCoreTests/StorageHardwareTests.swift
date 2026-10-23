import Foundation
import Testing
@testable import BoringCore

private actor ScalarFixture: ScalarHardwareBackend {
    var value: Float = 0.5
    var writes: [Float] = []
    var firstReadStarted = false
    var readBarrier: CheckedContinuation<Void, Never>?
    var holdRead = true
    func read() async -> Float? {
        if holdRead { firstReadStarted = true; await withCheckedContinuation { readBarrier = $0 } }
        return value
    }
    func resumeRead() { holdRead = false; readBarrier?.resume(); readBarrier = nil }
    func write(_ value: Float) async -> Bool { self.value = value; writes.append(value); return true }
}
struct StorageHardwareTests {
    @Test func rapidRelativeAdjustmentsAccumulateAcrossSuspendedRead() async throws {
        let backend = ScalarFixture()
        let controller = ScalarHardwareController(backend: backend)
        await controller.submit(.relative(0.1))
        while !(await backend.firstReadStarted) { await Task.yield() }
        await controller.submit(.relative(0.1))
        await controller.submit(.relative(0.1))
        await backend.resumeRead()
        await controller.flush()
        #expect(abs(await backend.value - 0.8) < 0.0001)
        #expect(await backend.writes.count == 1)
        await controller.submit(.absolute(0.2))
        await controller.submit(.relative(0.1))
        await controller.flush()
        #expect(abs(await backend.value - 0.3) < 0.0001)
    }
    @Test func staleConnectionInvalidationCannotClearItsReplacement() {
        var epoch = ConnectionEpoch()
        let first = epoch.begin()
        let replacement = epoch.begin()
        let staleInvalidated = epoch.invalidate(first)
        #expect(!staleInvalidated)
        #expect(epoch.isCurrent(replacement))
        let replacementInvalidated = epoch.invalidate(replacement)
        #expect(replacementInvalidated)
        #expect(epoch.current == nil)
    }
}

struct HUDHardwarePolicyTests {
    @Test func unsupportedHardwareAndUnrelatedKeysPreserveNativeHandling() {
        let none = HUDKeyCapabilities(volume: false, screen: false, keyboard: false)
        #expect(HUDKeyPolicy.decide(code: 0, state: 0xA, isRepeat: false, option: false, shift: false, command: false,
            enabled: true, capabilities: none, optionAction: .ignore) == .passThrough)
        let all = HUDKeyCapabilities(volume: true, screen: true, keyboard: true)
        #expect(HUDKeyPolicy.decide(code: 16, state: 0xA, isRepeat: false, option: false, shift: false, command: false,
            enabled: true, capabilities: all, optionAction: .ignore) == .passThrough)
        #expect(HUDKeyPolicy.decide(code: 0, state: 0xA, isRepeat: false, option: true, shift: true, command: false,
            enabled: true, capabilities: all, optionAction: .ignore) == .consume(.adjustVolume(1 / 64)))
        #expect(HUDKeyPolicy.decide(code: 7, state: 0xA, isRepeat: true, option: false, shift: false, command: false,
            enabled: true, capabilities: all, optionAction: .ignore) == .consume(nil))
        #expect(HUDKeyPolicy.decide(code: 0, state: 0xB, isRepeat: false, option: false, shift: false, command: false,
            enabled: true, capabilities: all, optionAction: .ignore) == .consume(nil))
    }
}
