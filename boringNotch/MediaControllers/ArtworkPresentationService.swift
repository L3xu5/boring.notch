import AppKit
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
    private let icon: (String) -> NSImage?
    private let colorEnabled: () -> Bool
    private let decode: @MainActor (Data) async -> NSImage?
    private let sampleColor: @MainActor (NSImage, @escaping (NSColor?) -> Void) -> Void
    private var data: Data?
    private var bundle: String?
    private var revision = UUID()
    private var decodeTask: Task<Void, Never>?

    init(defaultImage: NSImage, icon: @escaping (String) -> NSImage?, colorEnabled: @escaping () -> Bool = { true },
         decode: @escaping @MainActor (Data) async -> NSImage? = ArtworkPresentationService.decodeImage,
         sampleColor: @escaping @MainActor (NSImage, @escaping (NSColor?) -> Void) -> Void = { $0.averageColor(completion: $1) }) {
        self.defaultImage = defaultImage; self.image = defaultImage
        self.icon = icon; self.colorEnabled = colorEnabled
        self.decode = decode; self.sampleColor = sampleColor
    }
    deinit { decodeTask?.cancel() }
    func stop() { decodeTask?.cancel(); decodeTask = nil; revision = UUID(); data = nil; bundle = nil }

    func apply(data: Data?, bundleIdentifier: String) {
        guard self.data != data || bundle != bundleIdentifier else { return }
        stop()
        self.data = data; bundle = bundleIdentifier
        let ticket = revision
        guard let data else { applyFallback(bundleIdentifier); return }
        decodeTask = Task { @MainActor [weak self, decode] in
            let decoded = await decode(data)
            guard !Task.isCancelled, let self, self.revision == ticket else { return }
            if let image = decoded { self.present(image, usesIcon: false) }
            else { self.applyFallback(bundleIdentifier) }
            self.decodeTask = nil
        }
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
    private func applyFallback(_ bundle: String) {
        let image = icon(bundle)
        present(image ?? defaultImage, usesIcon: image != nil)
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
