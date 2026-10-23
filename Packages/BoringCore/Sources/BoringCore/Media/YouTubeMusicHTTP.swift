import Foundation

/// This integration's bearer belongs to a local companion API, never an arbitrary URL or a
/// redirect destination. URLComponents preserves a validated origin for every request.
public struct YouTubeLocalOrigin: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let port: Int?
    public init(_ baseURL: String) throws {
        guard let c = URLComponents(string: baseURL), let scheme = c.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme), let host = c.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/" else { throw YouTubeMusicError.invalidURL }
        self.scheme = scheme == "ws" ? "http" : scheme == "wss" ? "https" : scheme
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let port = c.port ?? (["https", "wss"].contains(scheme) ? 443 : 80)
        guard (1...65535).contains(port) else { throw YouTubeMusicError.invalidURL }
        self.port = port
    }
    public func url(path: String, webSocket: Bool = false) throws -> URL {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw YouTubeMusicError.invalidURL }
        var c = URLComponents(); c.scheme = webSocket ? (scheme == "https" ? "wss" : "ws") : scheme
        c.host = host.contains(":") ? "[" + host + "]" : host; c.port = port; c.path = path
        guard let url = c.url else { throw YouTubeMusicError.invalidURL }; return url
    }
    public func contains(_ url: URL) -> Bool {
        guard let other = try? Self(URLComponents(url: url, resolvingAgainstBaseURL: false).map {
            var c = $0; c.path = ""; c.query = nil; c.fragment = nil; return c.string ?? ""
        } ?? "") else { return false }
        return other == self
    }
    public static func validateToken(_ token: String) throws {
        guard !token.isEmpty, token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw YouTubeMusicError.authenticationRequired
        }
    }
}

public protocol YouTubeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
final class YouTubeRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: YouTubeLocalOrigin
    init(origin: YouTubeLocalOrigin) { self.origin = origin }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map { origin.contains($0) } == true ? request : nil)
    }
}
public struct YouTubeURLSessionTransport: YouTubeHTTPTransport {
    private let session: URLSession
    public init(origin: YouTubeLocalOrigin) {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 10
        c.httpShouldSetCookies = false; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
        c.connectionProxyDictionary = [:]
        session = URLSession(configuration: c, delegate: YouTubeRedirectDelegate(origin: origin), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw YouTubeMusicError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 * 1024 else { bytes.task.cancel(); throw YouTubeMusicError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
public protocol YouTubeHTTPServing: Sendable {
    func authenticate() async throws -> String
    func playback(token: String) async throws -> YouTubePlaybackPatch
    func likeState(token: String) async throws -> String?
    func command(endpoint: String, method: String, body: Data?, token: String) async throws -> Data
}
public final class YouTubeMusicHTTPClient: YouTubeHTTPServing, Sendable {
    private let origin: YouTubeLocalOrigin?
    private let transport: (any YouTubeHTTPTransport)?
    public init(baseURL: String, transport: (any YouTubeHTTPTransport)? = nil) {
        let scheme = URLComponents(string: baseURL)?.scheme?.lowercased()
        let origin = ["http", "https"].contains(scheme ?? "") ? try? YouTubeLocalOrigin(baseURL) : nil
        self.origin = origin
        self.transport = transport ?? origin.map { YouTubeURLSessionTransport(origin: $0) }
    }
    public func authenticate() async throws -> String {
        let data = try await request(path: "/auth/boringNotch", method: "POST", body: nil, token: nil)
        let token = try JSONDecoder().decode(YouTubeAuthResponse.self, from: data).accessToken
        try YouTubeLocalOrigin.validateToken(token)
        return token
    }
    public func playback(token: String) async throws -> YouTubePlaybackPatch {
        try JSONDecoder().decode(YouTubePlaybackPatch.self, from: await command(endpoint: "/song", method: "GET", body: nil, token: token))
    }
    public func likeState(token: String) async throws -> String? {
        struct Like: Decodable { let state: String? }
        return try JSONDecoder().decode(Like.self, from: await command(endpoint: "/like-state", method: "GET", body: nil, token: token)).state
    }
    public func command(endpoint: String, method: String = "POST", body: Data? = nil, token: String) async throws -> Data {
        try await request(path: "/api/v1" + endpoint, method: method, body: body, token: token)
    }
    private func request(path: String, method: String, body: Data?, token: String?) async throws -> Data {
        guard let origin, let transport else { throw YouTubeMusicError.invalidURL }
        var request = URLRequest(url: try origin.url(path: path)); request.httpMethod = method; request.httpBody = body
        if let token { try YouTubeLocalOrigin.validateToken(token); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport.data(for: request)
        try Task.checkCancellation()
        guard data.count <= 1024 * 1024 else { throw YouTubeMusicError.responseTooLarge }
        guard response.url.map(origin.contains) == true else { throw YouTubeMusicError.invalidResponse }
        switch response.statusCode {
        case 200..<300: return data
        case 401, 403: throw YouTubeMusicError.authenticationRequired
        default: throw YouTubeMusicError.httpError(response.statusCode)
        }
    }
}
