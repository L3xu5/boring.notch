import Foundation

/// Exact-id enrichment is independent of AX IPC, session routing and UI presentation.
actor YandexMediaAPIClient {
    static let shared = YandexMediaAPIClient()
    private let session: URLSession
    private let images: ImageService
    init(session: URLSession = MediaHTTPSession.shared) { self.session = session; images = ImageService(session: session) }
    func artwork(for metadata: YandexAccessibilityMetadata, token: String) async -> Data? {
        guard !Task.isCancelled else { return nil }
        var artworkURL = metadata.artworkURL
        if artworkURL == nil, let id = metadata.trackID,
           let url = URL(string: "https://api.music.yandex.net/tracks/\(id)") {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")
            if !token.isEmpty { request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               response.url?.scheme == "https", response.url?.host == "api.music.yandex.net",
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tracks = json["result"] as? [[String: Any]], let cover = tracks.first?["coverUri"] as? String {
                let path = cover.replacingOccurrences(of: "%%", with: "200x200")
                artworkURL = URL(string: path.hasPrefix("https://") ? path : "https://" + path)
            }
        }
        guard !Task.isCancelled, let artworkURL, YandexAccessibilityMetadata.isTrustedArtworkURL(artworkURL) else { return nil }
        return try? await images.fetchImageData(from: artworkURL,
            allowedHosts: ["avatars.yandex.net", "avatars.mds.yandex.net"])
    }
}
