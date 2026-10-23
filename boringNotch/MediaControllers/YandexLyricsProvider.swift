import BoringCore
import CryptoKit
import Foundation

// MARK: - Yandex Music lyrics API

/// Fetches lyrics that are synced to the exact Yandex recording (LRCLIB only has community
/// timings, which can be badly off for a specific edit). Needs the user's OAuth token.
struct YandexLyricsProvider: Sendable {
    var session: URLSession = MediaHTTPSession.shared
    let token: String
    private let base = "https://api.music.yandex.net"
    private let clientHeader = "YandexMusicAndroid/24023621"
    private let signSecret = "p93jhgh689SBReK6ghtw62"

    enum Result: Sendable {
        case lrc(String)   // synced LRC text
        case notFound      // reached the API, but the track/lyrics don't exist there
        case failed        // network/auth error — caller should fall back and may retry
    }

    /// Returns the raw LRC text for the exact playing recording, or a status for the caller.
    func fetchLRC(title: String, artist: String, album: String, duration: Double, nativeTrackID: String? = nil) async -> Result {
        guard !Task.isCancelled, !token.isEmpty else { return .failed }
        if let id = nativeTrackID, !id.isEmpty, id.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            return await lyrics(trackId: id)
        }
        guard let best = await resolveTrack(title: title, artist: artist, album: album, duration: duration) else {
            return .notFound
        }
        guard !Task.isCancelled else { return .failed }
        // Synced lyrics are only correct for the *exact* recording. If the best match carries no
        // synced lyrics (e.g. a live take), don't fetch — it would 404, and any other edition's LRC
        // would drift. Report notFound so the caller falls back to LRCLIB instead.
        guard best.hasSync else { return .notFound }
        return await lyrics(trackId: best.id)
    }

    private func authorized(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        r.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(clientHeader, forHTTPHeaderField: "X-Yandex-Music-Client")
        return r
    }

    // MARK: - Track resolution
    //
    // Getting perfect timing means fetching lyrics for the *exact* recording that's playing. Traps:
    //  1. Yandex has many editions per song (standard / Extended / live / remix / karaoke) with very
    //     different timings; a plain text search returns the popular one, and some editions surface
    //     only via the album (the Extended "Self Control" never appears in track search).
    //  2. Matching by duration alone can grab a *different song* of similar length ("The Lucky One"
    //     for "Self Control").
    //  3. The exact recording may have *no synced lyrics* (common for live takes) even when another
    //     edition does — using that other edition's LRC drifts (this made "Lift Me Up" ~4s late).
    // So: gather candidates from the album AND from track search, keep only same-title/near-duration
    // ones, and prefer a candidate that actually has synced lyrics at essentially the same length
    // (i.e. the same master). If even the best match has no synced lyrics, report notFound.

    private static let durationToleranceMs: Double = 5000   // "same song edition" window
    private static let sameRecordingMs: Double = 2000       // "same master" window (sync preference)

    private struct Candidate { let id: String; let durMs: Double; let hasSync: Bool }

    /// Normalise for comparison: fold case + diacritics, drop punctuation, collapse whitespace.
    private func norm(_ value: String) -> String { MediaText.normalized(value) }

    private func idOf(_ o: [String: Any]) -> String? {
        if let s = o["id"] as? String { return s }
        if let n = o["id"] as? NSNumber { return n.stringValue }
        return nil
    }
    private func durMs(_ t: [String: Any]) -> Double { (t["durationMs"] as? NSNumber)?.doubleValue ?? 0 }
    private func hasSync(_ t: [String: Any]) -> Bool {
        ((t["lyricsInfo"] as? [String: Any])?["hasAvailableSyncLyrics"] as? Bool) ?? false
    }
    private func titleMatches(_ candidate: String, _ target: String) -> Bool {
        let c = norm(candidate), t = norm(target)
        return !c.isEmpty && !t.isEmpty && c == t
    }

    func artistsMatch(_ track: [String: Any], _ target: String) -> Bool {
        guard let artists = track["artists"] as? [[String: Any]] else { return false }
        return MediaText.artistsMatch(artists.compactMap { $0["name"] as? String }, target: target)
    }

    private func trackMatches(_ track: [String: Any], title: String, artist: String) -> Bool {
        let baseTitle = track["title"] as? String ?? ""
        let version = track["version"] as? String ?? ""
        let matchesTitle = titleMatches(baseTitle, title)
            || (!baseTitle.isEmpty && !version.isEmpty && titleMatches(baseTitle + " " + version, title))
        return matchesTitle && artistsMatch(track, artist)
    }

    func queryValue(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))
    }

    private func get(_ path: String) async -> [String: Any]? {
        guard !Task.isCancelled, let url = URL(string: "\(base)\(path)"),
              let (data, resp) = try? await session.data(for: authorized(url)),
              !Task.isCancelled,
              (resp as? HTTPURLResponse)?.statusCode == 200,
              resp.url?.scheme == "https", resp.url?.host == "api.music.yandex.net", data.count <= 5_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }

    private func candidate(_ t: [String: Any]) -> Candidate? {
        guard let id = idOf(t) else { return nil }
        return Candidate(id: id, durMs: durMs(t), hasSync: hasSync(t))
    }

    /// The best-matching recording plus whether it carries synced lyrics; nil if nothing matches.
    private func resolveTrack(title: String, artist: String, album: String, duration: Double) async -> Candidate? {
        let targetMs = duration.isFinite && duration > 0 ? duration * 1000 : 0
        var seen = Set<String>()
        var candidates: [Candidate] = []
        func add(_ list: [Candidate]) { for c in list where seen.insert(c.id).inserted { candidates.append(c) } }

        // Album pins editions that text search misses; search adds the popular synced copies.
        if !album.isEmpty, targetMs > 0 { add(await albumCandidates(title: title, artist: artist, album: album)) }
        guard !Task.isCancelled else { return nil }
        add(await searchCandidates(title: title, artist: artist))
        guard !Task.isCancelled, !candidates.isEmpty else { return nil }

        let pool: [Candidate]
        if targetMs > 0 {
            let near = candidates.filter { abs($0.durMs - targetMs) <= Self.durationToleranceMs }
            // Exact recording isn't in Yandex → don't guess a wrong-length edition; let LRCLIB try.
            guard !near.isEmpty else { return nil }
            pool = near
        } else {
            pool = candidates
        }
        // Prefer a synced-lyrics copy at essentially the same length (same master); otherwise the
        // closest duration. This never substitutes a *different-length* edition's synced lyrics.
        func syncedSameMaster(_ c: Candidate) -> Bool {
            c.hasSync && abs(c.durMs - targetMs) <= Self.sameRecordingMs
        }
        return pool.min { a, b in
            let sa = syncedSameMaster(a), sb = syncedSameMaster(b)
            if sa != sb { return sa }
            return abs(a.durMs - targetMs) < abs(b.durMs - targetMs)
        }
    }

    private func albumCandidates(title: String, artist: String, album: String) async -> [Candidate] {
        guard let q = queryValue("\(album) \(artist)"),
              let json = await get("/search?text=\(q)&type=album&page=0&nocorrect=false"),
              let result = json["result"] as? [String: Any],
              let albums = (result["albums"] as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        // Choose the album whose title best matches the now-playing album.
        let target = norm(album)
        let scored = albums.compactMap { a -> (id: String, score: Int)? in
            guard let id = idOf(a), artistsMatch(a, artist) else { return nil }
            let at = norm(a["title"] as? String ?? "")
            let score = at == target ? 2 : ((at.contains(target) || target.contains(at)) && !at.isEmpty ? 1 : 0)
            return (id, score)
        }
        guard let picked = scored.max(by: { $0.score < $1.score }), picked.score > 0,
              let aj = await get("/albums/\(picked.id)/with-tracks"),
              let ar = aj["result"] as? [String: Any],
              let volumes = ar["volumes"] as? [[[String: Any]]] else { return [] }
        return volumes.flatMap { $0 }
            .filter { trackMatches($0, title: title, artist: artist) }
            .compactMap(candidate)
    }

    private func searchCandidates(title: String, artist: String) async -> [Candidate] {
        guard let q = queryValue("\(title) \(artist)"),
              let json = await get("/search?text=\(q)&type=track&page=0&nocorrect=false"),
              let result = json["result"] as? [String: Any],
              let results = (result["tracks"] as? [String: Any])?["results"] as? [[String: Any]] else { return [] }
        // Both title and performer must match; duration alone cannot identify a recording.
        return results
            .filter { trackMatches($0, title: title, artist: artist) }
            .compactMap(candidate)
    }

    private func lyrics(trackId: String) async -> Result {
        guard !Task.isCancelled else { return .failed }
        let ts = Int(Date().timeIntervalSince1970)
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(trackId)\(ts)".utf8), using: SymmetricKey(data: Data(signSecret.utf8)))
        let sign = Data(mac).base64EncodedString()
        guard let signEnc = queryValue(sign),
              let url = URL(string: "\(base)/tracks/\(trackId)/lyrics?format=LRC&timeStamp=\(ts)&sign=\(signEnc)"),
              let (data, resp) = try? await session.data(for: authorized(url)),
              !Task.isCancelled else { return .failed }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .notFound }   // no lyrics for this track
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let dl = result["downloadUrl"] as? String,
              let dlURL = URL(string: dl), dlURL.scheme?.lowercased() == "https",
              !Task.isCancelled,
              let (lrcData, lrcResp) = try? await session.data(for: URLRequest(url: dlURL, timeoutInterval: 10)),
              !Task.isCancelled,
              (lrcResp as? HTTPURLResponse)?.statusCode == 200, lrcResp.url?.scheme == "https", lrcData.count <= 2_000_000,
              let text = String(data: lrcData, encoding: .utf8), !text.isEmpty else { return .failed }
        return .lrc(text)
    }
}
