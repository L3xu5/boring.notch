import BoringCore
import Foundation

struct LRCLIBClient: Sendable {
    let session: URLSession
    init(session: URLSession = MediaHTTPSession.shared) { self.session = session }
    func fetch(title: String, artist: String, album: String, duration: Double) async -> LyricsDocument? {
        if duration.isFinite, duration > 0, duration < Double(Int.max), !album.isEmpty,
           let data = await get("get", query: ["track_name": title, "artist_name": artist, "album_name": album, "duration": String(Int(duration.rounded()))]),
           let item = try? JSONDecoder().decode(LyricsMatchCandidate.self, from: data), item.matches(title: title, artist: artist),
           let match = LyricsRecordingMatcher.best([item], duration: duration) { return match.document }
        guard !Task.isCancelled,
              let data = await get("search", query: ["track_name": title, "artist_name": artist]),
              let candidates = try? JSONDecoder().decode([LyricsMatchCandidate].self, from: data) else { return nil }
        let exact = candidates.filter { $0.matches(title: title, artist: artist) }
        return LyricsRecordingMatcher.best(exact, duration: duration)?.document ?? .init(plain: "", synced: [])
    }
    private func get(_ path: String, query: [String: String]) async -> Data? {
        var url = URLComponents(string: "https://lrclib.net/api/" + path)!
        url.queryItems = query.map { .init(name: $0.key, value: $0.value.folding(options: .diacriticInsensitive, locale: .current)) }
        guard let url = url.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("boring.notch (github.com/L3xu5/boring.notch)", forHTTPHeaderField: "User-Agent")
        for attempt in 0..<2 {
            guard !Task.isCancelled else { return nil }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode
                if status == 404 { return nil }
                guard status == 200, data.count <= 5_000_000 else { throw URLError(.badServerResponse) }
                return data
            } catch {
                guard !Task.isCancelled else { return nil }
                if attempt == 0 {
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return nil }
                }
            }
        }
        return nil
    }
}
