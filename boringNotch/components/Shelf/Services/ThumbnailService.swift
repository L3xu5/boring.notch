import Foundation
import AppKit
import QuickLookThumbnailing
import BoringCore

private struct ThumbnailKey: Hashable, Sendable {
    let path: String
    let modified: Date?
    let fileSize: Int?
    let width: Double
    let height: Double
    let scale: Double
}
private final class ThumbnailImage: @unchecked Sendable {
    let image: NSImage
    init(_ image: NSImage) { self.image = image }
}
private final class ThumbnailGeneration: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request
    let generator = QLThumbnailGenerator.shared
    init(_ request: QLThumbnailGenerator.Request) { self.request = request }
    func cancel() { generator.cancel(request) }
}

actor ThumbnailService {
    static let shared = ThumbnailService()
    private var cache = CostBoundedCache<ThumbnailKey, ThumbnailImage>(maximumCost: 32 * 1024 * 1024)
    private var pending: [ThumbnailKey: (id: UUID, task: Task<ThumbnailImage?, Never>)] = [:]
    private var generation: UInt64 = 0

    func thumbnail(for url: URL, size: CGSize) async -> NSImage? {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return nil }
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let values = url.accessSecurityScopedResource { try? $0.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) }
        let key = ThumbnailKey(path: url.standardizedFileURL.path, modified: values?.contentModificationDate,
                               fileSize: values?.fileSize, width: size.width, height: size.height, scale: scale)
        if let value = cache.value(forKey: key) { return value.image }
        if let request = pending[key] { return await request.task.value?.image }
        let id = UUID()
        let epoch = generation
        let task = Task {
            let image = await generate(for: url, size: size, scale: scale)
            if !Task.isCancelled, epoch == generation, let image {
                let cost = max(1, Int(size.width * scale) * Int(size.height * scale) * 4)
                cache.insert(image, forKey: key, cost: cost)
            }
            if pending[key]?.id == id { pending[key] = nil }
            return image
        }
        pending[key] = (id, task)
        return await task.value?.image
    }
    func clearCache() {
        generation &+= 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        cache.removeAll()
    }
    func clearCache(for url: URL) {
        generation &+= 1
        let path = url.standardizedFileURL.path
        for key in cache.keys where key.path == path { cache.removeValue(forKey: key) }
        for key in pending.keys.filter({ $0.path == path }) { pending.removeValue(forKey: key)?.task.cancel() }
    }
    private func generate(for url: URL, size: CGSize, scale: Double) async -> ThumbnailImage? {
        await url.accessSecurityScopedResource { scoped in
            let request = QLThumbnailGenerator.Request(fileAt: scoped, size: size, scale: scale, representationTypes: .all)
            request.iconMode = true
            let operation = ThumbnailGeneration(request)
            let result = CallbackResult<ThumbnailImage?>()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    result.install(continuation)
                    guard !Task.isCancelled else { result.cancel(returning: nil); return }
                    operation.generator.generateBestRepresentation(for: request) { representation, _ in
                        let image = representation.map { ThumbnailImage(NSImage(cgImage: $0.cgImage,
                            size: NSSize(width: $0.cgImage.width, height: $0.cgImage.height))) }
                        result.resume(returning: image)
                    }
                    result.onCancel { operation.cancel() }
                }
            } onCancel: { result.cancel(returning: nil) }
        }
    }
}
