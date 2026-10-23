import Foundation
import BoringCore

typealias YouTubeMusicHTTPClient = BoringCore.YouTubeMusicHTTPClient
typealias YouTubeMusicWebSocketClient = BoringCore.YouTubeMusicWebSocketClient

struct WebSocketURLBuilder {
    static func buildURL(from baseURL: String) -> URL? {
        try? YouTubeLocalOrigin(baseURL).url(path: "/api/v1/ws", webSocket: true)
    }
}
