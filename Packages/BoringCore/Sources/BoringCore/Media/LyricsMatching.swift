import Foundation

public struct LyricsMatchCandidate: Decodable, Sendable, Equatable {
    public var id: String
    public var duration: Double
    public var plain: String
    public var synced: String
    public var title: String
    public var artist: String
    public var album: String
    public init(id: String = "", duration: Double, plain: String = "", synced: String = "",
                title: String = "", artist: String = "", album: String = "") {
        self.id = id; self.duration = duration; self.plain = plain; self.synced = synced
        self.title = title; self.artist = artist; self.album = album
    }
    private enum CodingKeys: String, CodingKey { case id, duration, plainLyrics, syncedLyrics, trackName, name, artistName, albumName }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(String.self, forKey: .id)) ?? (try? values.decode(Int.self, forKey: .id)).map(String.init) ?? ""
        duration = (try? values.decode(Double.self, forKey: .duration)) ?? 0
        plain = (try? values.decode(String.self, forKey: .plainLyrics))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        synced = (try? values.decode(String.self, forKey: .syncedLyrics))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        title = (try? values.decode(String.self, forKey: .trackName)) ?? (try? values.decode(String.self, forKey: .name)) ?? ""
        artist = (try? values.decode(String.self, forKey: .artistName)) ?? ""
        album = (try? values.decode(String.self, forKey: .albumName)) ?? ""
    }
    public func matches(title: String, artist: String) -> Bool {
        let target = MediaText.normalized(title)
        return !target.isEmpty && MediaText.normalized(self.title) == target
            && MediaText.artistsMatch([self.artist], target: artist)
    }
    public var document: LyricsDocument {
        let lines = LRCParser.parse(synced)
        return .init(plain: plain.isEmpty ? lines.map(\.text).joined(separator: "\n") : plain, synced: lines)
    }
}

public enum LyricsRecordingMatcher {
    public static func best(_ candidates: [LyricsMatchCandidate], duration: Double) -> LyricsMatchCandidate? {
        let known = duration.isFinite && duration > 0
        let matching = candidates.compactMap { candidate -> LyricsMatchCandidate? in
            guard !known || (candidate.duration.isFinite && candidate.duration > 0 && abs(candidate.duration - duration) <= 5) else { return nil }
            var candidate = candidate
            // A search hit within five seconds can supply plain text, but its timestamps
            // need the tighter recording match used by the exact /get endpoint. Without
            // duration, choosing the shortest/first synced edition is only a guess.
            if !known || abs(candidate.duration - duration) > 2 {
                candidate.synced = ""
            }
            return candidate.document.isEmpty ? nil : candidate
        }
        let synced = matching.filter { !$0.document.synced.isEmpty }
        let pool = synced.isEmpty ? matching : synced
        return known ? pool.min { abs($0.duration - duration) < abs($1.duration - duration) } : pool.first
    }
}
