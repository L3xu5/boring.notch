import Foundation

public struct YouTubeMusicConfiguration: Sendable {
    public let baseURL: String
    public let bundleIdentifier: String
    public let reconnectDelay: ClosedRange<TimeInterval>
    public let updateInterval: TimeInterval
    public let connectedHealthInterval: TimeInterval
    public init(baseURL: String, bundleIdentifier: String, reconnectDelay: ClosedRange<TimeInterval> = 1...60,
                updateInterval: TimeInterval = 2, connectedHealthInterval: TimeInterval = 10) {
        self.baseURL = baseURL; self.bundleIdentifier = bundleIdentifier; self.reconnectDelay = reconnectDelay
        self.updateInterval = updateInterval; self.connectedHealthInterval = connectedHealthInterval
    }
    public static let `default` = Self(baseURL: "http://localhost:26538", bundleIdentifier: "com.github.th-ch.youtube-music")
}

public enum YouTubeMusicError: Error, Sendable, Equatable {
    case invalidURL, invalidResponse, authenticationRequired, responseTooLarge
    case httpError(Int)
}
public struct YouTubeAuthResponse: Decodable, Sendable { public let accessToken: String }
public enum YouTubePlaybackField: String, Sendable { case title, artist, album, imageSrc, videoId }

/// HTTP snapshots and socket deltas share a typed patch; missing fields never invent a pause.
public struct YouTubePlaybackPatch: Decodable, Sendable {
    public var isPaused: Bool?
    public var title: String?
    public var artist: String?
    public var album: String?
    public var elapsedSeconds: Double?
    public var songDuration: Double?
    public var imageSrc: String?
    public var repeatMode: Int?
    public var isShuffled: Bool?
    public var volume: Double?
    public var videoId: String?
    public var clearedFields: Set<YouTubePlaybackField>
    public init(isPaused: Bool? = nil, title: String? = nil, artist: String? = nil, album: String? = nil,
                elapsedSeconds: Double? = nil, songDuration: Double? = nil, imageSrc: String? = nil,
                repeatMode: Int? = nil, isShuffled: Bool? = nil, volume: Double? = nil, videoId: String? = nil,
                clearedFields: Set<YouTubePlaybackField> = []) {
        self.isPaused = isPaused; self.title = title; self.artist = artist; self.album = album
        self.elapsedSeconds = elapsedSeconds; self.songDuration = songDuration; self.imageSrc = imageSrc
        self.repeatMode = repeatMode; self.isShuffled = isShuffled; self.volume = volume; self.videoId = videoId
        self.clearedFields = clearedFields
    }
    private enum CodingKeys: String, CodingKey { case isPaused, title, alternativeTitle, artist, album, elapsedSeconds, songDuration, imageSrc, repeatMode, isShuffled, volume, videoId }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isPaused: try c.decodeIfPresent(Bool.self, forKey: .isPaused),
                  title: try c.decodeIfPresent(String.self, forKey: .title) ?? c.decodeIfPresent(String.self, forKey: .alternativeTitle),
                  artist: try c.decodeIfPresent(String.self, forKey: .artist), album: try c.decodeIfPresent(String.self, forKey: .album),
                  elapsedSeconds: try c.decodeIfPresent(Double.self, forKey: .elapsedSeconds),
                  songDuration: try c.decodeIfPresent(Double.self, forKey: .songDuration),
                  imageSrc: try c.decodeIfPresent(String.self, forKey: .imageSrc), repeatMode: try c.decodeIfPresent(Int.self, forKey: .repeatMode),
                  isShuffled: try c.decodeIfPresent(Bool.self, forKey: .isShuffled), volume: try c.decodeIfPresent(Double.self, forKey: .volume),
                  videoId: try c.decodeIfPresent(String.self, forKey: .videoId))
        for (key, field) in [(CodingKeys.title, YouTubePlaybackField.title), (.artist, .artist), (.album, .album), (.imageSrc, .imageSrc), (.videoId, .videoId)] {
            if c.contains(key), try c.decodeNil(forKey: key) { clearedFields.insert(field) }
        }
    }
    public static func socketMessage(_ data: Data) -> Self? {
        guard data.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard let type = root["type"] as? String else { return try? JSONDecoder().decode(Self.self, from: data) }
        let supported = ["PLAYER_INFO", "VIDEO_CHANGED", "PLAYER_STATE_CHANGED", "POSITION_CHANGED", "VOLUME_CHANGED", "REPEAT_CHANGED", "SHUFFLE_CHANGED"]
        guard supported.contains(type) else { return nil }
        if root["song"] is NSNull, ["PLAYER_INFO", "VIDEO_CHANGED"].contains(type) {
            return Self(isPaused: true, elapsedSeconds: 0, songDuration: 0,
                clearedFields: [.title, .artist, .album, .imageSrc, .videoId])
        }
        let song = root["song"] as? [String: Any] ?? [:]
        var flat = song
        for key in ["title", "artist", "album", "imageSrc", "songDuration", "volume", "videoId", "isPaused", "isShuffled", "elapsedSeconds", "repeatMode"] where root[key] != nil { flat[key] = root[key] }
        if flat["title"] == nil { flat["title"] = song["alternativeTitle"] }
        if let playing = root["isPlaying"] as? Bool { flat["isPaused"] = !playing }
        if let position = root["position"] { flat["elapsedSeconds"] = position }
        if let shuffled = root["shuffle"] { flat["isShuffled"] = shuffled }
        if let repeated = (root["repeat"] ?? song["repeat"]) as? String {
            flat["repeatMode"] = ["NONE": 0, "ALL": 1, "ONE": 2][repeated.uppercased()]
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject: flat) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: normalized)
    }
}

public protocol YouTubeMusicClock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}
public struct SystemYouTubeMusicClock: YouTubeMusicClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        let value = seconds.isFinite ? min(300, max(0.01, seconds)) : 1
        try await Task.sleep(for: .seconds(value))
    }
}
public protocol YouTubeMusicEnvironment: Sendable {
    func isRunning() async -> Bool
    func launch() async
}
public protocol YouTubeArtworkLoading: Sendable { func fetch(from url: URL) async throws -> Data }
