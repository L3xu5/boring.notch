import Foundation
import CryptoKit

// Links the real LyricsService, HTTP providers and Swift 6 Core module. Only preferences,
// native-lyrics results and URL loading are injected; no production algorithms are copied.
let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("boring-notch-lyrics-fixtures-" + UUID().uuidString)

enum MediaControllerType: String { case nowPlaying, appleMusic, spotify, youtubeMusic, yandexMusic }
struct FixtureDefaultKey<Value> { let name: String }
extension FixtureDefaultKey where Value == Bool {
    static var enableLyrics: Self { .init(name: "enabled") }
}
extension FixtureDefaultKey where Value == MediaControllerType {
    static var mediaController: Self { .init(name: "source") }
}
enum Defaults {
    static var enabled = true
    static var source = MediaControllerType.yandexMusic
    static subscript<Value>(_ key: FixtureDefaultKey<Value>) -> Value {
        get {
            if key.name == "enabled" { return enabled as! Value }
            return source as! Value
        }
        set {
            if key.name == "enabled" { enabled = newValue as! Bool }
            else { source = newValue as! MediaControllerType }
        }
    }
}
final class YandexMusicTokenStore {
    static let shared = YandexMusicTokenStore()
    var token = ""
}
struct NSRunningApplication {
    static var isRunning = false
    static func runningApplications(withBundleIdentifier _: String) -> [Self] {
        isRunning ? [Self()] : []
    }
}
struct ScriptResult { let stringValue: String? }
@MainActor enum AppleScriptHelper {
    static var pending: [CheckedContinuation<ScriptResult?, Error>?] = []
    static func execute(_: String) async throws -> ScriptResult? {
        // Deliberately ignore Task cancellation, as an already executing AppleScript can do.
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    static func complete(_ index: Int, with lyrics: String) {
        let continuation = pending[index]
        pending[index] = nil
        continuation?.resume(returning: ScriptResult(stringValue: lyrics))
    }
}

struct FixtureResponse {
    var json: Any = []
    var text: String?
    var status = 200
    var delay: TimeInterval = 0
}
enum FixtureNetwork {
    static let lock = NSLock()
    static var handler: (URLRequest) -> FixtureResponse = { _ in .init() }
    static var requests: [URL] = []
    static func respond(_ request: URLRequest) -> FixtureResponse {
        lock.lock()
        requests.append(request.url!)
        let response = handler(request)
        lock.unlock()
        return response
    }
    static func reset(_ response: @escaping (URLRequest) -> FixtureResponse) {
        lock.lock()
        handler = response
        requests = []
        lock.unlock()
    }
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}
final class FixtureURLProtocol: URLProtocol {
    private var delivery: DispatchWorkItem?
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = FixtureNetwork.respond(request)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let data = response.text.map { Data($0.utf8) }
                ?? (try! JSONSerialization.data(withJSONObject: response.json))
            let http = HTTPURLResponse(url: self.request.url!, statusCode: response.status,
                                       httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: work)
    }
    override func stopLoading() { delivery?.cancel() }
}

@MainActor
final class MusicManager {
    var songTitle = "Song"
    var artistName = "Artist"
    var album = ""
    var songDuration = 200.0
    var bundleIdentifier: String? = "com.apple.Music"
    private var lastRequest: LyricsRequest?
    private let service: LyricsService
    init() {
        service = LyricsService(cache: LyricsCache(fileURL: temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")), session: .shared, nativeLyrics: {
            guard NSRunningApplication.isRunning else { return nil }
            return try await AppleScriptHelper.execute("")?.stringValue
        })
    }
    var currentLyrics: String { service.document.plain }
    var syncedLyrics: [LyricsLine] { service.document.synced }
    var isFetchingLyrics: Bool { service.isFetching }
    func request(title: String = "Song", bundle: String? = "com.apple.Music") {
        songTitle = title; bundleIdentifier = bundle
        let request = LyricsRequest(source: Defaults.source.rawValue, bundleIdentifier: bundle, title: title,
                                    artist: artistName, album: album, duration: songDuration, nativeTrackID: nil,
                                    yandexToken: Defaults.source == .yandexMusic ? YandexMusicTokenStore.shared.token : "")
        lastRequest = request
        service.request(request, enabled: Defaults.enabled)
    }
    func reloadLyricsForCurrentTrack() {
        if let lastRequest { service.request(lastRequest, enabled: Defaults.enabled, force: true) }
    }
    func match(_ items: [[String: Any]], duration: Double) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let candidates = try? JSONDecoder().decode([LyricsMatchCandidate].self, from: data) else { return nil }
        return LyricsRecordingMatcher.best(candidates, duration: duration)?.id
    }
    func cacheKey(album: String = "Album", bundle: String? = "player", token: String = "") -> String {
        LyricsService.cacheKey(.init(source: Defaults.source.rawValue, bundleIdentifier: bundle, title: "Song",
                                    artist: "Artist", album: album, duration: 200, nativeTrackID: nil, yandexToken: token))
    }
    var cacheCount: Int { service.positiveCacheCount }
    func retryNow() { service.retryNow() }
    func stop() { service.stop(clear: true) }
}

