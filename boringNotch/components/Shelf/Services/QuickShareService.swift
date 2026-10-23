//
//  QuickShareService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import BoringCore

/// Dynamic representation of a sharing provider discovered at runtime
struct QuickShareProvider: Identifiable, Hashable, Sendable {
    var id: String
    var imageData: Data?
    var supportsRawText: Bool
}

@MainActor
final class QuickShareService: ObservableObject {
    static let shared = QuickShareService()
    
    @Published var availableProviders: [QuickShareProvider] = []
    @Published var isPickerOpen = false
    private var cachedServices: [String: NSSharingService] = [:]
    private var activeOperation: UUID?
   
    init() {
        guard !ShelfStorageEnvironment.isIsolatedPreview else {
            availableProviders = [QuickShareProvider.defaultProvider]
            return
        }
        Task {
            await discoverAvailableProviders()
        }
    }
    
    // MARK: - Provider Discovery
    
    @MainActor
    func discoverAvailableProviders() async {
        let finder = ShareServiceFinder()

        // Use simple test items without creating actual temp files
        // This avoids issues with the Share Sheet retaining references to deleted files
        let testItems: [Any] = [
            URL(string:"http://example.com") ?? URL(fileURLWithPath: "/"),
            "Test Text" as NSString
        ]

        let services = await finder.findApplicableServices(for: testItems)

        var providers: [QuickShareProvider] = []

        for svc in services {
            let title = svc.title
            let imgData = svc.image.tiffRepresentation
            let supportsRawText = svc.canPerform(withItems: ["Test Text"])
            let provider = QuickShareProvider(id: title, imageData: imgData, supportsRawText: supportsRawText)
            if !providers.contains(provider) {
                providers.append(provider)
                cachedServices[title] = svc
            }
        }
        
        if let idx = providers.firstIndex(where: { $0.id == "AirDrop" }) {
            let ad = providers.remove(at: idx)
            providers.insert(ad, at: 0)
        }

        if !providers.contains(where: { $0.id == "System Share Menu" }) {
            providers.append(QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true))
        }

        self.availableProviders = providers

    }
    
    // MARK: - File Picker
    @MainActor
    func showFilePicker(for provider: QuickShareProvider, from view: NSView?) async {
        guard !isPickerOpen else {
            print("⚠️ QuickShareService: File picker already open")
            return
        }

        isPickerOpen = true
        SharingStateManager.shared.beginInteraction()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.title = "Select Files for \(provider.id)"
        panel.message = "Choose files to share via \(provider.id)"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.isPickerOpen = false

            if response == .OK && !panel.urls.isEmpty {
                Task {
                    // Keep the picker interaction across the executor handoff and
                    // asynchronous resource acquisition. The service delegate takes
                    // over before shareFilesOrText returns.
                    defer { SharingStateManager.shared.endInteraction() }
                    await self?.shareFilesOrText(panel.urls, using: provider, from: view)
                }
            } else {
                SharingStateManager.shared.endInteraction()
            }
        }

        let response = panel.runModal()
        completion(response)
    }
    
    // MARK: - Sharing
    func shareFilesOrText(_ items: [Any], using provider: QuickShareProvider, from view: NSView?, cleanupURLs: [URL] = [],
                          onCompletion: @escaping (Bool) -> Void = { _ in }) async {
        guard !Task.isCancelled, activeOperation == nil, !items.isEmpty else {
            for url in cleanupURLs { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
            onCompletion(false)
            return
        }
        // Resource preparation may suspend for arbitrarily long filesystem work.
        // Hold a bridge until the delegate owns the actual sharing lifecycle.
        SharingStateManager.shared.beginInteraction()
        defer { SharingStateManager.shared.endInteraction() }
        let operation = UUID()
        activeOperation = operation
        let fileURLs = items.compactMap { $0 as? URL }.filter(\.isFileURL)
        let resources = await SharingSessionResources.acquire(fileURLs: fileURLs, cleanupURLs: cleanupURLs)
        guard !Task.isCancelled else {
            resources.finish()
            if activeOperation == operation { activeOperation = nil }
            onCompletion(false)
            return
        }
        let delegate = SharingStateManager.shared.makeDelegate(onEnd: { [weak self] in
            resources.finish()
            if self?.activeOperation == operation { self?.activeOperation = nil }
        }, onCompletion: onCompletion)
        if let service = cachedServices[provider.id], service.canPerform(withItems: items) {
            delegate.markServiceBegan()
            service.delegate = delegate
            service.perform(withItems: items)
        } else if let view, view.window != nil {
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = delegate
            delegate.markPickerBegan()
            picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
        } else {
            delegate.cancel()
        }
    }

    func shareDroppedFiles(_ providers: [NSItemProvider], using shareProvider: QuickShareProvider, from view: NSView?,
                           onCompletion: @escaping (Bool) -> Void = { _ in }) async {
        var payload: [Any] = []
        var cleanup: [URL] = []
        var allLoaded = true
        for provider in providers {
            if let url = await provider.extractFileURL() { payload.append(url) }
            else if let url = await provider.extractURL() { payload.append(url) }
            else if let text = await provider.extractText() {
                if shareProvider.supportsRawText { payload.append(text) }
                else if let url = await TemporaryFileStorageService.shared.createTempFile(for: .text(text)) {
                    payload.append(url); cleanup.append(url)
                } else { payload.append(text) }
            } else if let url = await provider.extractItem() {
                payload.append(await resolveShelfItemBookmark(for: url) ?? url)
            } else if let data = await provider.loadDataWithName(),
                      let url = await TemporaryFileStorageService.shared.createTempFile(for: .data(data.data, suggestedName: data.suggestedName)) {
                payload.append(url); cleanup.append(url)
            } else { allLoaded = false }
        }
        guard !Task.isCancelled, !payload.isEmpty else {
            cleanup.forEach { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: $0) }
            onCompletion(false)
            return
        }
        let completeSelection = allLoaded
        await shareFilesOrText(payload, using: shareProvider, from: view, cleanupURLs: cleanup) { success in
            // A successful partial share must not remove source records whose provider failed.
            onCompletion(success && completeSelection)
        }
    }

    private func resolveShelfItemBookmark(for fileURL: URL) async -> URL? {
        let items = ShelfStateViewModel.shared.items

        for itm in items {
            if let resolved = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: itm) {
                if resolved.standardizedFileURL.path == fileURL.standardizedFileURL.path {
                    return resolved
                }
            }
        }
        print("❌ Failed to resolve bookmark for shelf item")
        return nil
    }
}

