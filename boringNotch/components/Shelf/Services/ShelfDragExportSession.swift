import AppKit
import BoringCore
import Defaults

/// The Cocoa security scope belongs to the same handoff as the generated-file lease.
private final class DragSecurityScope: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    init(_ urls: [URL]) { self.urls = urls.filter { $0.startAccessingSecurityScopedResource() } }
    func finish() {
        let urls = lock.withLock { let current = self.urls; self.urls = []; return current }
        urls.forEach { $0.stopAccessingSecurityScopedResource() }
    }
    deinit { finish() }
}

@MainActor
final class ShelfDragExportSession {
    let items: [ShelfItem]
    let fileURLs: [UUID: URL]
    private let handoff: AssetExportHandoff
    private init(items: [ShelfItem], fileURLs: [UUID: URL], handoff: AssetExportHandoff) {
        self.items = items; self.fileURLs = fileURLs; self.handoff = handoff
    }
    static func prepare(_ proposedItems: [ShelfItem]) async -> ShelfDragExportSession {
        var items: [ShelfItem] = []
        var urls: [UUID: URL] = [:]
        for item in proposedItems {
            if case .file = item.kind {
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item),
                      url.accessSecurityScopedResource(accessor: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
                urls[item.id] = url
            }
            items.append(item)
        }
        let scopes = DragSecurityScope(Array(urls.values))
        let exportedItems = items
        let handoff = await TemporaryFileStorageService.shared.prepareExportHandoff(for: Array(urls.values)) { mayRemove in
            scopes.finish()
            guard mayRemove else { return }
            Task { @MainActor in
                guard Defaults[.autoRemoveShelfItems] else { return }
                for item in exportedItems { ShelfStateViewModel.shared.remove(item) }
            }
        }
        return ShelfDragExportSession(items: items, fileURLs: urls, handoff: handoff)
    }
    func claimReceiver() -> AssetExportReceiver? { handoff.claimReceiver() }
    func ended(_ operation: NSDragOperation) {
        let outcome: AssetDragOutcome
        if operation.isEmpty { outcome = .cancelled }
        else if operation.contains(.delete) { outcome = .deleted }
        else if operation.contains(.move) { outcome = .moved }
        else { outcome = .copied }
        let handoff = handoff
        Task { await handoff.sourceEnded(outcome) }
    }
}

/// SwiftUI's onDrop must claim this synchronously before returning acceptance to AppKit.
@MainActor
enum ShelfDragExportRegistry {
    static var current: ShelfDragExportSession?
    static func claimReceiver() -> AssetExportReceiver? { current?.claimReceiver() }
    static func ended(_ session: ShelfDragExportSession?) {
        if let session, current === session { current = nil }
    }
}
