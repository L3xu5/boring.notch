import Foundation

/// Progress, volume and clock ticks are playback events, not new artwork/track transitions.
public enum MediaContentChange {
    public static func hasChanged(from previous: MediaPlaybackState?, to next: MediaPlaybackState) -> Bool {
        guard let previous else { return true }
        return previous.identity != next.identity || previous.artwork != next.artwork
            || previous.artworkItemIdentifier != next.artworkItemIdentifier
    }
}
