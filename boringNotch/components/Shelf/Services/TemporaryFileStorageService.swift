import Foundation
import BoringCore

enum TempFileType {
    case data(Data, suggestedName: String?)
    case text(String)
    case url(URL)
}

/// Compatibility facade. The core store owns every generated file; borrowed provider URLs
/// never become deletable merely because they happen to live in a temporary directory.
final class TemporaryFileStorageService {
    static let shared = TemporaryFileStorageService()
    private let store: OwnedTemporaryAssetStore?

    init(rootURL: URL? = nil, liveRoot: @Sendable () -> URL = { ShelfStorageEnvironment.liveOwnedAssetsRoot() }) {
        let root = ShelfStorageEnvironment.isIsolatedPreview ? ShelfStorageEnvironment.previewOwnedRoot : (rootURL ?? liveRoot())
        store = try? OwnedTemporaryAssetStore(rootURL: root)
    }

    func createTempFile(for type: TempFileType) async -> URL? {
        guard let store else { return nil }
        do {
            let asset: OwnedTemporaryAsset
            switch type {
            case .data(let data, let name):
                asset = try await store.create(data: data, suggestedName: name ?? "Untitled.dat")
            case .text(let text):
                asset = try await store.create(data: Data(text.utf8), suggestedName: "Text.txt")
            case .url(let url):
                asset = try await store.createWebloc(for: url)
            }
            return asset.url
        } catch { return nil }
    }

    func createZip(from urls: [URL], suggestedName: String? = nil) async -> URL? {
        guard let store else { return nil }
        do {
            let name = suggestedName ?? (urls.count == 1 ? urls[0].lastPathComponent + ".zip" : "Archive.zip")
            return try await store.createArchive(from: urls, suggestedName: name).url
        } catch { return nil }
    }

    func removeTemporaryFileIfNeeded(at url: URL) {
        guard let store else { return }
        Task { try? await store.remove(at: url) }
    }

    func acquireLease(for url: URL) async -> TemporaryAssetLease? {
        guard let store else { return nil }
        return try? await store.acquireLease(for: url)
    }

    func release(_ lease: TemporaryAssetLease) async {
        try? await store?.release(lease)
    }
}

extension TemporaryFileStorageService {
    /// Leases are registered before AppKit starts tracking the drag, not after the receiver
    /// begins an asynchronous NSItemProvider load.
    func prepareExportHandoff(for urls: [URL], onDisposition: @escaping @Sendable (Bool) -> Void) async -> AssetExportHandoff {
        var leases: [TemporaryAssetLease] = []
        if let store {
            for url in urls {
                if let lease = try? await store.acquireLease(for: url) { leases.append(lease) }
            }
        }
        return AssetExportHandoff(store: store, leases: leases, onDisposition: onDisposition)
    }
}
