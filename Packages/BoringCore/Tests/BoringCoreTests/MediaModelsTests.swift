import Foundation
import Testing
@testable import BoringCore

@Suite struct MediaModelsTests {
    @Test func completeStateEquality() {
        let original = MediaPlaybackState(bundleIdentifier: "player")
        var changed = original; changed.volume = 0.8; #expect(changed != original)
        changed = original; changed.playbackRate = 2; #expect(changed != original)
        changed = original; changed.lastUpdated = Date(); #expect(changed != original)
    }
    @Test func unknownDurationAndPausedTimeline() {
        let now = Date(timeIntervalSince1970: 100)
        let timeline = MediaTimeline(position: 20, duration: 0, observedAt: now, rate: 1, isPlaying: true)
        #expect(timeline.position(at: now.addingTimeInterval(3)) == 23)
        #expect(MediaTimeline(position: 20, duration: 21, observedAt: now, rate: 1, isPlaying: true).position(at: now.addingTimeInterval(3)) == 21)
        #expect(MediaTimeline(position: 20, duration: 0, observedAt: now, rate: 1, isPlaying: false).position(at: now.addingTimeInterval(3)) == 20)
    }
    @Test func wireOwnerAndRemoval() throws {
        var wire = MediaWireState()
        wire.apply(.init(payload: ["parentApplicationBundleIdentifier": .string("yandex"), "bundleIdentifier": .string("helper.1")], diff: false))
        wire.apply(.init(payload: ["bundleIdentifier": .string("helper.2")]))
        #expect(wire.owner == "yandex")
        wire.apply(.init(payload: ["parentApplicationBundleIdentifier": .null]))
        #expect(wire.owner == "helper.2")
        wire.apply(.init(payload: [:], diff: false)); #expect(wire.owner == nil)
    }
    @Test func lrcFractionsRepeatedTimesAndOffset() {
        let result = LRCParser.parse("[offset:500]\n[00:01.5]One\n[00:02.50][00:03.125]Repeated\n[123:01]Long")
        #expect(result == [.init(time: 1, text: "One"), .init(time: 2, text: "Repeated"), .init(time: 2.625, text: "Repeated"), .init(time: 7380.5, text: "Long")])
        #expect(LRCParser.parse("[00:01]Verse\n[00:03]\n[00:05]Next")[1] == .init(time: 3, text: ""))
        #expect(LyricsDocument(plain: " ", synced: [.init(time: 0, text: "")]).isEmpty)
    }
    @Test func framingHasAnExplicitMemoryLimit() throws {
        var framing = JSONLinesFramer(maximumLineBytes: 8)
        #expect(try framing.append(Data("abc\n".utf8)) == [Data("abc".utf8)])
        #expect(throws: JSONLinesFramer.FramingError.self) { try framing.append(Data(repeating: 65, count: 9)) }
        #expect(framing.bufferedByteCount == 0)
    }
    @Test func opaqueWireIdentifiersCannotBecomeSourceAPITrackIDs() {
        var wire = MediaWireState()
        let update = MediaWireUpdate(payload: ["bundleIdentifier": .string("yandex"), "title": .string("Song"),
                                              "artist": .string("Artist"), "uniqueIdentifier": .string("42")], diff: false)
        wire.apply(update)
        let empty = MediaPlaybackState(bundleIdentifier: "yandex")
        #expect(wire.playbackState(applying: update, previous: empty, now: Date()).nativeTrackID == nil)
        let canonical = MediaPlaybackState(bundleIdentifier: "yandex", title: "Song", artist: "Artist", nativeTrackID: "123")
        #expect(wire.playbackState(applying: update, previous: canonical, now: Date()).nativeTrackID == "123")
    }
    @Test func sharedArtworkDoesNotHideANewTrackOrAnimateProgress() {
        let first = MediaPlaybackState(bundleIdentifier: "player", title: "First", artwork: Data([1]))
        var next = first; next.title = "Second"
        #expect(MediaContentChange.hasChanged(from: first, to: next))
        var progress = next; progress.currentTime = 3; progress.volume = 0.9
        #expect(progress != next)
        #expect(!MediaContentChange.hasChanged(from: next, to: progress))
    }
    @Test func removedPlayerFlagsDoNotRemainEnabled() {
        var wire = MediaWireState()
        let first = MediaWireUpdate(payload: ["bundleIdentifier": .string("player"), "title": .string("Song"),
                                             "shuffleMode": .number(3), "repeatMode": .number(2), "isLiked": .boolean(true)], diff: false)
        wire.apply(first)
        let previous = wire.playbackState(applying: first, previous: .init(bundleIdentifier: "player"), now: Date())
        let removed = MediaWireUpdate(payload: ["shuffleMode": .null, "repeatMode": .null, "isLiked": .null])
        wire.apply(removed)
        let result = wire.playbackState(applying: removed, previous: previous, now: Date())
        #expect(!result.isShuffled && result.repeatMode == .off && !result.isFavorite)
    }
    @Test func previewIsolationRequiresEveryExplicitDebugCondition() {
        #expect(MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: "local.boringnotch.preview", arguments: ["app", "--ui-snapshot"]))
        #expect(!MediaStartupPolicy.isIsolatedPreview(debugBuild: false, bundleIdentifier: "local.boringnotch.preview", arguments: ["--ui-snapshot"]))
        #expect(!MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: "theboringteam.boringnotch", arguments: ["--ui-snapshot"]))
        #expect(!MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: "local.YandexMetadataTests", arguments: ["--ui-snapshot"]))
        #expect(!MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: "local.boringnotch.preview", arguments: []))
        #expect(!MediaStartupPolicy.shouldStartAutomatically(firstLaunch: true, isolatedPreview: false))
        #expect(!MediaStartupPolicy.shouldStartAutomatically(firstLaunch: false, isolatedPreview: true))
        #expect(MediaStartupPolicy.shouldStartAutomatically(firstLaunch: false, isolatedPreview: false))
    }
}
