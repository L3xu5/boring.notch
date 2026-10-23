import Foundation

@main
struct MediaKeyRecoveryTests {
    static let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    static let safari = "com.apple.Safari"
    static let yandex = "ru.yandex.desktop.music"
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func snapshot(at date: Date = now) -> MediaKeyRecoverySnapshot {
        MediaKeyRecoverySnapshot(
            systemOwner: safari, systemIsPlaying: false,
            foreignActivity: now.addingTimeInterval(-30), yandexIsPlaying: true,
            accessibilityObservedAt: date.addingTimeInterval(-0.2),
            foregroundApp: "com.apple.TextEdit", capturedAt: date
        )
    }

    static func candidate(_ snapshot: MediaKeyRecoverySnapshot, proof: Bool = false) -> Bool {
        MediaKeyRecoveryPolicy.isCandidate(snapshot, at: snapshot.capturedAt, recentlyRecoveredYandex: proof)
    }

    static func main() {
        let before = snapshot()
        let response = now.addingTimeInterval(1.2)
        let after = snapshot(at: response)
        require(candidate(before), "old paused foreign owner with fresh playing Yandex is a candidate")
        require(MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: response), "unchanged stale native session with a new AX read can recover")

        for state: Bool? in [true, nil] {
            var value = before
            value.systemIsPlaying = state
            require(!candidate(value), "playing or unknown foreign session retains native control")
        }
        for owner: String? in [nil, "", "   ", yandex] {
            var value = before
            value.systemOwner = owner
            require(!candidate(value), "unknown or already-correct owner cannot recover")
        }
        var value = before
        value.foregroundApp = safari
        require(!candidate(value), "focused foreign owner always retains native control")
        value = before
        value.foreignActivity = nil
        require(!candidate(value), "unknown foreign activity is insufficient proof")
        value.foreignActivity = now.addingTimeInterval(-9.9)
        require(!candidate(value), "recent foreign activity prevents recovery")
        value.foreignActivity = now.addingTimeInterval(-10)
        require(candidate(value), "ten seconds of foreign inactivity meets the threshold")
        value.foreignActivity = now.addingTimeInterval(1)
        require(!candidate(value), "future foreign activity cannot count as old")

        value = before
        value.yandexIsPlaying = nil
        require(!candidate(value), "unknown Yandex AX state prevents recovery")
        value = before
        value.yandexIsPlaying = false
        require(!candidate(value), "paused background Yandex alone is insufficient proof")
        value.foregroundApp = yandex
        require(candidate(value), "foreground Yandex can resume from a known paused state")
        value.foregroundApp = "com.apple.TextEdit"
        require(candidate(value, proof: true), "a validated recent recovery can retain a paused Yandex target")
        value.foregroundApp = safari
        require(!candidate(value, proof: true), "recent proof cannot override a focused foreign owner")

        for observed: Date? in [nil, now.addingTimeInterval(-2.51), now.addingTimeInterval(0.1)] {
            value = before
            value.accessibilityObservedAt = observed
            require(!candidate(value), "missing, stale or future AX evidence cannot recover")
        }
        value = before
        value.accessibilityObservedAt = now.addingTimeInterval(-2.5)
        require(candidate(value), "AX evidence exactly at the freshness boundary is accepted")

        for nativePlaying in [true, false] {
            var first = before
            var last = after
            first.systemIsPlaying = nativePlaying
            last.systemIsPlaying = !nativePlaying
            require(!MediaKeyRecoveryPolicy.shouldRecover(before: first, after: last, at: response), "a native play/pause response must never trigger recovery")
        }
        var changed = after
        changed.systemOwner = "com.spotify.client"
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "ownership changes prove native handling responded")
        changed = after
        changed.foreignActivity = response
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "new foreign activity prevents recovery")
        changed.foreignActivity = now.addingTimeInterval(-20)
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "even still-old changed foreign activity prevents recovery")
        changed = after
        changed.yandexIsPlaying = false
        changed.foregroundApp = yandex
        var foregroundBefore = before
        foregroundBefore.foregroundApp = yandex
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: foregroundBefore, after: changed, at: response), "a native change to Yandex playback prevents a second toggle")

        for foreground: String? in [safari, yandex, "com.spotify.client", nil] {
            changed = after
            changed.foregroundApp = foreground
            require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "focus changes during native response cancel recovery")
        }
        changed = after
        changed.accessibilityObservedAt = before.accessibilityObservedAt
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "the same cached AX observation cannot prove no native response")
        changed.accessibilityObservedAt = now.addingTimeInterval(-1)
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "an older AX observation cannot prove no native response")
        changed.accessibilityObservedAt = now.addingTimeInterval(-0.1)
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "a newer AX read from before the key cannot prove native handling had no effect")
        changed = after
        changed.accessibilityObservedAt = response.addingTimeInterval(-2.6)
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: changed, at: response), "after AX state must still be fresh")

        var olderInitial = before
        olderInitial.accessibilityObservedAt = now.addingTimeInterval(-2.4)
        require(MediaKeyRecoveryPolicy.shouldRecover(before: olderInitial, after: after, at: response), "before freshness is evaluated at its original capture time")
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: after, after: before, at: response), "out-of-order captures cannot recover")
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: before, at: response), "a second capture is required")
        let late = snapshot(at: now.addingTimeInterval(5.01))
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: late, at: late.capturedAt), "native response must be checked within five seconds")
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: now), "future after captures cannot recover")

        var pausedBefore = before
        var pausedAfter = after
        pausedBefore.yandexIsPlaying = false
        pausedAfter.yandexIsPlaying = false
        pausedBefore.foregroundApp = yandex
        pausedAfter.foregroundApp = yandex
        require(MediaKeyRecoveryPolicy.shouldRecover(before: pausedBefore, after: pausedAfter, at: response), "known paused Yandex can recover while continuously focused")
        pausedBefore.foregroundApp = "com.apple.TextEdit"
        pausedAfter.foregroundApp = "com.apple.TextEdit"
        require(!MediaKeyRecoveryPolicy.shouldRecover(before: pausedBefore, after: pausedAfter, at: response), "paused background Yandex needs validated recent proof")
        require(MediaKeyRecoveryPolicy.shouldRecover(before: pausedBefore, after: pausedAfter, at: response, recentlyRecoveredYandex: true), "validated recent proof allows the next paused-Yandex media key")
        print("Media-key recovery policy: \(checks) checks passed")
    }
}
