//
//  QuickLookService.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-07.
//

import Foundation
import UniformTypeIdentifiers
import SwiftUI
import QuickLookUI
import QuickLook
import AppKit

@MainActor
final class QuickLookService: ObservableObject {
    @Published var urls: [URL] = []
    @Published var selectedURL: URL?

    @Published var isQuickLookOpen: Bool = false

    private var previewPanel: QLPreviewPanel?
    private var dataSource: QuickLookDataSource?
    private var resources: SharingSessionResources?
    private var requestID = UUID()
    private var previewPanelObserver: Any?

    func show(urls: [URL], selectFirst: Bool = true, slideshow: Bool = false) {
        guard !ShelfStorageEnvironment.isIsolatedPreview, !urls.isEmpty else { return }
        let id = UUID()
        requestID = id
        Task { @MainActor in
            let resources = await SharingSessionResources.acquire(fileURLs: urls.filter(\.isFileURL))
            guard requestID == id else { resources.finish(); return }
            self.resources?.finish()
            if let old = previewPanel {
                NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            }
            self.resources = resources
            self.urls = urls
            self.isQuickLookOpen = true
            if selectFirst { self.selectedURL = urls.first }
            let panel = QLPreviewPanel.shared()
            previewPanel = panel
            NotificationCenter.default.addObserver(self, selector: #selector(previewPanelWillClose(_:)),
                name: NSWindow.willCloseNotification, object: panel)
        }
    }

    func hide() {
        let panel = previewPanel
        stopAccessingCurrentURLs()
        selectedURL = nil
        urls.removeAll()
        isQuickLookOpen = false
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        }
        if let panel = previewPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            previewPanel = nil
        }
    }
    
    private func stopAccessingCurrentURLs() {
        requestID = UUID()
        resources?.finish()
        resources = nil
        // If Quick Look panel was closed externally, also remove observer and clear reference
        if let panel = previewPanel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
            previewPanel = nil
        }
    }
    
    func showQuickLook(urls: [URL]) {
        show(urls: urls, selectFirst: true, slideshow: false)
    }

    func updateSelection(urls: [URL]) {
        guard isQuickLookOpen else { return }
    show(urls: urls, selectFirst: true)
    }
}

extension QuickLookService {
    @objc private func previewPanelWillClose(_ notification: Notification) {
        guard let panel = notification.object as? QLPreviewPanel, panel === previewPanel else { return }
        hide()
    }
}

struct QuickLookPresenter: ViewModifier {
    @ObservedObject var service: QuickLookService

    func body(content: Content) -> some View {
        content
            .quickLookPreview($service.selectedURL, in: service.urls)
            .onChange(of: service.selectedURL) { _, url in
                if url == nil && service.isQuickLookOpen { service.hide() }
            }
    }
}

extension View {
    func quickLookPresenter(using service: QuickLookService) -> some View {
        self.modifier(QuickLookPresenter(service: service))
    }
}


final class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return urls.count
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < urls.count else { return nil }
        return urls[index] as QLPreviewItem
    }
}
