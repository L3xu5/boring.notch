import Foundation
import BoringCore

protocol ShelfPersistenceProviding: Sendable {
    func load() async throws -> [ShelfItem]
    func save(_ items: [ShelfItem], revision: UInt64) async throws
}

/// The persistence boundary owns encoding and disk IO on its actor, away from SwiftUI updates.
actor ShelfPersistenceService: ShelfPersistenceProviding {
    static let shared = ShelfPersistenceService()
    private let store: AtomicJSONStore<[ShelfItem]>?
    private let fileURL: URL?
    private var memoryItems: [ShelfItem] = []
    private var memoryRevision: UInt64 = 0
    private var permitsDiskWrites = false
    enum PersistenceError: Error { case unreadStorage }

    init(fileURL: URL? = nil, liveURL: @Sendable () -> URL = { ShelfStorageEnvironment.liveShelfFileURL() }) {
        // Even an explicitly injected inaccessible/live URL is ignored by an isolated preview.
        // Do not query AppSupport, load legacy records or construct a disk actor before this gate.
        guard !ShelfStorageEnvironment.isIsolatedPreview else {
            self.fileURL = nil; store = nil
            return
        }
        let location = fileURL ?? liveURL()
        self.fileURL = location
        store = AtomicJSONStore(fileURL: location)
    }

    func load() async throws -> [ShelfItem] {
        guard let store, let fileURL else { return memoryItems }
        permitsDiskWrites = false
        do {
            let items = try await store.load() ?? []
            permitsDiskWrites = true
            return items
        } catch {
            // Recover independently decodable records, preserving the original before a future
            // successful write. A corrupt file must not silently disappear behind an empty list.
            let data = try Data(contentsOf: fileURL)
            let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
            let recovered = array.compactMap { value -> ShelfItem? in
                guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
                return try? JSONDecoder().decode(ShelfItem.self, from: data)
            }
            _ = try await store.quarantineCorruptFile()
            _ = try await store.save(recovered, revision: 0)
            permitsDiskWrites = true
            return recovered
        }
    }

    func save(_ items: [ShelfItem], revision: UInt64) async throws {
        guard let store else {
            if revision >= memoryRevision { memoryItems = items; memoryRevision = revision }
            return
        }
        guard permitsDiskWrites else { throw PersistenceError.unreadStorage }
        _ = try await store.save(items, revision: revision)
    }
}
