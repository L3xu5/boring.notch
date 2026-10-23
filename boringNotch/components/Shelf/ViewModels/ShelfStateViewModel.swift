//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import BoringCore

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet {
            ShelfSelectionModel.shared.reconcile(with: items)
            guard hasLoadedPersistence else { return }
            persistenceRevision &+= 1
            let snapshot = items
            let revision = persistenceRevision
            Task {
                do { try await persistence.save(snapshot, revision: revision) }
                catch { NSLog("Unable to save shelf state: %@", error.localizedDescription) }
            }
        }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?

    private let persistence: any ShelfPersistenceProviding
    private var persistenceRevision: UInt64 = 0
    private var hasLoadedPersistence = false
    private var activeImports = 0

    init(persistence: any ShelfPersistenceProviding = ShelfPersistenceService.shared) {
        self.persistence = persistence
        Task { [weak self] in
            guard let self else { return }
            do {
                let saved = try await persistence.load()
                // Imports may finish before the disk read; merge rather than overwriting them.
                var merged = saved
                var seen = Set(saved.map(\.identityKey))
                for imported in self.items where seen.insert(imported.identityKey).inserted { merged.append(imported) }
                self.hasLoadedPersistence = true
                self.items = merged
                self.cleanupInvalidItems()
            } catch {
                self.hasLoadedPersistence = true
                NSLog("Unable to load shelf state: %@", error.localizedDescription)
            }
        }
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem) {
        guard let current = items.first(where: { $0.id == item.id }) else { return }
        items.removeAll { $0.id == item.id }
        if let url = current.URL { Task { await ThumbnailService.shared.clearCache(for: url) } }
        if !ShelfStorageEnvironment.isIsolatedPreview { current.cleanupStoredData() }
    }

    @discardableResult
    func addGeneratedFile(at url: URL) async -> Bool {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return false }
        let bookmark = await Task.detached(priority: .utility) { try? Bookmark(url: url) }.value
        guard let bookmark else {
            TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url)
            return false
        }
        add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
        return true
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        activeImports += 1
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            guard let self else {
                for item in dropped { item.cleanupStoredData() }
                return
            }
            self.add(dropped)
            self.activeImports -= 1
            self.isLoading = self.activeImports > 0
        }
    }

    func cleanupInvalidItems() {
        guard !ShelfStorageEnvironment.isIsolatedPreview else { return }
        let snapshot = items
        Task { [weak self] in
            var invalidIDs = Set<UUID>()
            for item in snapshot {
                // A disconnected volume or revoked permission is not evidence that a user's
                // borrowed file reference should be forgotten. Only generated assets expire.
                if item.isTemporary, case .file(let data) = item.kind, !(await Bookmark(data: data).validate()) {
                    invalidIDs.insert(item.id)
                }
            }
            guard let self else { return }
            let retained = CollectionValidation.removingInvalidItems(
                from: self.items, validated: snapshot, invalidIDs: invalidIDs)
            let removed = self.items.filter { item in !retained.contains(where: { $0.id == item.id }) }
            self.items = retained
            for item in removed { item.cleanupStoredData() }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Refreshing a stale shelf bookmark")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Refreshing a stale shelf bookmark")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
