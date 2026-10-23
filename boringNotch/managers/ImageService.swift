import Foundation

public protocol ImageServiceProtocol: Sendable {
    func fetchImageData(from url: URL) async throws -> Data
}

/// Shared transport only; decoding/tint extraction belongs to the presentation pipeline.
/// Every consumer gets its own cancellation ticket and the final waiter cancels the request.
public final class ImageService: ImageServiceProtocol, Sendable {
    public static let shared = ImageService()
    private let transport: ArtworkHTTPTransport
    public init(session: URLSession? = nil) { transport = ArtworkHTTPTransport(session: session) }
    public func fetchImageData(from url: URL) async throws -> Data { try await transport.fetch(url) }
    func fetchImageData(from url: URL, allowedHosts: Set<String>) async throws -> Data {
        try await transport.fetch(url, allowedHosts: allowedHosts)
    }
}

private actor ArtworkHTTPTransport {
    private struct Key: Hashable { let url: URL; let allowedHosts: Set<String>? }
    private struct Entry {
        let id: UUID
        let task: Task<Data, Error>
        var waiters: Set<UUID>
    }
    private let session: URLSession
    private var inFlight: [Key: Entry] = [:]
    init(session: URLSession?) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024,
                                       diskPath: "theboringteam.boringnotch/artwork")
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }
    func fetch(_ url: URL, allowedHosts: Set<String>? = nil) async throws -> Data {
        let key = Key(url: url, allowedHosts: allowedHosts)
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw URLError(.unsupportedURL)
        }
        try Task.checkCancellation()
        let waiter = UUID()
        var entry = inFlight[key] ?? Entry(id: UUID(), task: Task { [session] in
            let (data, response) = try await session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let final = response.url, ["http", "https"].contains(final.scheme?.lowercased() ?? ""),
                  !(url.scheme == "https" && final.scheme != "https"),
                  allowedHosts.map({ $0.contains(final.host?.lowercased() ?? "") && (final.port == nil || final.port == 443) }) ?? true,
                  !data.isEmpty, data.count <= 10_000_000,
                  http.value(forHTTPHeaderField: "Content-Type") == nil
                    || (response.mimeType.map({ $0.hasPrefix("image/") || $0 == "application/octet-stream" }) ?? false) else {
                throw URLError(.badServerResponse)
            }
            return data
        }, waiters: [])
        entry.waiters.insert(waiter); inFlight[key] = entry
        let requestID = entry.id
        let download = entry.task
        do {
            let data = try await withTaskCancellationHandler {
                let result = try await download.value
                try Task.checkCancellation()
                return result
            } onCancel: { [weak self] in
                Task { await self?.release(key, request: requestID, waiter: waiter) }
            }
            release(key, request: requestID, waiter: waiter)
            return data
        } catch {
            release(key, request: requestID, waiter: waiter)
            throw error
        }
    }
    private func release(_ key: Key, request: UUID, waiter: UUID) {
        guard var entry = inFlight[key], entry.id == request else { return }
        entry.waiters.remove(waiter)
        if entry.waiters.isEmpty { entry.task.cancel(); inFlight[key] = nil }
        else { inFlight[key] = entry }
    }
}
