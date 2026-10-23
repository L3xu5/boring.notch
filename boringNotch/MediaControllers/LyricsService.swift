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
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastKey = ""
    private var retryAfter: Date?

    init(cache: LyricsCache, session: URLSession = MediaHTTPSession.shared,
         nativeLyrics: @escaping @MainActor () async throws -> String? = { nil }) {
        self.cache = cache; self.session = session; self.nativeLyrics = nativeLyrics
    }
    deinit { task?.cancel() }

    static func cacheKey(_ request: LyricsRequest) -> String {
        let token = request.yandexToken
        let account = token.isEmpty ? "public" : SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        func normalized(_ value: String) -> String {
            value.folding(options: .diacriticInsensitive, locale: .current).replacingOccurrences(of: "\u{FFFD}", with: "")
        }
        return LyricsCacheKey.make(source: request.source, bundle: request.bundleIdentifier,
                                  provider: token.isEmpty ? "lrclib" : "yandex+lrclib", accountFingerprint: account,
                                  title: normalized(request.title), artist: normalized(request.artist), album: normalized(request.album),
                                  duration: request.duration, nativeID: request.nativeTrackID)
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
        if !force, key == lastKey, retryAfter.map({ Date() < $0 }) ?? true { return }
        stop()
        lastKey = key
        let ticket = generation
        isFetching = true
        document = .init(plain: "", synced: [])
        task = Task { [weak self, cache, session, nativeLyrics] in
            if force { await cache.remove(key) }
            guard !Task.isCancelled else { return }
            if let cached = await cache.value(for: key) {
                guard let self, self.isCurrent(ticket, key: key) else { return }
                self.document = cached; self.isFetching = false
                self.positiveCacheCount = await cache.count
                return
            }
            var result: LyricsDocument?
            if request.bundleIdentifier == "com.apple.Music", let plain = try? await nativeLyrics(), !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = .init(plain: plain.trimmingCharacters(in: .whitespacesAndNewlines), synced: [])
            }
            guard !Task.isCancelled, self?.isCurrent(ticket, key: key) == true else { return }
            if result == nil, !request.yandexToken.isEmpty {
                let provider = YandexLyricsProvider(session: session, token: request.yandexToken)
                if case .lrc(let text) = await provider.fetchLRC(title: request.title, artist: request.artist, album: request.album,
                                                               duration: request.duration, nativeTrackID: request.nativeTrackID) {
                    let lines = LRCParser.parse(text)
                    let document = LyricsDocument(plain: lines.map(\.text).joined(separator: "\n"), synced: lines)
                    if !document.isEmpty { result = document }
                }
            }
            guard !Task.isCancelled, self?.isCurrent(ticket, key: key) == true else { return }
            if result == nil {
                result = await LRCLIBClient(session: session).fetch(title: request.title, artist: request.artist,
                                                                  album: request.album, duration: request.duration)
            }
            guard let self, self.isCurrent(ticket, key: key) else { return }
            self.document = result ?? .init(plain: "", synced: [])
            self.isFetching = false
            if let result, !result.isEmpty {
                await cache.insert(result, for: key)
                if self.isCurrent(ticket, key: key) { self.positiveCacheCount = await cache.count }
            } else { self.retryAfter = Date().addingTimeInterval(result == nil ? 15 : 60) }
        }
    }
    private func isCurrent(_ ticket: UUID, key: String) -> Bool { !Task.isCancelled && generation == ticket && key == lastKey }
}
