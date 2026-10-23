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
}
