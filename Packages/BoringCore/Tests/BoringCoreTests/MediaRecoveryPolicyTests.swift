import Foundation
import Testing
@testable import BoringCore

@Suite struct MediaRecoveryPolicyTests {
    @Test func nativeFirstRequiresFreshUnchangedEvidence() {
        let now = Date(timeIntervalSince1970: 1000)
        let before = MediaKeyRecoverySnapshot(systemOwner: "com.apple.Safari", systemIsPlaying: false,
            foreignActivity: now.addingTimeInterval(-30), yandexIsPlaying: true,
            accessibilityObservedAt: now.addingTimeInterval(-0.2), foregroundApp: "editor", capturedAt: now)
        var after = before
        after.capturedAt = now.addingTimeInterval(1.2)
        after.accessibilityObservedAt = after.capturedAt
        #expect(MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: after.capturedAt))
        after.systemIsPlaying = true
        #expect(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: after.capturedAt))
        after.systemIsPlaying = false; after.foregroundApp = "com.apple.Safari"
        #expect(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: after.capturedAt))
        after.foregroundApp = "editor"; after.accessibilityObservedAt = before.accessibilityObservedAt
        #expect(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: after.capturedAt))
    }
}
