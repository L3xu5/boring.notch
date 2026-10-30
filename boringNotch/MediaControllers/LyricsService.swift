import BoringCore
import Combine
import CryptoKit
import Foundation

struct LyricsRequest: Sendable {
    var source: String
    var bundleIdentifier: String?
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var nativeTrackID: String?
    var yandexToken: String
    /// Source-local correlation only; never send an opaque MediaRemote ID to a provider API.
    var itemIdentifier: String? = nil
    var usesYandexProvider: Bool { source == "Yandex Music" || source == "yandexMusic" }
}

/// Owns request cancellation, provider selection and retry policy independently of UI fields.
/// The Keychain/Defaults/UI are caller dependencies; tests inject native lyrics and HTTP.
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var document = LyricsDocument(plain: "", synced: [])
    @Published private(set) var isFetching = false
    private(set) var positiveCacheCount = 0
    private let cache: LyricsCache
    private let session: URLSession
    private let nativeLyrics: @MainActor () async throws -> String?
    private let now: @MainActor () -> Date
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastKey = ""
    private var retryAfter: Date?

    init(cache: LyricsCache, session: URLSession = MediaHTTPSession.shared,
         nativeLyrics: @escaping @MainActor () async throws -> String? = { nil },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.cache = cache; self.session = session; self.nativeLyrics = nativeLyrics; self.now = now
    }
    deinit { task?.cancel() }

    static func cacheKey(_ request: LyricsRequest) -> String {
        let token = request.yandexToken
        let yandex = request.usesYandexProvider
        let account = token.isEmpty ? "public" : SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        func normalized(_ value: String) -> String {
            value.folding(options: .diacriticInsensitive, locale: .current).replacingOccurrences(of: "\u{FFFD}", with: "")
        }
        // Results selected by the old duration-only matcher may belong to another edition.
        // Leave existing files intact, but only reuse entries verified by the current policy.
        let recording = request.nativeTrackID?.isEmpty == false ? nil : request.itemIdentifier
        return "recording-v2\u{1E}" + LyricsCacheKey.make(source: request.source, bundle: request.bundleIdentifier,
                                  provider: yandex ? "yandex" : "lrclib", accountFingerprint: account,
                                  title: normalized(request.title), artist: normalized(request.artist), album: normalized(request.album),
                                  duration: request.duration, nativeID: request.nativeTrackID)
            + "\u{1E}" + (recording ?? "")
    }
    func stop(clear: Bool = false) {
        task?.cancel(); task = nil; generation = UUID(); lastKey = ""; retryAfter = nil
        isFetching = false
        if clear { document = .init(plain: "", synced: []) }
    }
    func retryNow() { retryAfter = .distantPast }
    func request(_ request: LyricsRequest, enabled: Bool, force: Bool = false) {
        guard enabled, !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stop(clear: true); return }
        let key = Self.cacheKey(request)
        // Even when an exact native ID permits cache reuse, a new source item must cancel
        // the old request before any suspended native/HTTP response can publish its result.
        let context = key + "\u{1D}" + (request.itemIdentifier ?? "")
        if !force, context == lastKey, retryAfter.map({ now() < $0 }) ?? true { return }
        stop()
        lastKey = context
        let ticket = generation
        isFetching = true
        document = .init(plain: "", synced: [])
        task = Task { [weak self, cache, session, nativeLyrics] in
            let yandex = request.usesYandexProvider
            if yandex, request.nativeTrackID.map({ !$0.isEmpty && $0.allSatisfy { $0 >= "0" && $0 <= "9" } }) != true {
                // A matching title/duration can still identify a different edit. Wait for
                // Accessibility to establish the exact source ID before reading any cache
                // or provider; its arrival changes the key and starts the request at once.
                guard let self, self.isCurrent(ticket, key: context) else { return }
                self.isFetching = false
                self.retryAfter = self.now().addingTimeInterval(60)
                return
            }
            if force { await cache.remove(key) }
            guard !Task.isCancelled else { return }
            if let cached = await cache.value(for: key) {
                guard let self, self.isCurrent(ticket, key: context) else { return }
                self.document = cached; self.isFetching = false
                self.positiveCacheCount = await cache.count
                return
            }
            var result: LyricsDocument?
            var transientFailure = false
            if !yandex, request.bundleIdentifier == "com.apple.Music", let plain = try? await nativeLyrics(), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .init(plain: plain.trimmingCharacters(in: .whitespacesAndNewlines), synced: [])
            }
            guard !Task.isCancelled, self?.isCurrent(ticket, key: context) == true else { return }
            if result == nil, yandex, !request.yandexToken.isEmpty {
                let provider = YandexLyricsProvider(session: session, token: request.yandexToken)
                switch await provider.fetchLRC(title: request.title, artist: request.artist, album: request.album,
                                               duration: request.duration, nativeTrackID: request.nativeTrackID) {
                case .lrc(let text):
                    let lines = LRCParser.parse(text)
                    let document = LyricsDocument(plain: lines.map(\.text).joined(separator: "\n"), synced: lines)
                    if !document.isEmpty { result = document }
                case .notFound: break
                case .failed: transientFailure = true
                }
            }
            guard !Task.isCancelled, self?.isCurrent(ticket, key: context) == true else { return }
            // A different provider cannot prove that its lyrics belong to the exact Yandex
            // recording. An API miss/error must never replace the native song's text or
            // persist a fallback that prevents recovery when Yandex becomes reachable.
            if result == nil, !yandex {
                result = await LRCLIBClient(session: session).fetch(title: request.title, artist: request.artist,
                                                                  album: request.album, duration: request.duration)
                transientFailure = result == nil
            }
            guard let self, self.isCurrent(ticket, key: context) else { return }
            self.document = result ?? .init(plain: "", synced: [])
            self.isFetching = false
            if let result, !result.isEmpty {
                await cache.insert(result, for: key)
                if self.isCurrent(ticket, key: context) { self.positiveCacheCount = await cache.count }
            } else { self.retryAfter = self.now().addingTimeInterval(transientFailure ? 15 : 60) }
        }
    }
    private func isCurrent(_ ticket: UUID, key: String) -> Bool { !Task.isCancelled && generation == ticket && key == lastKey }
}
