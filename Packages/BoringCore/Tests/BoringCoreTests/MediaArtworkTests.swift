import Foundation
import Testing
@testable import BoringCore

@Suite struct MediaArtworkTests {
    private static let artA = Data("cover A".utf8)
    private static let artB = Data("cover B".utf8)
    private static let first: [String: MediaWireValue] = [
        "bundleIdentifier": .string("fixture.player"), "title": .string("Track A"),
        "artist": .string("Fixture artist"), "album": .string("Fixture album"),
        "artworkData": .string(artA.base64EncodedString()),
    ]

    private struct Sequence {
        private var wire = MediaWireState()
        var state = MediaPlaybackState(bundleIdentifier: "fixture.player")

        mutating func apply(_ payload: [String: MediaWireValue], diff: Bool = true) -> MediaPlaybackState {
            let update = MediaWireUpdate(payload: payload, diff: diff)
            wire.apply(update)
            state = wire.playbackState(applying: update, previous: state, now: Date(timeIntervalSince1970: 100))
            return state
        }
    }

    @Test func titleBeforeArtworkDoesNotBorrowOrResurrectThePreviousCover() {
        var sequence = Sequence()
        let first = sequence.apply(Self.first, diff: false)
        #expect(first.artwork == Self.artA)
        let nextTitle = sequence.apply(["title": .string("Track B")])
        #expect(nextTitle.title == "Track B" && nextTitle.artwork == nil)
        let heartbeat = sequence.apply(["elapsedTime": .number(1)])
        #expect(heartbeat.title == "Track B" && heartbeat.artwork == nil)
        let freshCover = sequence.apply(["artworkData": .string(Self.artB.base64EncodedString())])
        #expect(freshCover.title == "Track B" && freshCover.artwork == Self.artB)
    }

    @Test func missingPresentationArtworkCannotBeRecoveredFromRetainedWireBytes() {
        var sequence = Sequence()
        _ = sequence.apply(Self.first, diff: false)
        sequence.state.artwork = nil
        let heartbeat = sequence.apply(["timestamp": .string("2026-10-28T12:00:00Z")])
        #expect(heartbeat.artwork == nil)
        let explicitFreshCover = sequence.apply(["artworkData": .string(Self.artA.base64EncodedString())])
        #expect(explicitFreshCover.artwork == Self.artA)
    }

    @Test func unchangedItemKeepsItsCoverAcrossProgressAndFullSnapshotsWithoutArtwork() {
        var sequence = Sequence()
        _ = sequence.apply(Self.first, diff: false)
        let progress = sequence.apply(["elapsedTime": .number(5), "volume": .number(0.3)])
        #expect(progress.artwork == Self.artA)
        var snapshot = Self.first
        snapshot.removeValue(forKey: "artworkData")
        let full = sequence.apply(snapshot, diff: false)
        #expect(full.title == "Track A" && full.artwork == Self.artA)
        let heartbeat = sequence.apply(["elapsedTime": .number(6)])
        #expect(heartbeat.artwork == Self.artA)
    }

    @Test func aFreshSharedCoverDoesNotHideTheNewItem() {
        var sequence = Sequence()
        _ = sequence.apply(Self.first, diff: false)
        let next = sequence.apply(["title": .string("Track B"),
                                   "artworkData": .string(Self.artA.base64EncodedString())])
        #expect(next.title == "Track B" && next.artwork == Self.artA)
    }

    @Test func replacementWithoutFreshArtworkClearsButCompleteReplacementKeepsItsOwnCover() {
        var sequence = Sequence()
        _ = sequence.apply(Self.first, diff: false)
        let missing = sequence.apply(["bundleIdentifier": .string("fixture.player"),
                                      "title": .string("Track B"), "artist": .string("Fixture artist")], diff: false)
        #expect(missing.title == "Track B" && missing.artwork == nil)
        let fresh = sequence.apply(["bundleIdentifier": .string("fixture.player"),
                                    "title": .string("Track C"), "artist": .string("Fixture artist"),
                                    "artworkData": .string(Self.artB.base64EncodedString())], diff: false)
        #expect(fresh.title == "Track C" && fresh.artwork == Self.artB)
    }

    @Test func explicitNullOrMalformedFreshArtworkClearsWithoutHeartbeatResurrection() {
        for removed: MediaWireValue in [.null, .string("invalid base64!")] {
            var sequence = Sequence()
            _ = sequence.apply(Self.first, diff: false)
            let cleared = sequence.apply(["artworkData": removed])
            #expect(cleared.artwork == nil)
            let heartbeat = sequence.apply(["elapsedTime": .number(1)])
            #expect(heartbeat.artwork == nil)
        }
    }

    @Test func freshArtworkDecodingTrimsWhitespaceAndNeverPromotesOpaqueQueueIDs() {
        var sequence = Sequence()
        var snapshot = Self.first
        snapshot["uniqueIdentifier"] = .string("opaque-queue-42")
        snapshot["contentItemIdentifier"] = .string("42")
        snapshot["artworkData"] = .string(" \n" + Self.artA.base64EncodedString() + "\n ")
        let first = sequence.apply(snapshot, diff: false)
        #expect(first.artwork == Self.artA && first.nativeTrackID == nil)
        let next = sequence.apply(["title": .string("Track B"), "uniqueIdentifier": .string("opaque-queue-43")])
        #expect(next.artwork == nil && next.nativeTrackID == nil)
    }
}
