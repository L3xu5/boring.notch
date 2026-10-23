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
        try await exactNativeIdentifier()
        try await specialQueryCharacters()
        try await sameTrackReload()
        try await disableDuringNativeFetch()
        try await staleWebFetch()
        try await negativeResultsRetry()
        print("9 lyrics regression scenarios passed (actual service and Core module)")
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
            return .init(json: [["duration": 200, "plainLyrics": title]], delay: title == "Old" ? 0.2 : 0)
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
        FixtureNetwork.reset { _ in .init(json: [["duration": 200, "plainLyrics": "Now available"]]) }
        manager.retryNow()
        manager.request(bundle: "player")
        try await eventually("lyrics appeared after backoff") { manager.currentLyrics == "Now available" }
    }
}