extension YandexLyricsProvider {
    func encodedQueryValue(_ value: String) -> String? { queryValue(value) }
    func matchesArtist(_ names: [String], target: String) -> Bool {
        artistsMatch(["artists": names.map { ["name": $0] }], target)
    }
}

struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
@MainActor func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestFailure(description: "Timed out: " + message)
}

@main struct LyricsRegressionTests {
    @MainActor static func main() async throws {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0, directory: temporaryDirectory)
        URLProtocol.registerClass(FixtureURLProtocol.self)
        try durationMatching()
        try cachePartitioning()
        try await yandexMatching()
        try await yandexVersionMatching()
        try await exactNativeIdentifier()
        try await authoritativeYandexLyrics()
        try await yandexWaitsForExactRecording()
        try await opaqueRecordingLifetime()
        try await rejectsOldMatcherCache()
        try await lrclibResponseMatching()
        try await specialQueryCharacters()
        try await sameTrackReload()
        try await disableDuringNativeFetch()
        try await staleWebFetch()
        try await negativeResultsRetry()
        print("15 lyrics regression scenarios passed (actual service and Core module)")
    }

    @MainActor static func durationMatching() throws {
        let manager = MusicManager()
        defer { manager.stop() }
        let exactPlain: [String: Any] = ["id": "exact", "duration": 200, "plainLyrics": "Exact text"]
        let extended: [String: Any] = ["id": "extended", "duration": 220, "syncedLyrics": "[00:01]Wrong"]
        let sameMaster: [String: Any] = ["id": "same", "duration": 201, "syncedLyrics": "[00:01]Right"]
        try expect(manager.match([extended, exactPlain], duration: 200) == "exact", "Wrong-length synced copy beat exact plain lyrics")
        try expect(manager.match([extended], duration: 200) == nil, "Wrong-length recording was accepted")
        try expect(manager.match([exactPlain, sameMaster], duration: 200) == "same", "Synced same-recording preference was lost")
        let nearEdition: [String: Any] = ["id": "near-edition", "duration": 204, "syncedLyrics": "[00:01]Other edit"]
        try expect(manager.match([exactPlain, nearEdition], duration: 200) == "exact", "Four-second alternate edition beat the exact plain recording")
        try expect(manager.match([nearEdition], duration: 200) == nil, "Unverified four-second timings were accepted")
        try expect(manager.match([sameMaster], duration: 0) == nil, "Unknown duration selected arbitrary synced timestamps")
    }

    @MainActor static func cachePartitioning() throws {
        let manager = MusicManager()
        defer { manager.stop() }
        Defaults.source = .yandexMusic
        let original = manager.cacheKey(token: "secret-account-A")
        try expect(original != manager.cacheKey(album: "Other Album", token: "secret-account-A"), "Albums shared cache entries")
        try expect(original != manager.cacheKey(bundle: "other-player", token: "secret-account-A"), "Players shared cache entries")
        try expect(original != manager.cacheKey(token: "secret-account-B"), "Accounts shared cache entries")
        try expect(!original.contains("secret-account-A"), "Credential leaked into cache key")
        Defaults.source = .nowPlaying
        try expect(original != manager.cacheKey(token: "secret-account-A"), "Controller sources shared cache entries")
    }

    static func track(_ id: String, title: String = "Song", artist: String = "Artist",
                      duration: Int = 200000, synced: Bool = true) -> [String: Any] {
        ["id": id, "title": title, "artists": [["name": artist]], "durationMs": duration,
         "lyricsInfo": ["hasAvailableSyncLyrics": synced]]
    }

    @MainActor static func yandexMatching() async throws {
        let provider = YandexLyricsProvider(session: .shared, token: "fixture")
        try expect(provider.matchesArtist(["Artist", "Guest"], target: "Artist featuring Guest"), "A featured performer was not normalized")
        try expect(provider.matchesArtist(["Artist", "Guest"], target: "Artist feat. Guest"), "A feat. performer was not normalized")
        try expect(!provider.matchesArtist(["Artist", "Other"], target: "Artist feat. Guest"), "A different collaboration was accepted")
        try expect(!provider.matchesArtist(["Artist", "Guest"], target: "Artist"), "A primary-artist subset accepted another collaboration")
        let candidates = [
            track("empty", title: ""), track("substring", title: "Song Prelude"),
            track("wrong-artist", artist: "Other Artist"), track("exact-plain", synced: false),
            track("same-master", duration: 201000), track("extended", duration: 220000),
        ]
        FixtureNetwork.reset { request in
            let path = request.url!.path
            if path == "/search" {
                return .init(json: ["result": ["tracks": ["results": candidates]]])
            }
            if path.hasPrefix("/tracks/") {
                let id = path.components(separatedBy: "/")[2]
                return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/\(id).lrc"]])
            }
            return .init(text: "[00:01.00]" + request.url!.deletingPathExtension().lastPathComponent)
        }
        let result = await YandexLyricsProvider(session: .shared, token: "fixture").fetchLRC(title: "Sóng", artist: "Artist", album: "", duration: 200)
        guard case .lrc(let lyrics) = result else { throw TestFailure(description: "Yandex exact match was not found") }
        try expect(lyrics.contains("same-master"), "Yandex selected empty/substring/wrong-artist title or lost synced same-master preference")
        let unrelated = await YandexLyricsProvider(session: .shared, token: "fixture").fetchLRC(title: "Song", artist: "Another Performer", album: "", duration: 200)
        guard case .notFound = unrelated else { throw TestFailure(description: "Different performer was accepted") }
    }

    @MainActor static func yandexVersionMatching() async throws {
        var live = track("live", duration: 200000); live["version"] = "Live"
        var remix = track("remix", duration: 200000); remix["version"] = "Dance Remix"
        var remaster = track("remaster", duration: 201000); remaster["version"] = "2011 Remaster"
        let candidates = [live, remix, remaster]
        FixtureNetwork.reset { request in
            if request.url!.path == "/search" { return .init(json: ["result": ["tracks": ["results": candidates]]]) }
            if request.url!.path.hasPrefix("/tracks/") {
                return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/" + request.url!.path.components(separatedBy: "/")[2] + ".lrc"]])
            }
            return .init(text: "[00:01.00]" + request.url!.deletingPathExtension().lastPathComponent)
        }
        let provider = YandexLyricsProvider(session: .shared, token: "fixture")
        guard case .lrc(let original) = await provider.fetchLRC(title: "Song", artist: "Artist", album: "", duration: 200) else {
            throw TestFailure(description: "Same-length remaster was rejected")
        }
        try expect(original.contains("remaster"), "Base-title query selected a live take/remix instead of a compatible remaster")
        guard case .lrc(let explicitLive) = await provider.fetchLRC(title: "Song (Live)", artist: "Artist", album: "", duration: 200) else {
            throw TestFailure(description: "Explicit live recording was rejected")
        }
        try expect(explicitLive.contains("live"), "Explicit version did not select its own lyrics")
        let before = FixtureNetwork.count
        guard case .notFound = await provider.fetchLRC(title: "Song", artist: "Artist", album: "", duration: 0) else {
            throw TestFailure(description: "Unknown duration guessed a Yandex edition")
        }
        try expect(FixtureNetwork.count == before, "Unknown duration started a speculative Yandex lookup")
    }

    static func request(nativeID: String? = "123", item: String? = "item A", token: String = "fixture") -> LyricsRequest {
        .init(source: "Yandex Music", bundleIdentifier: "ru.yandex.desktop.music", title: "Song", artist: "Artist",
              album: "Album", duration: 200, nativeTrackID: nativeID, yandexToken: token, itemIdentifier: item)
    }
    @MainActor static func authoritativeYandexLyrics() async throws {
        let cache = LyricsCache(fileURL: temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var observedAt = Date(timeIntervalSince1970: 10_000)
        let service = LyricsService(cache: cache, session: .shared, now: { observedAt })
        defer { service.stop(clear: true) }
        FixtureNetwork.reset { _ in .init(json: ["trackName": "Song", "artistName": "Artist", "duration": 200, "syncedLyrics": "[00:01]Wrong fallback"]) }
        service.request(request(token: ""), enabled: true)
        try await eventually("no-token Yandex result") { !service.isFetching }
        try expect(FixtureNetwork.count == 0 && service.document.isEmpty, "Missing Yandex token fetched another provider's text")
        var legacy = request(token: ""); legacy.source = "yandexMusic"
        service.request(legacy, enabled: true)
        try await eventually("legacy Yandex source result") { !service.isFetching }
        try expect(FixtureNetwork.count == 0 && service.document.isEmpty, "Legacy Yandex source name bypassed provider authority")

        FixtureNetwork.reset { _ in .init(status: 404) }
        service.request(request(), enabled: true)
        try await eventually("native Yandex lyrics unavailable") { !service.isFetching }
        try expect(FixtureNetwork.requests.count == 1 && FixtureNetwork.requests[0].host == "api.music.yandex.net", "Yandex miss substituted another provider")
        try expect(service.document.isEmpty, "Yandex miss published unrelated text")
        let cachedMisses = await cache.count
        try expect(cachedMisses == 0, "A Yandex miss was cached")
        observedAt = observedAt.addingTimeInterval(59)
        service.request(request(), enabled: true)
        try expect(!service.isFetching && FixtureNetwork.count == 1, "Yandex miss ignored its bounded backoff")
        observedAt = observedAt.addingTimeInterval(2)
        service.request(request(), enabled: true)
        try await eventually("Yandex miss can retry without a track change") { !service.isFetching && FixtureNetwork.count == 2 }

        FixtureNetwork.reset { _ in .init(status: 503) }
        service.request(request(), enabled: true, force: true)
        try await eventually("native Yandex transient failure") { !service.isFetching }
        try expect(FixtureNetwork.count == 1 && service.document.isEmpty, "Yandex failure fetched a permanent fallback")
        observedAt = observedAt.addingTimeInterval(14)
        service.request(request(), enabled: true)
        try expect(!service.isFetching && FixtureNetwork.count == 1, "Yandex error retried before the transient backoff expired")
        FixtureNetwork.reset { request in
            if request.url!.host == "api.music.yandex.net" { return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/recovered.lrc"]]) }
            return .init(text: "[00:01]Recovered native recording")
        }
        observedAt = observedAt.addingTimeInterval(2)
        service.request(request(), enabled: true)
        try await eventually("native Yandex recovered") { service.document.plain == "Recovered native recording" }
        try expect(FixtureNetwork.requests.allSatisfy { $0.host != "lrclib.net" }, "Retry used another lyrics provider")
    }

    @MainActor static func opaqueRecordingLifetime() async throws {
        let first = request(nativeID: nil, item: "opaque A")
        let second = request(nativeID: nil, item: "opaque B")
        try expect(LyricsService.cacheKey(first) != LyricsService.cacheKey(second), "Opaque recordings without native IDs shared a cache entry")
        try expect(LyricsService.cacheKey(request(item: "opaque A")) == LyricsService.cacheKey(request(item: "opaque B")), "Opaque churn invalidated an exact native-ID cache entry")
        // Native AppleScript can complete after cancellation; use it to prove that same-ID,
        // same-text source-item changes still invalidate the previous request context.
        var old = request(item: "opaque A", token: ""); old.source = "appleMusic"; old.bundleIdentifier = "com.apple.Music"
        var new = old; new.itemIdentifier = "opaque B"
        AppleScriptHelper.pending = []
        let service = LyricsService(cache: LyricsCache(fileURL: temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")), session: .shared, nativeLyrics: {
            try await AppleScriptHelper.execute("")?.stringValue
        })
        defer { service.stop(clear: true) }
        service.request(old, enabled: true)
        try await eventually("old opaque native request") { AppleScriptHelper.pending.count == 1 }
        service.request(new, enabled: true)
        try await eventually("new opaque native request") { AppleScriptHelper.pending.count == 2 }
        AppleScriptHelper.complete(1, with: "Current recording")
        try await eventually("new opaque response") { service.document.plain == "Current recording" }
        AppleScriptHelper.complete(0, with: "Old recording")
        try await Task.sleep(for: .milliseconds(20))
        try expect(service.document.plain == "Current recording", "Late same-text recording replaced current lyrics")
    }

    @MainActor static func yandexWaitsForExactRecording() async throws {
        let service = LyricsService(cache: LyricsCache(fileURL: temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")), session: .shared)
        defer { service.stop(clear: true) }
        FixtureNetwork.reset { request in
            if request.url!.path == "/search" {
                return .init(json: ["result": ["tracks": ["results": [track("999", title: "Song", duration: 200000)]]]])
            }
            if request.url!.path == "/tracks/123/lyrics" {
                return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/actual.lrc"]])
            }
            return .init(text: "[00:01]Exact current recording")
        }
        service.request(request(nativeID: nil), enabled: true)
        try await eventually("Yandex waits for exact recording") { !service.isFetching }
        try expect(service.document.isEmpty && FixtureNetwork.count == 0, "Yandex searched a same-title edition before the exact ID arrived")
        for invalid in ["", "opaque 123", "１２３", "١٢٣"] {
            service.request(request(nativeID: invalid), enabled: true)
            try await eventually("Yandex rejects an opaque/non-ASCII ID") { !service.isFetching }
            try expect(service.document.isEmpty && FixtureNetwork.count == 0, "Untrusted ID triggered a speculative Yandex search")
        }
        service.request(request(nativeID: "123"), enabled: true)
        try await eventually("exact Yandex recording enriches immediately") { service.document.plain == "Exact current recording" }
        try expect(FixtureNetwork.requests.count == 2 && FixtureNetwork.requests[0].path == "/tracks/123/lyrics", "Exact-ID enrichment was blocked by backoff or used search")
    }

    @MainActor static func rejectsOldMatcherCache() async throws {
        let value = request(token: "")
        let oldKey = LyricsCacheKey.make(source: value.source, bundle: value.bundleIdentifier, provider: "lrclib", accountFingerprint: "public",
                                        title: value.title, artist: value.artist, album: value.album, duration: value.duration, nativeID: value.nativeTrackID)
        let oldURL = temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode([oldKey: LyricsDocument(plain: "Poisoned edition", synced: [.init(time: 1, text: "Poisoned edition")])]).write(to: oldURL)
        let service = LyricsService(cache: LyricsCache(fileURL: temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"), legacyURLs: [oldURL]), session: .shared)
        defer { service.stop(clear: true) }
        FixtureNetwork.reset { _ in .init(status: 404) }
        service.request(value, enabled: true)
        try await eventually("legacy matcher cache ignored") { !service.isFetching }
        try expect(service.document.isEmpty && FileManager.default.fileExists(atPath: oldURL.path), "Old mismatched lyrics were reused or legacy file removed")
    }

    @MainActor static func lrclibResponseMatching() async throws {
        func candidate(_ id: String, title: String = "Song", artist: String = "Artist", duration: Double = 200) -> [String: Any] {
            ["id": id, "trackName": title, "artistName": artist, "duration": duration, "syncedLyrics": "[00:01]" + id]
        }
        FixtureNetwork.reset { request in
            if request.url!.path == "/api/get" { return .init(json: candidate("bad-get", title: "Song Live", duration: 240)) }
            return .init(json: [candidate("substring", title: "Song Live"), candidate("other", artist: "Artist, Guest"), candidate("far", duration: 204), candidate("exact")])
        }
        let result = await LRCLIBClient(session: .shared).fetch(title: "Song", artist: "Artist", album: "Album", duration: 200)
        try expect(result?.plain == "exact", "LRCLIB /get or keyword search selected another recording")
        try expect(FixtureNetwork.requests.count == 2, "Unverified /get result did not proceed to verified search")
    }

    @MainActor static func exactNativeIdentifier() async throws {
        FixtureNetwork.reset { request in
            if request.url!.path == "/tracks/123/lyrics" {
                return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/exact.lrc"]])
            }
            return .init(text: "[00:01.00]Exact recording")
        }
        let result = await YandexLyricsProvider(session: .shared, token: "fixture").fetchLRC(title: "Ambiguous title", artist: "Artist", album: "Album", duration: 0, nativeTrackID: "123")
        guard case .lrc(let text) = result else { throw TestFailure(description: "Exact source ID was not used") }
        try expect(text.contains("Exact recording"), "Exact-id request lost lyrics")
        try expect(!FixtureNetwork.requests.contains { $0.path == "/search" }, "A known exact recording was replaced with text search")
    }

    @MainActor static func specialQueryCharacters() async throws {
        let title = "Rock & Roll + Forever"
        let artist = "A + B"
        let provider = YandexLyricsProvider(session: .shared, token: "fixture")
        try expect(provider.encodedQueryValue("+/=&") == "%2B%2F%3D%26", "HMAC/query delimiters were not encoded")
        FixtureNetwork.reset { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = components.queryItems?.first { $0.name == "text" }?.value
            if request.url!.path == "/search" {
                guard query == title + " " + artist else { return .init(status: 400) }
                return .init(json: ["result": ["tracks": ["results": [track("special", title: title, artist: artist)]]]])
            }
            if request.url!.path.hasPrefix("/tracks/") {
                return .init(json: ["result": ["downloadUrl": "https://fixture.invalid/special.lrc"]])
            }
            return .init(text: "[00:01.00]Special characters survived")
        }
        let result = await provider.fetchLRC(title: title, artist: artist, album: "", duration: 200)
        guard case .lrc(let lyrics) = result else { throw TestFailure(description: "Special-character track query failed") }
        try expect(lyrics.contains("Special characters survived"), "Encoded track query selected the wrong result")
    }

    @MainActor static func sameTrackReload() async throws {
        Defaults.enabled = true; Defaults.source = .appleMusic; NSRunningApplication.isRunning = true
        AppleScriptHelper.pending = []
        let manager = MusicManager()
        defer { manager.stop() }
        manager.request()
        try await eventually("first native request") { AppleScriptHelper.pending.count == 1 }
        manager.reloadLyricsForCurrentTrack()
        try await eventually("same-track reload") { AppleScriptHelper.pending.count == 2 }
        AppleScriptHelper.complete(1, with: "Fresh lyrics")
        try await eventually("fresh native response") { manager.currentLyrics == "Fresh lyrics" }
        AppleScriptHelper.complete(0, with: "Stale lyrics")
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.currentLyrics == "Fresh lyrics", "Canceled same-track native fetch replaced the reload")
    }

    @MainActor static func disableDuringNativeFetch() async throws {
        Defaults.enabled = true; Defaults.source = .appleMusic; NSRunningApplication.isRunning = true
        AppleScriptHelper.pending = []
        let manager = MusicManager()
        defer { manager.stop() }
        manager.request()
        try await eventually("native request before disabling") { AppleScriptHelper.pending.count == 1 }
        Defaults.enabled = false
        manager.request()
        AppleScriptHelper.complete(0, with: "Disabled lyrics")
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.currentLyrics.isEmpty && manager.syncedLyrics.isEmpty && !manager.isFetchingLyrics, "Disabled lyrics were restored by a late response")
        Defaults.enabled = true
        manager.request()
        try await eventually("re-enabled request for same key") { AppleScriptHelper.pending.count == 2 }
        AppleScriptHelper.complete(1, with: "Enabled again")
        try await eventually("re-enabled lyrics") { manager.currentLyrics == "Enabled again" }
    }

    @MainActor static func staleWebFetch() async throws {
        Defaults.enabled = true; Defaults.source = .nowPlaying; NSRunningApplication.isRunning = false
        FixtureNetwork.reset { request in
            let title = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "track_name" }?.value ?? ""
            return .init(json: [["trackName": title, "artistName": "Artist", "duration": 200, "plainLyrics": title]], delay: title == "Old" ? 0.2 : 0)
        }
        let manager = MusicManager()
        defer { manager.stop() }
        manager.request(title: "Old", bundle: "old.player")
        try await eventually("old web request") { FixtureNetwork.count > 0 }
        manager.request(title: "New", bundle: "new.player")
        try await eventually("new web lyrics") { manager.currentLyrics == "New" }
        try await Task.sleep(for: .milliseconds(250))
        try expect(manager.currentLyrics == "New", "A previous source's late web result replaced the current track")
    }

    @MainActor static func negativeResultsRetry() async throws {
        Defaults.enabled = true; Defaults.source = .nowPlaying; NSRunningApplication.isRunning = false
        FixtureNetwork.reset { _ in .init(json: []) }
        let manager = MusicManager()
        defer { manager.stop() }
        manager.request(bundle: "player")
        try await eventually("empty search completed") { FixtureNetwork.count == 1 && !manager.isFetchingLyrics }
        try expect(manager.cacheCount == 0, "An empty result was persisted in the positive cache")
        manager.request(bundle: "player")
        try await Task.sleep(for: .milliseconds(20))
        try expect(FixtureNetwork.count == 1, "An authoritative miss ignored the retry backoff")
        FixtureNetwork.reset { _ in .init(json: [["trackName": "Song", "artistName": "Artist", "duration": 200, "plainLyrics": "Now available"]]) }
        manager.retryNow()
        manager.request(bundle: "player")
        try await eventually("lyrics appeared after backoff") { manager.currentLyrics == "Now available" }
    }
}
