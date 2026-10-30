import AppKit
import BoringCore
import Combine
import Foundation
import ImageIO

/// A decoded image is constructed on one worker, then exclusively presented on MainActor.
private struct DecodedArtwork: @unchecked Sendable { let image: NSImage? }

/// Owns decode/color revisions independently of player metadata and HTTP. The facade can
/// change tracks immediately; a stale completion can never replace its current presentation.
@MainActor
final class ArtworkPresentationService: ObservableObject {
    @Published private(set) var image: NSImage
    @Published private(set) var usesApplicationIcon = false
    @Published private(set) var color: NSColor = .white
    private let defaultImage: NSImage
    private let colorEnabled: () -> Bool
    private let decode: @MainActor (Data) async -> NSImage?
    private let sampleColor: @MainActor (NSImage, @escaping (NSColor?) -> Void) -> Void
    private var data: Data?
    private var bundle: String?
    private var itemIdentity: MediaItemIdentity?
    private var artworkItemIdentifier: String?
    private var decodedData: Data?
    private var decodedBundle: String?
    private var decodedIdentity: MediaItemIdentity?
    private var decodedItemIdentifier: String?
    private var revision = UUID()
    private var decodeTask: Task<Void, Never>?
    private struct PendingDecode {
        let data: Data
        let bundle: String
        var identity: MediaItemIdentity?
        var itemIdentifier: String?
    }
    private var pendingDecode: PendingDecode?

    init(defaultImage: NSImage, colorEnabled: @escaping () -> Bool = { true },
         decode: @escaping @MainActor (Data) async -> NSImage? = ArtworkPresentationService.decodeImage,
         sampleColor: @escaping @MainActor (NSImage, @escaping (NSColor?) -> Void) -> Void = { $0.averageColor(completion: $1) }) {
        self.defaultImage = defaultImage; self.image = defaultImage
        self.colorEnabled = colorEnabled
        self.decode = decode; self.sampleColor = sampleColor
    }
    deinit { decodeTask?.cancel() }
    func stop() {
        cancelDecode()
        data = nil; bundle = nil; itemIdentity = nil; artworkItemIdentifier = nil
        clearDecodedAssociation()
    }

    func apply(data: Data?, bundleIdentifier: String, identity: MediaItemIdentity? = nil,
               artworkItemIdentifier: String? = nil) {
        guard self.data != data || bundle != bundleIdentifier || itemIdentity != identity
            || self.artworkItemIdentifier != artworkItemIdentifier else { return }
        let sharedDecodedCover = data != nil && decodedData == data && decodedBundle == bundleIdentifier
        let keepDecodedCover = decodedData != nil && decodedBundle == bundleIdentifier
            && Self.sameItem(decodedIdentity, identity, oldIdentifier: decodedItemIdentifier,
                             newIdentifier: artworkItemIdentifier)
        let associatedIdentity = keepDecodedCover ? Self.refinedIdentity(decodedIdentity, identity) : identity
        let associatedIdentifier = keepDecodedCover ? artworkItemIdentifier ?? decodedItemIdentifier : artworkItemIdentifier
        if var pending = pendingDecode, pending.bundle == bundleIdentifier,
           data == nil || data == pending.data,
           Self.sameItem(pending.identity, identity, oldIdentifier: pending.itemIdentifier,
                         newIdentifier: artworkItemIdentifier) {
            // A pause or a partial metadata observation can omit bytes while their decoder is
            // still running. Keep that verified work alive; waiting for another artwork event
            // can otherwise leave the placeholder on screen for the rest of the song.
            pending.identity = Self.refinedIdentity(pending.identity, identity)
            pending.itemIdentifier = artworkItemIdentifier ?? pending.itemIdentifier
            pendingDecode = pending
            self.data = data; bundle = bundleIdentifier; itemIdentity = identity
            self.artworkItemIdentifier = artworkItemIdentifier
            if keepDecodedCover {
                decodedIdentity = associatedIdentity; decodedItemIdentifier = associatedIdentifier
            }
            return
        }
        cancelDecode()
        self.data = data; bundle = bundleIdentifier; itemIdentity = identity
        self.artworkItemIdentifier = artworkItemIdentifier
        if sharedDecodedCover {
            decodedIdentity = associatedIdentity; decodedItemIdentifier = associatedIdentifier
            if colorEnabled() { calculateAverageColor() }
            return
        }
        if keepDecodedCover {
            decodedIdentity = associatedIdentity; decodedItemIdentifier = associatedIdentifier
            if colorEnabled() { calculateAverageColor() }
        } else { applyPlaceholder() }
        let ticket = revision
        guard let data else { return }
        pendingDecode = .init(data: data, bundle: bundleIdentifier, identity: associatedIdentity,
                              itemIdentifier: associatedIdentifier)
        decodeTask = Task { @MainActor [weak self, decode] in
            let decoded = await decode(data)
            guard !Task.isCancelled, let self, self.revision == ticket,
                  let pending = self.pendingDecode else { return }
            if let image = decoded {
                self.decodedData = data; self.decodedBundle = bundleIdentifier
                self.decodedIdentity = pending.identity; self.decodedItemIdentifier = pending.itemIdentifier
                self.present(image, usesIcon: false)
            }
            self.pendingDecode = nil; self.decodeTask = nil
        }
    }

