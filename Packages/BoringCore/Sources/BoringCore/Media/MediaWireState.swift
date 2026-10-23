import Foundation

public enum MediaWireValue: Decodable, Equatable, Sendable {
    case string(String), number(Double), boolean(Bool), null, unsupported
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Bool.self) { self = .boolean(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else { self = .unsupported }
    }
}

public struct MediaWireUpdate: Decodable, Sendable {
    public let payload: [String: MediaWireValue]
    public let diff: Bool?
    public init(payload: [String: MediaWireValue], diff: Bool = true) { self.payload = payload; self.diff = diff }
}

public extension Dictionary where Key == String, Value == MediaWireValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }; return value
    }
    func number(_ key: String) -> Double? {
        guard case .number(let value) = self[key], value.isFinite else { return nil }; return value
    }
    func boolean(_ key: String) -> Bool? {
        guard case .boolean(let value) = self[key] else { return nil }; return value
    }
}

/// Pure, shared adapter reducer. A missing key is unchanged; null removes the key.
/// Parent and helper owner fields are resolved only after applying the entire patch.
public struct MediaWireState: Sendable {
    public private(set) var payload: [String: MediaWireValue] = [:]
    public init() {}
    public mutating func reset() { payload.removeAll() }
    public mutating func apply(_ update: MediaWireUpdate) {
        if update.diff != true { payload.removeAll() }
        for (key, value) in update.payload {
            if case .null = value { payload.removeValue(forKey: key) }
            else { payload[key] = value }
        }
    }
    public var owner: String? {
        let parent = payload.string("parentApplicationBundleIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        return parent ?? payload.string("bundleIdentifier").flatMap { $0.isEmpty ? nil : $0 }
    }

    public func playbackState(applying update: MediaWireUpdate, previous: MediaPlaybackState, now: Date) -> MediaPlaybackState {
        let patch = update.payload
        let diff = update.diff == true
        var state = previous
        state.bundleIdentifier = owner ?? ""
        state.title = payload.string("title") ?? ""
        state.artist = payload.string("artist") ?? ""
        state.album = payload.string("album") ?? ""
        state.duration = max(0, payload.number("duration") ?? 0)
        // MediaRemote's opaque content/queue identifiers are not source API track IDs. Only
        // a source adapter (for example a trusted Yandex track link) may establish that ID.
        let sameMetadata = state.bundleIdentifier == previous.bundleIdentifier
            && !state.title.isEmpty && MediaText.normalized(state.title) == MediaText.normalized(previous.title)
            && MediaText.normalized(state.artist) == MediaText.normalized(previous.artist)
            && (state.album.isEmpty || previous.album.isEmpty || state.album == previous.album)
            && (state.duration <= 0 || previous.duration <= 0 || abs(state.duration - previous.duration) <= 5)
        state.nativeTrackID = sameMetadata ? previous.nativeTrackID : nil
        state.lastUpdated = patch.string("timestamp").flatMap(Self.date) ?? (diff ? previous.lastUpdated : now)
        if let position = patch.number("elapsedTime") { state.currentTime = max(0, position) }
        else if !diff || patch["elapsedTime"] != nil { state.currentTime = 0 }
        else { state.currentTime = previous.timeline.position(at: state.lastUpdated) }
        state.isPlaying = payload.boolean("playing") ?? false
        state.playbackRate = max(0, payload.number("playbackRate") ?? 1)
        state.volume = min(1, max(0, payload.number("volume") ?? 0.5))
        if let shuffle = payload.number("shuffleMode") { state.isShuffled = shuffle != 1 }
        else if patch["shuffleMode"] != nil { state.isShuffled = false }
        if let repeatValue = payload.number("repeatMode"), let value = Int(exactly: repeatValue) {
            state.repeatMode = MediaRepeatMode(rawValue: value) ?? .off
        }
        else if patch["repeatMode"] != nil { state.repeatMode = .off }
        if let liked = payload.boolean("isLiked") { state.isFavorite = liked }
        else if patch["isLiked"] != nil || state.identity != previous.identity { state.isFavorite = false }
        if patch["artworkData"] != nil || !diff || state.identity != previous.identity
            || (previous.artwork == nil && payload["artworkData"] != nil) {
            if let encoded = payload.string("artworkData") {
                state.artwork = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if patch["artworkData"] != nil || state.identity != previous.identity { state.artwork = nil }
        } else if payload["artworkData"] == nil && state.identity != previous.identity { state.artwork = nil }
        return state
    }

    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

public struct JSONLinesFramer: Sendable {
    public enum FramingError: Error, Sendable { case lineTooLarge }
    private var buffer = Data()
    public let maximumLineBytes: Int
    public var bufferedByteCount: Int { buffer.count }
    public init(maximumLineBytes: Int = 16 * 1024 * 1024) { self.maximumLineBytes = maximumLineBytes }
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= maximumLineBytes else {
                buffer.removeAll(); throw FramingError.lineTooLarge
            }
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            if !line.isEmpty { lines.append(line) }
        }
        guard buffer.count <= maximumLineBytes else { buffer.removeAll(); throw FramingError.lineTooLarge }
        return lines
    }
    public mutating func finish() -> Data? {
        defer { buffer.removeAll() }; return buffer.isEmpty ? nil : buffer
    }
}