// MARK: - App Storage Extension for Provider Selection

extension QuickShareProvider {
    static var defaultProvider: QuickShareProvider {
        // Defaults registration must not instantiate UI services or depend on asynchronous
        // provider discovery. Existing stored choices are unaffected by this stable fallback.
        QuickShareProvider(id: "System Share Menu", imageData: nil, supportsRawText: true)
    }
}

/// Security scopes and generated assets belong to the operation, rather than a mutable global
/// URL array. In-flight operations keep their files even if another UI asks to remove them.
@MainActor
final class SharingSessionResources {
    private var scopedURLs: [URL]
    private var assetLeases: [TemporaryAssetLease]
    private var cleanupURLs: [URL]
    private var finished = false
    private init(scopedURLs: [URL], assetLeases: [TemporaryAssetLease], cleanupURLs: [URL]) {
        self.scopedURLs = scopedURLs
        self.assetLeases = assetLeases
        self.cleanupURLs = cleanupURLs
    }
    static func acquire(fileURLs: [URL], cleanupURLs: [URL] = []) async -> SharingSessionResources {
        let scoped = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
        var leases: [TemporaryAssetLease] = []
        for url in fileURLs {
            if let lease = await TemporaryFileStorageService.shared.acquireLease(for: url) { leases.append(lease) }
        }
        return SharingSessionResources(scopedURLs: scoped, assetLeases: leases, cleanupURLs: cleanupURLs)
    }
    func finish() {
        guard !finished else { return }
        finished = true
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        let leases = assetLeases
        let cleanup = cleanupURLs
        assetLeases = []
        cleanupURLs = []
        Task {
            for url in cleanup { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
            for lease in leases { await TemporaryFileStorageService.shared.release(lease) }
        }
    }
    deinit {
        let scopes = scopedURLs
        let leases = assetLeases
        let cleanup = cleanupURLs
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }
        Task { @MainActor in
            for url in cleanup { TemporaryFileStorageService.shared.removeTemporaryFileIfNeeded(at: url) }
            for lease in leases { await TemporaryFileStorageService.shared.release(lease) }
        }
    }
}
