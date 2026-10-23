import Foundation

struct ShelfItemDetails: Sendable {
    let fileURL: URL?
    let displayName: String
}

/// Bookmark resolution and filesystem metadata belong to IO work, not SwiftUI body evaluation.
actor ShelfMetadataService {
    static let shared = ShelfMetadataService()
    func details(for item: ShelfItem) -> ShelfItemDetails {
        switch item.kind {
        case .file(let data):
            guard !ShelfStorageEnvironment.isIsolatedPreview else { return .init(fileURL: nil, displayName: "Preview file") }
            guard let url = Bookmark(data: data).resolveURL() else { return .init(fileURL: nil, displayName: "Unavailable file") }
            let name = url.accessSecurityScopedResource { url in
                if let legacy = legacyDisplayName(url) { return legacy }
                return (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
            }
            return .init(fileURL: url, displayName: name)
        case .text(let text): return .init(fileURL: nil, displayName: text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .link(let url):
            let display = url.absoluteString.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            return .init(fileURL: nil, displayName: display)
        }
    }
    private func legacyDisplayName(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1024 * 1024 else { return nil }
        if url.pathExtension.lowercased() == "json", url.pathComponents.contains("TextBlocks"),
           let data = try? Data(contentsOf: url),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let title = object["title"] as? String, !title.isEmpty { return title }
            if let content = object["content"] as? String {
                let firstLine = content.components(separatedBy: .newlines).first ?? content
                return firstLine.count > 50 ? String(firstLine.prefix(47)) + "…" : firstLine
            }
        }
        if url.pathExtension.lowercased() == "webloc", url.pathComponents.contains("WebLocs"),
           let data = try? Data(contentsOf: url),
           let object = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] {
            return (object["Title"] as? String) ?? (object["URL"] as? String)
        }
        return nil
    }

}
