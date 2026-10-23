import Foundation

public protocol YouTubeSocket: Sendable {
    func resume() async throws
    func receive() async throws -> Data
    func close() async
}
public protocol YouTubeSocketFactory: Sendable {
    func makeSocket(for request: URLRequest) async throws -> any YouTubeSocket
}
private struct FoundationYouTubeSocket: YouTubeSocket {
    let task: URLSessionWebSocketTask
    let ownedSession: URLSession?
    func resume() async throws {
        task.resume()
        let result = CallbackResult<Result<Void, any Error>>()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            result.cancel(returning: .failure(URLError(.timedOut)))
            task.cancel(with: .goingAway, reason: nil)
        }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                task.sendPing { error in
                    if let error { result.resume(returning: .failure(error)) }
                    else { result.resume(returning: .success(())) }
                }
            }
        } onCancel: {
            result.cancel(returning: .failure(CancellationError()))
            task.cancel(with: .goingAway, reason: nil)
        }
        deadline.cancel()
        try response.get()
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            guard data.count <= 1024 * 1024 else { throw YouTubeMusicError.responseTooLarge }
            return data
        case .string(let text):
            guard text.utf8.count <= 1024 * 1024 else { throw YouTubeMusicError.responseTooLarge }
            return Data(text.utf8)
        @unknown default: throw YouTubeMusicError.invalidResponse
        }
    }
    func close() async { task.cancel(with: .goingAway, reason: nil); ownedSession?.invalidateAndCancel() }
}
public struct YouTubeURLSessionSocketFactory: YouTubeSocketFactory {
    private let injectedSession: URLSession?
    public init(session: URLSession? = nil) { injectedSession = session }
    public func makeSocket(for request: URLRequest) async throws -> any YouTubeSocket {
        guard let url = request.url else { throw YouTubeMusicError.invalidURL }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["ws", "wss"].contains(components.scheme ?? "") else { throw YouTubeMusicError.invalidURL }
        components.path = ""; components.query = nil; components.fragment = nil
        let origin = try YouTubeLocalOrigin(components.string ?? "")
        let session: URLSession
        if let injectedSession { session = injectedSession }
        else {
            let c = URLSessionConfiguration.ephemeral
            c.connectionProxyDictionary = [:]; c.httpShouldSetCookies = false
            c.httpCookieStorage = nil; c.urlCredentialStorage = nil
            c.timeoutIntervalForRequest = 5
            session = URLSession(configuration: c, delegate: YouTubeRedirectDelegate(origin: origin), delegateQueue: nil)
        }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1024 * 1024
        return FoundationYouTubeSocket(task: task, ownedSession: injectedSession == nil ? session : nil)
    }
}

/// Each receive worker owns only its socket and a weak reference to this coordinator. Old
/// receives cannot clear a replacement connection or request reconnect after intentional stop.
public actor YouTubeMusicWebSocketClient {
    private let factory: any YouTubeSocketFactory
    private let onMessage: @Sendable (Data) async -> Void
    private let onDisconnect: @Sendable () async -> Void
    private var generation = UUID()
    private var socket: (any YouTubeSocket)?
    private var receiveTask: Task<Void, Never>?
    private var connected = false
    public var isConnected: Bool { connected && socket != nil }
    public init(factory: any YouTubeSocketFactory = YouTubeURLSessionSocketFactory(),
                onMessage: @escaping @Sendable (Data) async -> Void,
                onDisconnect: @escaping @Sendable () async -> Void) {
        self.factory = factory; self.onMessage = onMessage; self.onDisconnect = onDisconnect
    }
    public func connect(to url: URL, with token: String) async throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["ws", "wss"].contains(components.scheme?.lowercased() ?? ""),
              components.path == "/api/v1/ws", components.query == nil, components.fragment == nil else { throw YouTubeMusicError.invalidURL }
        var origin = components; origin.path = ""
        _ = try YouTubeLocalOrigin(origin.string ?? "")
        try YouTubeLocalOrigin.validateToken(token)
        let id = UUID(); generation = id
        let old = socket; socket = nil; connected = false
        receiveTask?.cancel(); receiveTask = nil
        await old?.close()
        guard generation == id, !Task.isCancelled else { throw CancellationError() }
        var request = URLRequest(url: url); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let new = try await factory.makeSocket(for: request)
        guard generation == id, !Task.isCancelled else { await new.close(); throw CancellationError() }
        socket = new
        do { try await new.resume() }
        catch {
            if generation == id { socket = nil; connected = false }
            await new.close()
            throw error
        }
        guard generation == id, !Task.isCancelled else {
            if generation == id { socket = nil; connected = false }
            await new.close(); throw CancellationError()
        }
        connected = true
        receiveTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    let data = try await new.receive()
                    guard !Task.isCancelled, await self?.deliver(data, generation: id) == true else { return }
                } catch {
                    if !Task.isCancelled { await self?.receivedError(generation: id) }
                    return
                }
            }
        }
    }
    public func disconnect() async {
        generation = UUID()
        receiveTask?.cancel(); receiveTask = nil
        let old = socket; socket = nil; connected = false
        await old?.close()
    }
    private func deliver(_ data: Data, generation id: UUID) async -> Bool {
        guard generation == id, socket != nil else { return false }
        await onMessage(data)
        return generation == id
    }
    private func receivedError(generation id: UUID) async {
        guard generation == id else { return }
        let terminal = UUID(); generation = terminal
        let old = socket; socket = nil; receiveTask = nil; connected = false
        await old?.close()
        guard generation == terminal else { return }
        await onDisconnect()
    }
    deinit {
        receiveTask?.cancel()
        let old = socket
        Task { await old?.close() }
    }
}