    private func cancelDecode() {
        decodeTask?.cancel(); decodeTask = nil; pendingDecode = nil; revision = UUID()
    }

    private func clearDecodedAssociation() {
        decodedData = nil; decodedBundle = nil; decodedIdentity = nil; decodedItemIdentifier = nil
    }

    private static func refinedIdentity(_ previous: MediaItemIdentity?, _ next: MediaItemIdentity?) -> MediaItemIdentity? {
        guard let previous, let next else { return next }
        // Partial observations cannot erase the recording that supplied these pixels.
        return .init(source: next.source, nativeID: next.nativeID ?? previous.nativeID,
            title: next.title.isEmpty ? previous.title : next.title,
            artist: next.artist.isEmpty ? previous.artist : next.artist,
            album: next.album.isEmpty ? previous.album : next.album)
    }

    private static func sameItem(_ previous: MediaItemIdentity?, _ next: MediaItemIdentity?,
                                 oldIdentifier: String?, newIdentifier: String?) -> Bool {
        guard let previous, let next, previous.source == next.source else { return false }
        if let oldIdentifier, let newIdentifier, oldIdentifier != newIdentifier { return false }
        if let oldID = previous.nativeID, let newID = next.nativeID { return oldID == newID }
        if previous == next { return true }
        let title = MediaText.normalized(previous.title), artist = MediaText.normalized(previous.artist)
        return !title.isEmpty && !artist.isEmpty && title == MediaText.normalized(next.title)
            && artist == MediaText.normalized(next.artist)
            && (previous.album.isEmpty || next.album.isEmpty
                || MediaText.normalized(previous.album) == MediaText.normalized(next.album))
    }
    private static func decodeImage(_ data: Data) async -> NSImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceShouldCacheImmediately: true,
                  ] as CFDictionary) else { return DecodedArtwork(image: nil) }
            return DecodedArtwork(image: NSImage(cgImage: thumbnail, size: .zero))
        }.value.image
    }
    private func applyPlaceholder() {
        clearDecodedAssociation()
        if image !== defaultImage || usesApplicationIcon { present(defaultImage, usesIcon: false) }
    }
    func setImage(_ image: NSImage, usesIcon: Bool = false) {
        stop(); present(image, usesIcon: usesIcon)
    }
    private func present(_ image: NSImage, usesIcon: Bool) {
        self.image = image; usesApplicationIcon = usesIcon
        if colorEnabled() { calculateAverageColor() }
    }
    func calculateAverageColor() {
        let image = self.image, ticket = revision
        sampleColor(image) { [weak self] color in
            Task { @MainActor in
                guard let self, self.revision == ticket, self.image === image else { return }
                self.color = color ?? .white
            }
        }
    }
}
