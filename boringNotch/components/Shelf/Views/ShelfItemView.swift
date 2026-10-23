//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import SwiftUI
import Defaults

import QuickLook

struct ShelfItemView: View {
    let item: ShelfItem
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var selection = ShelfSelectionModel.shared
    @StateObject private var viewModel: ShelfItemViewModel
    @EnvironmentObject private var quickLookService: QuickLookService
    @State private var showStack = false
    @State private var cachedPreviewImage: NSImage?
    @State private var debouncedDropTarget = false

    private var isSelected: Bool { viewModel.isSelected }
    private var shouldHideDuringDrag: Bool { selection.isDragging && selection.isSelected(item.id) && false }
    
    init(item: ShelfItem) {
        self.item = item
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    var body: some View {
        ZStack {
            if !shouldHideDuringDrag {
                VStack(alignment: .center, spacing: 2) {
                    iconView
                    textView
                }
                .frame(width: 105)
                .padding(.vertical, 10)
                .padding(.horizontal, 5)
                .background(backgroundView)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.1), value: debouncedDropTarget)
                .animation(.easeInOut(duration: 0.1), value: isSelected)

                DraggableClickHandler(
                    item: item,
                    viewModel: viewModel,
                    cachedPreviewImage: $cachedPreviewImage,
                    dragPreviewContent: {
                        DragPreviewView(thumbnail: viewModel.thumbnail ?? viewModel.fallbackIcon, displayName: viewModel.displayName)
                    },
                    onRightClick: viewModel.handleRightClick,
                    onClick: { event, nsview in
                        viewModel.handleClick(event: event, view: nsview)
                    }
                )
            } else {
                Color.clear
                    .frame(width: 105)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 5)
            }
        }
        .onChange(of: viewModel.isDropTargeted) { _, targeted in
            vm.dragDetectorTargeting = targeted
            // Debounce drop target state changes
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                debouncedDropTarget = targeted
            }
        }
        .task(id: item) {
            viewModel.update(item: item)
            await viewModel.loadThumbnail()
            guard !Task.isCancelled else { return }
            cachedPreviewImage = await renderDragPreview()
            viewModel.onQuickLookRequest = { urls in
                quickLookService.show(urls: urls, selectFirst: true)
            }
        }
        .onChange(of: viewModel.thumbnail) { _, _ in
            // Invalidate cached preview when thumbnail changes
            Task {
                cachedPreviewImage = await renderDragPreview()
            }
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - View Components

    private var iconView: some View {
        Image(nsImage: viewModel.thumbnail ?? viewModel.fallbackIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
    }

    private var textView: some View {
        Text(viewModel.displayName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .lineLimit(2)
            .truncationMode(.middle)
            .multilineTextAlignment(.center)
            .frame(height: 30, alignment: .top)
    }

    private var backgroundView: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        strokeColor,
                        lineWidth: strokeWidth
                    )
            )
    }

    private var backgroundColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.25)
        } else if isSelected {
            return Color.accentColor.opacity(0.15)
        } else {
            return Color.clear
        }
    }

    private var strokeColor: Color {
        if debouncedDropTarget {
            return Color.accentColor.opacity(0.9)
        } else if isSelected {
            return Color.accentColor.opacity(0.8)
        } else {
            return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        if debouncedDropTarget {
            return 3
        } else if isSelected {
            return 2
        } else {
            return 1
        }
    }
    
    // MARK: - Drag Preview Rendering
    
    @MainActor
    private func renderDragPreview() async -> NSImage {
        let content = DragPreviewView(thumbnail: viewModel.thumbnail ?? viewModel.fallbackIcon, displayName: viewModel.displayName)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? (viewModel.thumbnail ?? viewModel.fallbackIcon)
    }

    
}

// MARK: - Draggable Click Handler with NSDraggingSource
private struct DraggableClickHandler<Content: View>: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    @Binding var cachedPreviewImage: NSImage?
    @ViewBuilder let dragPreviewContent: () -> Content
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void
    
    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        view.item = item
        view.viewModel = viewModel
        view.dragPreviewImage = cachedPreviewImage ?? renderDragPreview()
        view.onRightClick = onRightClick
        view.onClick = onClick
        return view
    }
    
    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        nsView.item = item
        nsView.viewModel = viewModel
        // Only update preview if cached version is available
        if let cached = cachedPreviewImage {
            nsView.dragPreviewImage = cached
        }
        nsView.onRightClick = onRightClick
        nsView.onClick = onClick
    }
    
    private func renderDragPreview() -> NSImage {
        let content = dragPreviewContent()
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        
        if let nsImage = renderer.nsImage {
            return nsImage
        }
        
        // Fallback to icon if rendering fails
        return viewModel.thumbnail ?? viewModel.fallbackIcon
    }
    
    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        var dragPreviewImage: NSImage?
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?

        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var exportSession: ShelfDragExportSession?
        private var preparationTask: Task<Void, Never>?
        
        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }
        
        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onClick?(event, self)
        }
        
        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent = mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }
            
            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )
            
            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }
        
        private func startDragSession(with event: NSEvent) {
            guard preparationTask == nil else { return }
            let selected = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let proposed = selected.count > 1 && selected.contains(where: { $0.id == item.id }) ? selected : [item!]
            preparationTask = Task { @MainActor [weak self] in
                let session = await ShelfDragExportSession.prepare(proposed)
                guard let self else { session.ended([]); return }
                self.preparationTask = nil
                guard !Task.isCancelled, self.window != nil, NSEvent.pressedMouseButtons & 1 == 1,
                      !session.items.isEmpty else { session.ended([]); return }
                var dragging: [NSDraggingItem] = []
                for item in session.items {
                    guard let writer = self.createPasteboardItem(for: item, fileURL: session.fileURLs[item.id]) else { continue }
                    let draggingItem = NSDraggingItem(pasteboardWriter: writer)
                    let image = self.dragPreviewImage ?? item.icon
                    draggingItem.setDraggingFrame(NSRect(origin: .zero, size: image.size), contents: image)
                    dragging.append(draggingItem)
                }
                guard !dragging.isEmpty else { session.ended([]); return }
                self.exportSession = session
                ShelfDragExportRegistry.current = session
                self.beginDraggingSession(with: dragging, event: event, source: self)
            }
        }

        private func createPasteboardItem(for item: ShelfItem, fileURL: URL?) -> NSPasteboardItem? {
            let pasteboardItem = NSPasteboardItem()

            switch item.kind {
            case .file:
                guard let url = fileURL else { return nil }
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem

            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }
        
        // MARK: - NSDraggingSource
        
        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            // When copyOnDrag is enabled, only allow copy operations
            if Defaults[.copyOnDrag] {
                return [.copy]
            }
            
            switch context {
            case .outsideApplication:
                return [.copy, .move]
            case .withinApplication:
                return [.copy, .move, .generic]
            @unknown default:
                return [.copy]
            }
        }
        
        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }
        
        
        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            let session = exportSession
            exportSession = nil
            ShelfDragExportRegistry.ended(session)
            session?.ended(operation)
        }

        deinit { preparationTask?.cancel() }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            return false
        }
    }
}
