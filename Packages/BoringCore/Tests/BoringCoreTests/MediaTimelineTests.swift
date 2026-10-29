import Foundation
import Testing
@testable import BoringCore

@Suite struct MediaTimelineTests {
    private struct Player {
        let start = Date(timeIntervalSince1970: 1_000)
        var wire = MediaWireState()
        var state = MediaPlaybackState(bundleIdentifier: "fixture.player")

        init(playing: Bool = true, rate: Double = 1) {
            let update = MediaWireUpdate(payload: [
                "bundleIdentifier": .string("fixture.player"), "title": .string("Fixture"),
                "artist": .string("Artist"), "elapsedTime": .number(10),
                "duration": .number(180), "timestamp": .string("1970-01-01T00:16:40Z"),
                "playing": .boolean(playing), "playbackRate": .number(rate)
            ], diff: false)
            wire.apply(update)
            state = wire.playbackState(applying: update, previous: state, now: start)
        }

        mutating func apply(_ payload: [String: MediaWireValue], at seconds: Double) {
            let update = MediaWireUpdate(payload: payload)
            wire.apply(update)
            state = wire.playbackState(applying: update, previous: state,
                                       now: start.addingTimeInterval(seconds))
        }

        func position(at seconds: Double) -> Double {
            state.timeline.position(at: start.addingTimeInterval(seconds))
        }
    }

    @Test func playingOnlyPauseAndResumeDoNotReplayPausedTime() {
        var player = Player()
        player.apply(["playing": .boolean(false)], at: 5)
        #expect(player.state.currentTime == 15)
        #expect(player.state.lastUpdated == player.start.addingTimeInterval(5))
        #expect(player.position(at: 10) == 15)

        player.apply(["playing": .boolean(true)], at: 10)
        #expect(player.position(at: 10) == 15)
        #expect(player.position(at: 12) == 17)
    }

    @Test func playingAndRateOnlyPauseAndResumeShareOneAnchor() {
        var player = Player()
        player.apply(["playing": .boolean(false), "playbackRate": .number(0)], at: 5)
        #expect(player.position(at: 100) == 15)
        player.apply(["playing": .boolean(true), "playbackRate": .number(1)], at: 10)
        #expect(player.state.currentTime == 15)
        #expect(player.position(at: 12) == 17)
    }

    @Test func rateOnlyChangesIntegrateEachRateUntilItsChange() {
        var player = Player()
        player.apply(["playbackRate": .number(0)], at: 5)
        #expect(player.state.currentTime == 15)
        #expect(player.position(at: 10) == 15)
        player.apply(["playbackRate": .number(2)], at: 10)
        #expect(player.state.currentTime == 15)
        #expect(player.position(at: 13) == 21)
    }

    @Test func unchangedCachedPlayingValueDoesNotResetItsAnchor() {
        var player = Player()
        player.apply(["playing": .boolean(true), "playbackRate": .number(1)], at: 5)
        #expect(player.state.currentTime == 10)
        #expect(player.state.lastUpdated == player.start)
        #expect(player.position(at: 5) == 15)

        player.apply(["playing": .boolean(false)], at: 6)
        let paused = player.state
        player.apply(["playing": .boolean(false)], at: 20)
        #expect(player.state.currentTime == paused.currentTime)
        #expect(player.state.lastUpdated == paused.lastUpdated)
        #expect(player.position(at: 30) == 16)
    }

    @Test func metadataOnlyDiffPreservesTheTimelineAnchor() {
        var player = Player()
        player.apply(["volume": .number(0.25)], at: 5)
        #expect(player.state.lastUpdated == player.start)
        #expect(player.state.currentTime == 10)
        #expect(player.position(at: 5) == 15)
    }

    @Test func metadataOnlyDiffDoesNotReanchorASourceOverriddenPause() {
        var player = Player()
        // A source-specific reader can override stale transport fields retained by
        // MediaRemote. An unrelated patch must not pretend those fields just changed.
        player.state.currentTime = 15
        player.state.lastUpdated = player.start.addingTimeInterval(5)
        player.state.isPlaying = false
        player.state.playbackRate = 0
        player.apply(["volume": .number(0.25)], at: 20)
        #expect(player.state.currentTime == 15)
        #expect(player.state.lastUpdated == player.start.addingTimeInterval(5))
    }

    @Test func suppliedTimestampRemainsAuthoritativeOverReceiptTime() {
        var player = Player()
        player.apply(["playing": .boolean(false),
                      "timestamp": .string("1970-01-01T00:16:45Z")], at: 8)
        #expect(player.state.currentTime == 15)
        #expect(player.state.lastUpdated == player.start.addingTimeInterval(5))
        player.apply(["playing": .boolean(true),
                      "timestamp": .string("1970-01-01T00:16:50Z")], at: 14)
        #expect(player.state.currentTime == 15)
        #expect(player.state.lastUpdated == player.start.addingTimeInterval(10))
        #expect(player.position(at: 14) == 19)
    }

    @Test func positionOnlyPatchRetainsTheAdaptersElapsedTimestampContract() {
        var player = Player()
        player.apply(["elapsedTime": .number(20)], at: 5)
        // elapsedTime describes the adapter's retained timestamp, not receipt time.
        #expect(player.state.currentTime == 20)
        #expect(player.state.lastUpdated == player.start)
        #expect(player.position(at: 5) == 25)
    }

    @Test func explicitPositionWithTransportChangeIsNotIntegratedAgain() {
        var player = Player()
        player.apply(["elapsedTime": .number(20), "playing": .boolean(false),
                      "playbackRate": .number(0)], at: 5)
        #expect(player.state.currentTime == 20)
        #expect(player.state.lastUpdated == player.start)
        #expect(player.position(at: 20) == 20)
        player.apply(["playing": .boolean(true), "playbackRate": .number(1)], at: 10)
        #expect(player.position(at: 10) == 20)
        #expect(player.position(at: 12) == 22)
    }
}
