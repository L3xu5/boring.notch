import AppKit

/// A clipboard consumer may paste much later. Keep resources until the pasteboard changes,
/// rather than leaking scopes forever or guessing a timeout for the external paste operation.
@MainActor
final class ShelfClipboardService {
    static let shared = ShelfClipboardService()
    private var resources: SharingSessionResources?
    private var monitor: Task<Void, Never>?
    private var requestID = UUID()

    func copy(fileURLs: [URL], fallbackText: String) async {
        let id = UUID()
        requestID = id
        let newResources = await SharingSessionResources.acquire(fileURLs: fileURLs)
        guard requestID == id else { newResources.finish(); return }
        monitor?.cancel()
        resources?.finish()
        resources = newResources
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let succeeded = fileURLs.isEmpty ? pasteboard.setString(fallbackText, forType: .string)
            : pasteboard.writeObjects(fileURLs as [NSURL])
        guard succeeded, !fileURLs.isEmpty else { resources?.finish(); resources = nil; return }
        let changeCount = pasteboard.changeCount
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.requestID == id else { return }
                if pasteboard.changeCount != changeCount {
                    self.resources?.finish()
                    self.resources = nil
                    self.monitor = nil
                    return
                }
            }
        }
    }
}
