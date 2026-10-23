import Foundation

public enum MediaRepeatMode: Int, Codable, Sendable {
    case off = 1, one = 2, all = 3
}

/// A timeline is an anchor, its observation time and a rate. Unknown duration must not clamp
/// a valid position to zero. Platform adapters normalize their clocks at this boundary.
public struct MediaTimeline: Equatable, Sendable {
    public var position: TimeInterval
    public var duration: TimeInterval
    public var observedAt: Date
    public var rate: Double
    public var isPlaying: Bool

    public init(position: Double, duration: Double, observedAt: Date, rate: Double, isPlaying: Bool) {
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.observedAt = observedAt
        self.rate = rate.isFinite ? max(0, rate) : 0
        self.isPlaying = isPlaying
    }

    public func position(at date: Date) -> TimeInterval {
        let advance = isPlaying ? max(0, date.timeIntervalSince(observedAt)) * rate : 0
        let result = max(0, position + advance)
        return duration > 0 ? min(result, duration) : result
    }
}

public struct MediaItemIdentity: Hashable, Codable, Sendable {
    public var source: String
    public var nativeID: String?
    public var title: String
    public var artist: String
    public var album: String
    public init(source: String, nativeID: String? = nil, title: String, artist: String, album: String) {
        self.source = source; self.nativeID = nativeID
        self.title = title; self.artist = artist; self.album = album
    }
}

public struct MediaCapabilities: Equatable, Sendable {
    public var volume: Bool
    public var favorite: Bool
    public var dislike: Bool
    public var seek: Bool
    public var shuffle: Bool
    public var repeatMode: Bool
    public init(volume: Bool = false, favorite: Bool = false, dislike: Bool = false,
                seek: Bool = true, shuffle: Bool = true, repeatMode: Bool = true) {
        self.volume = volume; self.favorite = favorite; self.dislike = dislike
        self.seek = seek; self.shuffle = shuffle; self.repeatMode = repeatMode
    }
}

/// Complete equality is intentional. Presentation layers may suppress their own redraws,
/// but a volume/rate/anchor-only event must still update the underlying playback state.
public struct MediaPlaybackState: Equatable, Sendable {
    public var bundleIdentifier: String
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var album: String
    public var currentTime: TimeInterval
    public var duration: TimeInterval
    public var playbackRate: Double
    public var isShuffled: Bool
    public var repeatMode: MediaRepeatMode
    public var lastUpdated: Date
    public var artwork: Data?
    public var volume: Double
    public var isFavorite: Bool
    public var nativeTrackID: String?

    public init(bundleIdentifier: String, isPlaying: Bool = false, title: String = "", artist: String = "",
                album: String = "", currentTime: TimeInterval = 0, duration: TimeInterval = 0,
                playbackRate: Double = 1, isShuffled: Bool = false, repeatMode: MediaRepeatMode = .off,
                lastUpdated: Date = .distantPast, artwork: Data? = nil, volume: Double = 0.5,
                isFavorite: Bool = false, nativeTrackID: String? = nil) {
        self.bundleIdentifier = bundleIdentifier; self.isPlaying = isPlaying
        self.title = title; self.artist = artist; self.album = album
        self.currentTime = currentTime; self.duration = duration; self.playbackRate = playbackRate
        self.isShuffled = isShuffled; self.repeatMode = repeatMode; self.lastUpdated = lastUpdated
        self.artwork = artwork; self.volume = volume; self.isFavorite = isFavorite
        self.nativeTrackID = nativeTrackID
    }

    public var identity: MediaItemIdentity {
        .init(source: bundleIdentifier, nativeID: nativeTrackID, title: title, artist: artist, album: album)
    }
    public var timeline: MediaTimeline {
        .init(position: currentTime, duration: duration, observedAt: lastUpdated,
              rate: playbackRate, isPlaying: isPlaying)
    }
}
