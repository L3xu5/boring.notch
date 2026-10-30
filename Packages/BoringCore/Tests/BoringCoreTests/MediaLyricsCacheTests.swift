import Foundation
import Testing
@testable import BoringCore

@Suite struct MediaLyricsCacheTests {
    @Test func boundedPositiveCacheAndMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("v4.json")
        try JSONEncoder().encode(["legacy": LyricsDocument(plain: "Legacy", synced: [])]).write(to: old)
        let cache = LyricsCache(fileURL: root.appendingPathComponent("new/cache.json"), legacyURLs: [old], maximumEntries: 2, timeToLive: 10)
        let now = Date(timeIntervalSince1970: 100)
        #expect(await cache.value(for: "legacy", now: now)?.plain == "Legacy")
        await cache.insert(.init(plain: "One", synced: []), for: "one", now: now.addingTimeInterval(1))
        await cache.insert(.init(plain: "Two", synced: []), for: "two", now: now.addingTimeInterval(2))
        #expect(await cache.count == 2)
        #expect(await cache.value(for: "legacy", now: now.addingTimeInterval(3)) == nil)
        #expect(await cache.value(for: "one", now: now.addingTimeInterval(12)) == nil)
        #expect(FileManager.default.fileExists(atPath: old.path))
        await cache.insert(.init(plain: "", synced: []), for: "miss")
        #expect(await cache.value(for: "miss") == nil)
    }
    @Test func matchRejectsDifferentRecordingBeforeSyncedPreference() {
        let exact = LyricsMatchCandidate(id: "exact", duration: 200, plain: "Plain")
        let wrong = LyricsMatchCandidate(id: "wrong", duration: 220, synced: "[00:01]Wrong")
        let same = LyricsMatchCandidate(id: "same", duration: 201, synced: "[00:01]Same")
        #expect(LyricsRecordingMatcher.best([exact, wrong], duration: 200)?.id == "exact")
        #expect(LyricsRecordingMatcher.best([exact, wrong, same], duration: 200)?.id == "same")
        #expect(LyricsRecordingMatcher.best([wrong], duration: 200) == nil)
    }
    @Test func nearbyEditionCannotSupplyUnverifiedTimestamps() {
        let exact = LyricsMatchCandidate(id: "exact", duration: 200, plain: "Exact plain")
        let different = LyricsMatchCandidate(id: "different", duration: 204, plain: "Nearby plain", synced: "[00:01]Nearby timed")
        #expect(LyricsRecordingMatcher.best([different, exact], duration: 200)?.id == "exact")
        #expect(LyricsRecordingMatcher.best([different], duration: 200)?.document.synced.isEmpty == true)
        #expect(LyricsRecordingMatcher.best([different], duration: 200)?.document.plain == "Nearby plain")
    }
    @Test func unknownDurationCannotGuessATimedEdition() {
        let candidate = LyricsMatchCandidate(id: "unknown", duration: 200, plain: "Plain", synced: "[00:01]Timed")
        #expect(LyricsRecordingMatcher.best([candidate], duration: 0)?.document == .init(plain: "Plain", synced: []))
        #expect(LyricsRecordingMatcher.best([.init(duration: 200, synced: "[00:01]Timed")], duration: .nan) == nil)
    }
    @Test func keywordSearchRequiresFullTitleAndPerformerSet() throws {
        let candidate = try JSONDecoder().decode(LyricsMatchCandidate.self, from: Data(#"{"trackName":"Sóng (Live)","artistName":"Artist feat. Guest","duration":200,"syncedLyrics":"[00:01]Live"}"#.utf8))
        #expect(!candidate.matches(title: "Song", artist: "Artist feat. Guest"))
        #expect(!candidate.matches(title: "Song Live", artist: "Artist"))
        #expect(candidate.matches(title: "Song Live", artist: "Guest, Artist"))
        #expect(!MediaText.artistsMatch(["Artist", "Guest"], target: "Artist"))
        #expect(MediaText.artistsMatch(["Artist", "Guest"], target: "Artist featuring Guest"))
    }
}
