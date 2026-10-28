import AppKit
import BoringCore
import Foundation
import ImageIO

typealias PlaybackState = MediaPlaybackState

@MainActor
enum ImageFixtures {
    static var images: [String: NSImage] = [:]
    static var decoding = Set<String>()
    static var colors: [ObjectIdentifier: (NSColor?) -> Void] = [:]
    static func image(_ name: String) -> NSImage {
        if let image = images[name] { return image }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        images[name] = image
        return image
    }
    static func decode(_ data: Data) async -> NSImage? {
        let name = String(data: data, encoding: .utf8)!
        decoding.insert(name)
        if name.hasPrefix("slow") {
            // Deliberately ignore cancellation to model an already-running native decoder.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() }
            }
        }
        return name == "invalid" ? nil : image(name)
    }
}

@MainActor
final class MusicManager {
    private let presentation = ArtworkPresentationService(defaultImage: ImageFixtures.image("default"),
        icon: { $0.isEmpty ? nil : ImageFixtures.image("icon:" + $0) }, colorEnabled: { false },
        decode: ImageFixtures.decode, sampleColor: { image, callback in ImageFixtures.colors[ObjectIdentifier(image)] = callback })
    private var state: PlaybackState?
    var flips = 0
    var songTitle: String { state?.title ?? "" }
    var artistName: String { state?.artist ?? "" }
    var album: String { state?.album ?? "" }
    var albumArt: NSImage { presentation.image }
    var usingAppIconForArtwork: Bool { presentation.usesApplicationIcon }
    var avgColor: NSColor { presentation.color }
    func apply(_ next: PlaybackState) {
        if MediaContentChange.hasChanged(from: state, to: next) { flips += 1 }
        state = next
        presentation.apply(data: next.artwork, bundleIdentifier: next.bundleIdentifier, identity: next.identity)
    }
    func updateAlbumArt(newAlbumArt: NSImage) { presentation.setImage(newAlbumArt) }
    func calculateAverageColor() { presentation.calculateAverageColor() }
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
        state.title = title; state.artist = "Artist " + title; state.album = "Album " + title
        state.duration = 200; state.artwork = artwork.map { Data($0.utf8) }
        return state
    }
    @MainActor static func main() async throws {
        try await metadataWithSharedCover()
        try await changedTrackClearsDecodedCover()
        try await sameTrackQualityKeepsDecodedCover()
        try await staleArtworkDecode()
        try await missingArtworkCancelsOldDecode()
        try await invalidArtworkUsesFallback()
        try await staleColorCallback()
        try await boundedProductionDecoder()
        print("8 music metadata regression scenarios passed (actual service/Core; real AppKit image values)")
    }
    @MainActor static func metadataWithSharedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("A", artwork: "shared-cover"))
        try await eventually("initial cover") { manager.albumArt === ImageFixtures.image("shared-cover") }
        manager.apply(state("B", artwork: "shared-cover"))
        let flips = manager.flips
        var progress = state("B", artwork: "shared-cover"); progress.currentTime = 1
        manager.apply(progress)
        try expect(manager.songTitle == "B" && manager.artistName == "Artist B" && manager.album == "Album B", "Shared cover prevented metadata advance")
        try expect(manager.flips == flips, "Progress tick retriggered content transition")
    }
    @MainActor static func changedTrackClearsDecodedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("Old decoded", artwork: "old-decoded-cover"))
        try await eventually("old decoded cover") { manager.albumArt === ImageFixtures.image("old-decoded-cover") }
        manager.apply(state("New pending", artwork: "slow-new-track-cover"))
        try expect(manager.songTitle == "New pending" && manager.albumArt === ImageFixtures.image("icon:fixture.player"),
                   "A new title was temporarily paired with the preceding track's decoded cover")
        try await eventually("new track decoded") { manager.albumArt === ImageFixtures.image("slow-new-track-cover") }
        manager.apply(state("Shared next", artwork: "slow-new-track-cover"))
        try expect(manager.albumArt === ImageFixtures.image("slow-new-track-cover") && !manager.usingAppIconForArtwork,
                   "A shared album cover flashed a placeholder on a track change")
    }
    @MainActor static func sameTrackQualityKeepsDecodedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("Same track", artwork: "small-cover"))
        try await eventually("small decoded cover") { manager.albumArt === ImageFixtures.image("small-cover") }
        manager.apply(state("Same track", artwork: "slow-large-cover"))
        try expect(manager.albumArt === ImageFixtures.image("small-cover"),
                   "A same-track image update flashed a placeholder before decoding")
        try await eventually("large cover decoded") { manager.albumArt === ImageFixtures.image("slow-large-cover") }
    }
    @MainActor static func staleArtworkDecode() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "slow-old-cover"))
        try await eventually("old decode started") { ImageFixtures.decoding.contains("slow-old-cover") }
        manager.apply(state("New", artwork: "new-cover"))
        try await eventually("new cover applied") { manager.albumArt === ImageFixtures.image("new-cover") }
        try await Task.sleep(for: .milliseconds(200))
        try expect(manager.albumArt === ImageFixtures.image("new-cover") && manager.songTitle == "New", "Late decode replaced current cover")
    }
    @MainActor static func missingArtworkCancelsOldDecode() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "slow-before-nil"))
        try await eventually("decode before nil") { ImageFixtures.decoding.contains("slow-before-nil") }
        manager.apply(state("New", artwork: nil))
        try expect(manager.albumArt === ImageFixtures.image("icon:fixture.player") && manager.usingAppIconForArtwork, "Missing cover did not use app icon")
        try await Task.sleep(for: .milliseconds(200))
        try expect(manager.albumArt === ImageFixtures.image("icon:fixture.player"), "Stale decoder replaced app icon")
    }
    @MainActor static func invalidArtworkUsesFallback() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "valid-cover"))
        try await eventually("valid cover") { manager.albumArt === ImageFixtures.image("valid-cover") }
        manager.apply(state("New", artwork: "invalid"))
        try await eventually("invalid image fallback") { manager.albumArt === ImageFixtures.image("icon:fixture.player") }
        try expect(manager.songTitle == "New", "Decoder failure blocked metadata")
    }
    @MainActor static func staleColorCallback() async throws {
        let manager = MusicManager()
        let old = ImageFixtures.image("old-image"), new = ImageFixtures.image("new-image")
        ImageFixtures.colors = [:]
        manager.updateAlbumArt(newAlbumArt: old); manager.calculateAverageColor()
        manager.updateAlbumArt(newAlbumArt: new); manager.calculateAverageColor()
        ImageFixtures.colors[ObjectIdentifier(new)]?(.blue)
        try await eventually("new image color") { manager.avgColor == .blue }
        ImageFixtures.colors[ObjectIdentifier(old)]?(.red)
        try await Task.sleep(for: .milliseconds(20))
        try expect(manager.avgColor == .blue, "Late color callback replaced current tint")
    }
    @MainActor static func boundedProductionDecoder() async throws {
        let context = CGContext(data: nil, width: 4096, height: 16, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 16))
        let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        let fallback = ImageFixtures.image("default-decoder-fallback")
        let service = ArtworkPresentationService(defaultImage: fallback, icon: { _ in nil }, colorEnabled: { false })
        service.apply(data: data, bundleIdentifier: "fixture")
        try await eventually("production thumbnail decoder") { service.image !== fallback }
        let decoded = service.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        try expect(decoded != nil && decoded!.width <= 1024, "Album artwork was decoded at its unbounded original pixel dimensions")
    }
}
