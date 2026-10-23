import Testing
@testable import BoringCore

struct StorageInteractionTests {
    @Test func pickerToServiceCountsOnceAndStaysActiveUntilActualCompletion() {
        var lifetime = InteractionLifetime()
        let beganPicker = lifetime.beginPicker()
        let beganService = lifetime.beginService()
        let beganAgain = lifetime.beginService()
        #expect(beganPicker)
        #expect(!beganService)
        #expect(!beganAgain)
        #expect(lifetime.phase == .service)
        #expect(lifetime.finish() == true)
        #expect(lifetime.finish() == nil)
        let restarted = lifetime.beginService()
        #expect(!restarted)
    }
    @Test func cancellationBeforePresentationDoesNotInventAnInteraction() {
        var lifetime = InteractionLifetime()
        #expect(lifetime.finish() == false)
        #expect(lifetime.finish() == nil)
    }
}
