import Foundation

public struct LyricsMatchCandidate: Decodable, Sendable, Equatable {
    public var id: String
    public var duration: Double
    public var plain: String
    public var synced: String
    public init(id: String = "", duration: Double, plain: String = "", synced: String = "") {
        self.id = id; self.duration = duration; self.plain = plain; self.synced = synced
    }
    private enum CodingKeys: String, CodingKey { case id, duration, plainLyrics, syncedLyrics }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? values.decode(String.self, forKey: .id)) ?? (try? values.decode(Int.self, forKey: .id)).map(String.init) ?? ""
        duration = (try? values.decode(Double.self, forKey: .duration)) ?? 0
        plain = (try? values.decode(String.self, forKey: .plainLyrics))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        synced = (try? values.decode(String.self, forKey: .syncedLyrics))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    public var document: LyricsDocument {
        let lines = LRCParser.parse(synced)
        return .init(plain: plain.isEmpty ? lines.map(\.text).joined(separator: "\n") : plain, synced: lines)
    }
}

public enum LyricsRecordingMatcher {
    public static func best(_ candidates: [LyricsMatchCandidate], duration: Double) -> LyricsMatchCandidate? {
        let known = duration.isFinite && duration > 0
        let matching = candidates.filter {
            (!$0.plain.isEmpty || !$0.synced.isEmpty) && (!known || ($0.duration > 0 && abs($0.duration - duration) <= 5))
        }
        let synced = matching.filter { !$0.synced.isEmpty }
        let pool = synced.isEmpty ? matching : synced
        return known ? pool.min { abs($0.duration - duration) < abs($1.duration - duration) } : pool.first
    }
}
