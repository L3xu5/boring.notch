import BoringCore
import Foundation

/// The preview is a separate execution environment, not just a different preferences domain.
/// Every Shelf factory must choose its boundary before constructing any live storage object.
enum ShelfStorageEnvironment {
    static var isIsolatedPreview: Bool {
        #if DEBUG
        MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: Bundle.main.bundleIdentifier,
                                            arguments: ProcessInfo.processInfo.arguments)
        #else
        false
        #endif
    }
    static let previewOwnedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("BoringNotchPreviewAssets-" + UUID().uuidString, isDirectory: true)
    static var ownedAssetsRoot: URL {
        if isIsolatedPreview { return previewOwnedRoot }
        return liveOwnedAssetsRoot()
    }
    static func liveOwnedAssetsRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boringNotch/Shelf/OwnedAssets", isDirectory: true)
    }
    static func liveShelfFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("boringNotch/Shelf/items.json")
    }
}
