import AppKit
import Foundation
import UniformTypeIdentifiers
import BoringCore

struct ProviderData: Sendable {
    let data: Data
    let suggestedName: String?
}

extension NSItemProvider {
    func extractItem() async -> URL? { await loadFileURL(typeIdentifier: UTType.item.identifier) }
    func extractFileURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await loadFileURL(typeIdentifier: UTType.fileURL.identifier)
    }
    func loadData() async -> Data? { await loadDataWithName()?.data }
    func loadDataWithName() async -> ProviderData? {
        guard hasItemConformingToTypeIdentifier(UTType.data.identifier) else { return nil }
        let suggestedName = self.suggestedName
        return await providerValue { finish in
            self.loadItem(forTypeIdentifier: UTType.data.identifier, options: nil) { item, error in
                guard error == nil else { finish(nil); return }
                if let data = item as? Data { finish(ProviderData(data: data, suggestedName: suggestedName)) }
                else if let url = item as? URL, url.isFileURL {
                    // The provider owns this URL. Read during its callback, retain only bytes,
                    // and never delete, rename or remove its parent directory.
                    let data = url.accessSecurityScopedResource { try? Data(contentsOf: $0, options: .mappedIfSafe) }
                    finish(data.map { ProviderData(data: $0, suggestedName: suggestedName ?? url.lastPathComponent) })
                } else { finish(nil) }
            }
        }
    }
    func extractURL() async -> URL? {
        guard hasItemConformingToTypeIdentifier(UTType.url.identifier),
              let url = await loadURL(typeIdentifier: UTType.url.identifier), url.scheme != nil else { return nil }
        return url
    }
    func extractText() async -> String? {
        for type in [UTType.utf8PlainText.identifier, UTType.plainText.identifier]
            where hasItemConformingToTypeIdentifier(type) {
            if let text = await loadText(typeIdentifier: type) { return text }
        }
        return nil
    }
    func loadFileURL(typeIdentifier: String) async -> URL? {
        await providerValue { finish in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                guard error == nil else { finish(nil); return }
                finish(Self.decodedURL(item, fileOnly: true))
            }
        }
    }
    func loadURL(typeIdentifier: String) async -> URL? {
        await providerValue { finish in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                guard error == nil else { finish(nil); return }
                finish(Self.decodedURL(item, fileOnly: false))
            }
        }
    }
    func loadText(typeIdentifier: String) async -> String? {
        await providerValue { finish in
            self.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                guard error == nil else { finish(nil); return }
                if let string = item as? String { finish(string) }
                else if let data = item as? Data { finish(String(data: data, encoding: .utf8)) }
                else { finish(nil) }
            }
        }
    }

    private static func decodedURL(_ item: Any?, fileOnly: Bool) -> URL? {
        var url = item as? URL
        let string = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        if url == nil, let string {
            // Absolute paths are also syntactically valid relative URLs; detect paths first.
            url = string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        }
        if url == nil, fileOnly, let data = item as? Data { url = Bookmark(data: data).resolveURL() }
        guard !fileOnly || url?.isFileURL == true else { return nil }
        return url
    }

    /// A faulty provider cannot keep the shelf spinner or a cancelled import alive forever.
    /// Late callbacks are harmless and the value is resumed exactly once.
    private func providerValue<Value: Sendable>(
        _ load: (@escaping @Sendable (Value?) -> Void) -> Void
    ) async -> Value? {
        let result = CallbackResult<Value?>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            result.cancel(returning: nil)
        }
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                guard !Task.isCancelled else { result.cancel(returning: nil); return }
                load { result.resume(returning: $0) }
            }
        } onCancel: { result.cancel(returning: nil) }
        deadline.cancel()
        return value
    }
}
