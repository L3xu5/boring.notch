import BoringCore

// Native integration keeps its established configuration/model names. Wire parsing and
// lifecycle semantics live in the strict Swift core, rather than an AppKit observable client.
typealias YouTubeMusicConfiguration = BoringCore.YouTubeMusicConfiguration
typealias PlaybackResponse = BoringCore.YouTubePlaybackPatch
typealias AuthResponse = BoringCore.YouTubeAuthResponse
typealias YouTubeMusicError = BoringCore.YouTubeMusicError
