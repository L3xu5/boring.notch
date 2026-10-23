import Foundation

// Production state comparison and async callbacks are inserted by test_music_metadata.py.
// Only image decoding/color extraction and UI side effects are fixtures, allowing deterministic
// reversed completion order without launching an AppKit app or relying on image sizes/timings.
// PRODUCTION_PLAYBACK_STATE

struct NSColor: Equatable {
    let name: String
    static let white = NSColor(name: "white")
}
final class NSImage {
    let name: String
    static let lock = NSLock()
    static var decoding = Set<String>()
    init(_ name: String) { self.name = name }
    convenience init?(data: Data) {
        let name = String(data: data, encoding: .utf8)!
        Self.lock.lock(); Self.decoding.insert(name); Self.lock.unlock()
        if name.hasPrefix("slow") { Thread.sleep(forTimeInterval: 0.15) }
        if name == "invalid" { return nil }
        self.init(name)
    }
    static func beganDecoding(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return decoding.contains(name)
    }
    func averageColor(_ callback: @escaping (NSColor?) -> Void) {
        ColorFixture.pending[name] = callback
    }
}
enum ColorFixture { static var pending: [String: (NSColor?) -> Void] = [:] }
let defaultImage = NSImage("default")
func AppIconAsNSImage(for bundle: String) -> NSImage? { bundle.isEmpty ? nil : NSImage("icon:" + bundle) }
enum FixtureAnimation { case smooth }
func withAnimation(_: FixtureAnimation, _ body: () -> Void) { body() }
enum Defaults {
    enum Key { case coloredSpectrogram }
    static subscript(_: Key) -> Bool { false }
}
final class FixtureController { var supportsVolumeControl = true }

class MusicManager {
    var songTitle = "Initial"
    var artistName = "Initial Artist"
    var album = "Initial Album"
    var bundleIdentifier: String? = nil
    var artworkData: Data?
    var artworkRequestID = UUID()
    var albumArt = defaultImage
    var avgColor = NSColor.white
    var isPlaying = false
    var usingAppIconForArtwork = false
    var elapsedTime = 0.0
    var songDuration = 0.0
    var playbackRate = 1.0
    var isShuffled = false
    var repeatMode = RepeatMode.off
    var volume = 0.5
    var volumeControlSupported = false
    var isFavoriteTrack = false
    var timestampDate = Date.distantPast
    var activeController: FixtureController? = FixtureController()
    var workItem: DispatchWorkItem?
    var flips = 0
    private func triggerFlipAnimation() { flips += 1 }
    private func updateIdleState(state: Bool) {}
    private func updateSneakPeek() {}
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String,
                                        album: String, duration: Double) {}
    // PRODUCTION_METADATA_METHODS
}

extension MusicManager {
    @MainActor func apply(_ state: PlaybackState) { updateFromPlaybackState(state) }
}
struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
@MainActor func eventually(_ message: String, _ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestFailure(description: "Timed out: " + message)
}

@main struct MusicMetadataRegressionTests {
    static func state(_ title: String, artwork: String?) -> PlaybackState {
        var state = PlaybackState(bundleIdentifier: "fixture.player")
        state.title = title
        state.artist = "Artist " + title
        state.album = "Album " + title
        state.duration = 200
        state.artwork = artwork.map { Data($0.utf8) }
        return state
    }
    @MainActor static func main() async throws {
        try await metadataWithSharedCover()
        try await staleArtworkDecode()
        try await missingArtworkCancelsOldDecode()
        try await invalidArtworkUsesFallback()
        try await staleColorCallback()
        print("5 music metadata regression scenarios passed")
    }
    @MainActor static func metadataWithSharedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("A", artwork: "shared-cover"))
        try await eventually("initial cover") { manager.albumArt.name == "shared-cover" }
        manager.apply(state("B", artwork: "shared-cover"))
        let flips = manager.flips
        var progress = state("B", artwork: "shared-cover")
        progress.currentTime = 1
        manager.apply(progress)
        try expect(manager.songTitle == "B" && manager.artistName == "Artist B" && manager.album == "Album B", "Metadata did not advance when artwork bytes stayed the same")
        try expect(manager.flips == flips, "An unchanged progress tick retriggered the track transition")
    }
    @MainActor static func staleArtworkDecode() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "slow-old-cover"))
        try await eventually("old decode started") { NSImage.beganDecoding("slow-old-cover") }
        manager.apply(state("New", artwork: "new-cover"))
        try await eventually("new cover applied") { manager.albumArt.name == "new-cover" }
        try await Task.sleep(for: .milliseconds(200))
        try expect(manager.albumArt.name == "new-cover" && manager.songTitle == "New", "A late previous-track decode replaced the current cover")
    }
    @MainActor static func missingArtworkCancelsOldDecode() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "slow-before-nil"))
        try await eventually("decode before missing artwork") { NSImage.beganDecoding("slow-before-nil") }
        manager.apply(state("New", artwork: nil))
        try expect(manager.albumArt.name == "icon:fixture.player" && manager.usingAppIconForArtwork, "Missing artwork did not clear the previous cover")
        try await Task.sleep(for: .milliseconds(200))
        try expect(manager.albumArt.name == "icon:fixture.player", "A stale decode replaced the new track's icon fallback")
    }
    @MainActor static func invalidArtworkUsesFallback() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "valid-cover"))
        try await eventually("valid cover") { manager.albumArt.name == "valid-cover" }
        manager.apply(state("New", artwork: "invalid"))
        try await eventually("invalid-image fallback") { manager.albumArt.name == "icon:fixture.player" }
        try expect(manager.songTitle == "New", "Image decoding failure blocked track metadata")
    }
    @MainActor static func staleColorCallback() async throws {
        let manager = MusicManager()
        ColorFixture.pending = [:]
        manager.updateAlbumArt(newAlbumArt: NSImage("old-image"))
        manager.calculateAverageColor()
        manager.updateAlbumArt(newAlbumArt: NSImage("new-image"))
        manager.calculateAverageColor()
        ColorFixture.pending["new-image"]?(NSColor(name: "blue"))
        try await eventually("new image color") { manager.avgColor.name == "blue" }
        ColorFixture.pending["old-image"]?(NSColor(name: "red"))
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.avgColor.name == "blue", "An old image's color callback replaced the current tint")
    }
}
