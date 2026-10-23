import Foundation

public actor YouTubeMusicAuthManager {
    private let httpClient: any YouTubeHTTPServing
    private var accessToken: String?
    private var generation: UInt64 = 0
    private var authentication: (id: UUID, task: Task<String, any Error>)?
    public init(httpClient: any YouTubeHTTPServing) { self.httpClient = httpClient }
    public var currentToken: String? { accessToken }
    public func authenticate() async throws -> String {
        if let accessToken { return accessToken }
        if let authentication {
            let token = try await authentication.task.value; try Task.checkCancellation(); return token
        }
        let id = UUID(), epoch = generation
        let http = httpClient
        let task = Task { [weak self] in
            do {
                let token = try await http.authenticate()
                try Task.checkCancellation()
                guard let self else { throw CancellationError() }
                return try await self.accept(token, id: id, epoch: epoch)
            } catch {
                await self?.clear(id: id)
                throw error
            }
        }
        authentication = (id, task)
        let token = try await task.value
        try Task.checkCancellation()
        return token
    }
    public func invalidateToken() {
        generation &+= 1; accessToken = nil
        authentication?.task.cancel(); authentication = nil
    }
    private func accept(_ token: String, id: UUID, epoch: UInt64) throws -> String {
        guard generation == epoch, authentication?.id == id else { throw CancellationError() }
        try YouTubeLocalOrigin.validateToken(token)
        accessToken = token; authentication = nil
        return token
    }
    private func clear(id: UUID) { if authentication?.id == id { authentication = nil } }
    deinit { authentication?.task.cancel() }
}
