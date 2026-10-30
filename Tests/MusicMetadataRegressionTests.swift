import AppKit
import BoringCore
import Foundation
import ImageIO

typealias PlaybackState = MediaPlaybackState

@MainActor
enum ImageFixtures {
    static var images: [String: NSImage] = [:]
    static var decoding = Set<String>()
    static var completed: [String: Int] = [:]
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
        completed[name, default: 0] += 1
        return name == "invalid" ? nil : image(name)
    }
}

@MainActor
final class MusicManager {
    private let presentation = ArtworkPresentationService(defaultImage: ImageFixtures.image("default"),
        colorEnabled: { false },
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
        presentation.apply(data: next.artwork, bundleIdentifier: next.bundleIdentifier, identity: next.identity,
                           artworkItemIdentifier: next.artworkItemIdentifier)
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
        try await pauseAndDecodeFailureKeepTheCurrentCover()
        try await nilOnNextItemCannotReuseRetainedCover()
        try await pendingBytesCannotReuseAnotherItemsDecodedCover()
        try await sameTextNewRecordingCannotReuseRetainedCover()
        try await partialMetadataCannotForgetDecodedAssociation()
        try await sourceChangesClearDecodedAssociation()
        try await stoppingRejectsAnUncancelableDecode()
        try await sharedBytesCannotForgetDecodedAssociation()
        try await qualityCompletionCannotForgetDecodedAssociation()
        try await sameItemNilKeepsPendingDecode()
        try await pendingRefinementsDoNotRestartDecode()
        try await pendingRefinementsPreserveRecordingProof()
        print("20 music metadata regression scenarios passed (actual service/Core; real AppKit image values)")
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
        try expect(manager.songTitle == "New pending" && manager.albumArt === ImageFixtures.image("default"),
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
        try expect(manager.albumArt === ImageFixtures.image("default") && !manager.usingAppIconForArtwork, "Missing new cover did not use a neutral placeholder")
        try await Task.sleep(for: .milliseconds(200))
        try expect(manager.albumArt === ImageFixtures.image("default"), "Stale decoder replaced the current placeholder")
    }
    @MainActor static func invalidArtworkUsesFallback() async throws {
        let manager = MusicManager()
        manager.apply(state("Old", artwork: "valid-cover"))
        try await eventually("valid cover") { manager.albumArt === ImageFixtures.image("valid-cover") }
        manager.apply(state("New", artwork: "invalid"))
        try await eventually("invalid image fallback") { manager.albumArt === ImageFixtures.image("default") }
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
        let service = ArtworkPresentationService(defaultImage: fallback, colorEnabled: { false })
        service.apply(data: data, bundleIdentifier: "fixture")
        try await eventually("production thumbnail decoder") { service.image !== fallback }
        let decoded = service.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        try expect(decoded != nil && decoded!.width <= 1024, "Album artwork was decoded at its unbounded original pixel dimensions")
    }

    @MainActor static func pauseAndDecodeFailureKeepTheCurrentCover() async throws {
        let manager = MusicManager()
        var track = state("Paused", artwork: "pause-cover")
        track.isPlaying = true; track.artworkItemIdentifier = "item A"
        manager.apply(track)
        try await eventually("pause cover") { manager.albumArt === ImageFixtures.image("pause-cover") }
        track.isPlaying = false; track.playbackRate = 0; track.artwork = nil
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("pause-cover") && !manager.usingAppIconForArtwork,
                   "A paused same-item artwork removal replaced the verified cover")
        let completed = ImageFixtures.completed["invalid", default: 0]
        track.artwork = Data("invalid".utf8)
        manager.apply(track)
        try await eventually("failed same-item decode") { ImageFixtures.completed["invalid", default: 0] > completed }
        try expect(manager.albumArt === ImageFixtures.image("pause-cover"), "A failed same-item quality decode erased its cover")
        track.isPlaying = true; track.playbackRate = 1; track.artwork = Data("pause-cover".utf8)
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("pause-cover"), "Resume flashed a placeholder for an already-decoded cover")
    }

    @MainActor static func nilOnNextItemCannotReuseRetainedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("A", artwork: "nil-transition-cover"))
        try await eventually("nil transition cover") { manager.albumArt === ImageFixtures.image("nil-transition-cover") }
        manager.apply(state("A", artwork: nil))
        try expect(manager.albumArt === ImageFixtures.image("nil-transition-cover"), "Same-item nil discarded its cover")
        manager.apply(state("B", artwork: nil))
        try expect(manager.albumArt === ImageFixtures.image("default") && !manager.usingAppIconForArtwork,
                   "Consecutive nil artwork attached A's cover or an application logo to B")
    }

    @MainActor static func pendingBytesCannotReuseAnotherItemsDecodedCover() async throws {
        let manager = MusicManager()
        manager.apply(state("A", artwork: "quality-before-change"))
        try await eventually("quality before change") { manager.albumArt === ImageFixtures.image("quality-before-change") }
        manager.apply(state("A", artwork: "slow-shared-pending-quality"))
        try await eventually("quality decode started") { ImageFixtures.decoding.contains("slow-shared-pending-quality") }
        manager.apply(state("B", artwork: "slow-shared-pending-quality"))
        try expect(manager.albumArt === ImageFixtures.image("default"),
                   "Requested-byte equality attached an earlier decoded cover to a different item")
        try await eventually("shared pending quality decoded") { manager.albumArt === ImageFixtures.image("slow-shared-pending-quality") }
        manager.apply(state("C", artwork: "slow-shared-pending-quality"))
        try expect(manager.albumArt === ImageFixtures.image("slow-shared-pending-quality"), "Verified shared cover flashed a placeholder")
    }

    @MainActor static func sameTextNewRecordingCannotReuseRetainedCover() async throws {
        let manager = MusicManager()
        var track = state("Same text", artwork: "recording-cover")
        track.artworkItemIdentifier = "opaque A"
        manager.apply(track)
        try await eventually("recording cover") { manager.albumArt === ImageFixtures.image("recording-cover") }
        track.artwork = nil
        manager.apply(track)
        let flips = manager.flips
        track.artworkItemIdentifier = "opaque B"
        manager.apply(track)
        try expect(manager.flips == flips + 1 && manager.albumArt === ImageFixtures.image("default"),
                   "The facade ignored a new recording with the same text and missing artwork")
    }

    @MainActor static func partialMetadataCannotForgetDecodedAssociation() async throws {
        for boundary in ["opaque", "native", "album"] {
            let manager = MusicManager()
            var track = state("Partial", artwork: "partial-proof-" + boundary)
            if boundary == "native" { track.nativeTrackID = "123" }
            if boundary == "opaque" { track.artworkItemIdentifier = "opaque A" }
            manager.apply(track)
            try await eventually("partial proof cover") { manager.albumArt === ImageFixtures.image("partial-proof-" + boundary) }
            track.artwork = nil; track.nativeTrackID = nil; track.artworkItemIdentifier = nil; track.album = ""
            manager.apply(track)
            try expect(manager.albumArt === ImageFixtures.image("partial-proof-" + boundary), "A partial same-item refinement erased its cover")
            switch boundary {
            case "opaque": track.artworkItemIdentifier = "opaque B"
            case "native": track.nativeTrackID = "456"
            default: track.album = "Different album"
            }
            manager.apply(track)
            try expect(manager.albumArt === ImageFixtures.image("default"),
                       "A missing field forgot the earlier \(boundary) proof and allowed another item to reuse its cover")
        }
    }

    @MainActor static func sourceChangesClearDecodedAssociation() async throws {
        let manager = MusicManager()
        var track = state("Source", artwork: "same-source-bytes")
        manager.apply(track)
        try await eventually("source cover") { manager.albumArt === ImageFixtures.image("same-source-bytes") }
        track.bundleIdentifier = "another.player"
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("default"), "A new source inherited another source's decoded association")
        try await eventually("new source decodes its own bytes") { manager.albumArt === ImageFixtures.image("same-source-bytes") }
    }

    @MainActor static func sharedBytesCannotForgetDecodedAssociation() async throws {
        let manager = MusicManager()
        var track = state("Shared proof", artwork: "shared-proof-cover")
        track.nativeTrackID = "123"; track.artworkItemIdentifier = "opaque A"
        manager.apply(track)
        try await eventually("shared proof cover") { manager.albumArt === ImageFixtures.image("shared-proof-cover") }
        track.nativeTrackID = nil; track.artworkItemIdentifier = nil; track.album = ""
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("shared-proof-cover"), "Same-item shared bytes flashed a placeholder")
        track.artwork = nil; track.nativeTrackID = "456"; track.artworkItemIdentifier = "opaque B"
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("default"), "Shared bytes discarded the earlier recording proof")
    }

    @MainActor static func qualityCompletionCannotForgetDecodedAssociation() async throws {
        let manager = MusicManager()
        var track = state("Quality proof", artwork: "quality-proof-small")
        track.nativeTrackID = "123"; track.artworkItemIdentifier = "opaque A"
        manager.apply(track)
        try await eventually("quality proof cover") { manager.albumArt === ImageFixtures.image("quality-proof-small") }
        track.nativeTrackID = nil; track.artworkItemIdentifier = nil; track.album = ""
        track.artwork = Data("slow-quality-proof-large".utf8)
        manager.apply(track)
        try await eventually("quality proof upgrade") { manager.albumArt === ImageFixtures.image("slow-quality-proof-large") }
        track.artwork = nil; track.nativeTrackID = "456"; track.artworkItemIdentifier = "opaque B"
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("default"), "A quality decode discarded the earlier recording proof")
    }

    @MainActor static func stoppingRejectsAnUncancelableDecode() async throws {
        let placeholder = ImageFixtures.image("stop-placeholder")
        let service = ArtworkPresentationService(defaultImage: placeholder, colorEnabled: { false }, decode: ImageFixtures.decode)
        let old = state("Old stop", artwork: "slow-stop-cover")
        service.apply(data: old.artwork, bundleIdentifier: old.bundleIdentifier, identity: old.identity)
        try await eventually("stop decode started") { ImageFixtures.decoding.contains("slow-stop-cover") }
        service.stop()
        let new = state("New stop", artwork: nil)
        service.apply(data: nil, bundleIdentifier: new.bundleIdentifier, identity: new.identity)
        try await Task.sleep(for: .milliseconds(200))
        try expect(service.image === placeholder && !service.usesApplicationIcon, "A stopped decoder restored an old cover")
    }

    @MainActor static func sameItemNilKeepsPendingDecode() async throws {
        let manager = MusicManager()
        var track = state("Pending pause", artwork: "slow-pause-before-decode")
        track.artworkItemIdentifier = "pending pause"
        manager.apply(track)
        try await eventually("pause decode started") { ImageFixtures.decoding.contains("slow-pause-before-decode") }
        track.artwork = nil; track.isPlaying = false; track.playbackRate = 0
        manager.apply(track)
        try await eventually("paused cover completes without another artwork event") {
            manager.albumArt === ImageFixtures.image("slow-pause-before-decode")
        }
    }

    @MainActor static func pendingRefinementsDoNotRestartDecode() async throws {
        let manager = MusicManager()
        let name = "slow-pending-refinements"
        let completed = ImageFixtures.completed[name, default: 0]
        var track = state("Pending refinement", artwork: name)
        manager.apply(track)
        try await eventually("refinement decode started") { ImageFixtures.decoding.contains(name) }
        track.nativeTrackID = "123"
        manager.apply(track)
        track.artworkItemIdentifier = "pending recording"
        manager.apply(track)
        track.album = ""
        manager.apply(track)
        track.artwork = nil
        manager.apply(track)
        try await eventually("refined pending cover completes") { manager.albumArt === ImageFixtures.image(name) }
        try expect(ImageFixtures.completed[name, default: 0] == completed + 1,
                   "Same-item metadata refinements restarted the pending image decoder")
        track.artworkItemIdentifier = "another recording"
        manager.apply(track)
        try expect(manager.albumArt === ImageFixtures.image("default"),
                   "A coalesced decode forgot the recording proof supplied while decoding")
    }

    @MainActor static func pendingRefinementsPreserveRecordingProof() async throws {
        for boundary in ["opaque", "native", "album", "source"] {
            let manager = MusicManager()
            let name = "slow-pending-proof-" + boundary
            var track = state("Pending proof", artwork: name)
            track.nativeTrackID = "123"; track.artworkItemIdentifier = "opaque A"
            manager.apply(track)
            try await eventually("pending proof decode started") { ImageFixtures.decoding.contains(name) }
            track.artwork = nil; track.nativeTrackID = nil; track.artworkItemIdentifier = nil; track.album = ""
            manager.apply(track)
            switch boundary {
            case "opaque": track.artworkItemIdentifier = "opaque B"
            case "native": track.nativeTrackID = "456"
            case "album": track.album = "Another album"
            default: track.bundleIdentifier = "another.player"
            }
            manager.apply(track)
            try await eventually("rejected pending decode completed") { ImageFixtures.completed[name, default: 0] > 0 }
            // The decoder completion is deliberately uncancelable. Let its caller resume,
            // then verify that the revision gate rejected the obsolete image.
            try await Task.sleep(for: .milliseconds(20))
            try expect(manager.albumArt === ImageFixtures.image("default"),
                       "A pending decoder crossed the \(boundary) boundary after a partial observation")
        }
    }
}
