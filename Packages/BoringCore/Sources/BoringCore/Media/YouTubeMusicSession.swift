import Foundation

public struct YouTubeMusicSessionEvent: Sendable {
    public let sequence: UInt64
    public let state: MediaPlaybackState
}

/// Owns source lifetime and bounded work. The native controller is only a workspace/Combine
/// adapter; all auth/socket/reconnect/artwork races can be exercised with injected backends.
private final class YouTubeStopIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isStopped: Bool { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped = true } }
}

public actor YouTubeMusicSession {
    private let stopIntent = YouTubeStopIntent()
    private let configuration: YouTubeMusicConfiguration
    private let http: any YouTubeHTTPServing
    private let auth: YouTubeMusicAuthManager
    private let sockets: any YouTubeSocketFactory
    private let environment: any YouTubeMusicEnvironment
    private let artwork: any YouTubeArtworkLoading
    private let clock: any YouTubeMusicClock
    private let onState: @Sendable (YouTubeMusicSessionEvent) -> Void
    private var state: MediaPlaybackState
    private var started = false
    private var stopped = false
    private var present = false
    private var generation: UInt64 = 0
    private var publication: UInt64 = 0
    private var wireRevision: UInt64 = 0
    private var playbackRequestID: UUID?
    private var connection: (id: UUID, task: Task<Void, Never>)?
    private var reconnect: (id: UUID, task: Task<Void, Never>)?
    private var pollTask: Task<Void, Never>?
    private var artTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var socket: YouTubeMusicWebSocketClient?
    private var socketID: UUID?
    private var socketConnected = false
    private var desiredArtwork: URL?
    private var artworkIdentity: MediaItemIdentity?
    private var artworkRequestID = UUID()
    private var nextReconnectDelay: Double

    public init(configuration: YouTubeMusicConfiguration = .default, http: any YouTubeHTTPServing,
                socketFactory: any YouTubeSocketFactory = YouTubeURLSessionSocketFactory(),
                environment: any YouTubeMusicEnvironment, artwork: any YouTubeArtworkLoading,
                clock: any YouTubeMusicClock = SystemYouTubeMusicClock(),
                onState: @escaping @Sendable (YouTubeMusicSessionEvent) -> Void = { _ in }) {
        self.configuration = configuration; self.http = http; self.auth = YouTubeMusicAuthManager(httpClient: http)
        self.sockets = socketFactory; self.environment = environment; self.artwork = artwork; self.clock = clock; self.onState = onState
        state = .init(bundleIdentifier: configuration.bundleIdentifier)
        nextReconnectDelay = Self.interval(configuration.reconnectDelay.lowerBound, fallback: 1)
    }
    public var playbackState: MediaPlaybackState { state }
    public var isStopped: Bool { stopped || stopIntent.isStopped }
    /// A synchronous native source switch prevents queued commands before actor cleanup runs.
    public nonisolated func requestStop() { stopIntent.stop() }
    public func start() async {
        guard !stopped, !stopIntent.isStopped, !started, !Task.isCancelled else { return }
        started = true
        let epoch = generation
        let running = await environment.isRunning()
        guard !stopped, !stopIntent.isStopped, generation == epoch, !Task.isCancelled else { return }
        applicationStateChanged(isRunning: running)
    }
    public func applicationStateChanged(isRunning: Bool) {
        guard started, !stopped, !stopIntent.isStopped, isRunning != present else { return }
        endApplicationSession()
        present = isRunning
        guard isRunning else { return }
        nextReconnectDelay = Self.interval(configuration.reconnectDelay.lowerBound, fallback: 1)
        let epoch = generation
        scheduleConnection(epoch: epoch)
        startPolling(epoch: epoch)
    }
    public func stop() async {
        guard !stopped else { return }
        stopIntent.stop()
        stopped = true; started = false
        endApplicationSession()
        await cleanupTask?.value
    }
    private func current(_ epoch: UInt64) -> Bool { !stopped && !stopIntent.isStopped && started && present && generation == epoch && !Task.isCancelled }
    private func emit() { publication &+= 1; onState(.init(sequence: publication, state: state)) }
    private func endApplicationSession() {
        generation &+= 1; present = false
        connection?.task.cancel(); connection = nil
        reconnect?.task.cancel(); reconnect = nil
        pollTask?.cancel(); pollTask = nil
        artTask?.cancel(); artTask = nil
        playbackRequestID = nil; artworkRequestID = UUID()
        let old = socket; socket = nil; socketID = nil; socketConnected = false
        let previousCleanup = cleanupTask
        let auth = auth
        cleanupTask = Task { await previousCleanup?.value; await auth.invalidateToken(); await old?.disconnect() }
        desiredArtwork = nil; artworkIdentity = nil
        state = .init(bundleIdentifier: configuration.bundleIdentifier)
        emit()
    }
    private func scheduleConnection(epoch: UInt64) {
        guard current(epoch), connection == nil else { return }
        let id = UUID()
        connection = (id, Task { [weak self] in await self?.connect(epoch: epoch, id: id) })
    }
    private func connect(epoch: UInt64, id: UUID) async {
        defer { if connection?.id == id { connection = nil } }
        await cleanupTask?.value
        guard current(epoch) else { return }
        do {
            let token = try await auth.authenticate()
            guard current(epoch) else { return }
            let origin = try YouTubeLocalOrigin(configuration.baseURL)
            let clientID = UUID()
            let client = YouTubeMusicWebSocketClient(factory: sockets,
                onMessage: { [weak self] data in await self?.receive(data, epoch: epoch, socketID: clientID) },
                onDisconnect: { [weak self] in await self?.socketFailed(epoch: epoch, socketID: clientID) })
            socket = client; socketID = clientID
            try await client.connect(to: origin.url(path: "/api/v1/ws", webSocket: true), with: token)
            guard current(epoch), socketID == clientID else { await client.disconnect(); return }
            socketConnected = true
            nextReconnectDelay = Self.interval(configuration.reconnectDelay.lowerBound, fallback: 1)
            await updatePlaybackInfo()
        } catch {
            guard current(epoch) else { return }
            socketConnected = false
            scheduleReconnect(epoch: epoch)
        }
    }
    private func socketFailed(epoch: UInt64, socketID id: UUID) {
        guard current(epoch), socketID == id else { return }
        socket = nil; socketID = nil; socketConnected = false
        startPolling(epoch: epoch)
        scheduleReconnect(epoch: epoch)
    }
    private func scheduleReconnect(epoch: UInt64) {
        guard current(epoch), reconnect == nil else { return }
        let id = UUID(), delay = nextReconnectDelay, clock = clock
        let ceiling = Self.interval(configuration.reconnectDelay.upperBound, fallback: 60)
        nextReconnectDelay = min(ceiling, delay * 2)
        reconnect = (id, Task.detached { [weak self] in
            do { try await clock.sleep(for: delay) } catch { return }
            await self?.retryConnection(epoch: epoch, id: id)
        })
    }
    private func retryConnection(epoch: UInt64, id: UUID) {
        guard reconnect?.id == id else { return }
        reconnect = nil
        guard current(epoch) else { return }
        if connection != nil { scheduleReconnect(epoch: epoch) }
        else { scheduleConnection(epoch: epoch) }
    }
    private func startPolling(epoch: UInt64) {
        pollTask?.cancel()
        let clock = clock
        pollTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.pollOnce(epoch: epoch) else { return }
                do { try await clock.sleep(for: delay) } catch { return }
            }
        }
    }
    private func pollOnce(epoch: UInt64) async -> Double? {
        guard current(epoch) else { return nil }
        let running = await environment.isRunning()
        guard current(epoch) else { return nil }
        guard running else { applicationStateChanged(isRunning: false); return nil }
        // Authentication retries belong to the reconnect worker. Polling must not bypass
        // its backoff and repeatedly open the companion's authorization dialog.
        if await auth.currentToken != nil { await updatePlaybackInfo() }
        guard current(epoch) else { return nil }
        return Self.interval(socketConnected ? configuration.connectedHealthInterval : configuration.updateInterval, fallback: 2)
    }
    public func updatePlaybackInfo() async {
        let epoch = generation
        guard current(epoch) else { return }
        await cleanupTask?.value
        guard current(epoch), playbackRequestID == nil else { return }
        let requestID = UUID(), wire = wireRevision
        playbackRequestID = requestID
        defer { if playbackRequestID == requestID { playbackRequestID = nil } }
        do {
            let token = try await auth.authenticate()
            guard current(epoch), playbackRequestID == requestID else { return }
            let patch = try await http.playback(token: token)
            guard current(epoch), playbackRequestID == requestID, wireRevision == wire else { return }
            apply(patch, epoch: epoch)
            let identity = state.identity
            do {
                let like = try await http.likeState(token: token)
                guard current(epoch), state.identity == identity else { return }
                let favorite = like?.uppercased() == "LIKE"
                if state.isFavorite != favorite { state.isFavorite = favorite; emit() }
            } catch { /* Older companion versions may not expose like-state. */ }
        } catch YouTubeMusicError.authenticationRequired {
            guard current(epoch) else { return }
            await auth.invalidateToken()
            guard current(epoch) else { return }
            scheduleReconnect(epoch: epoch)
        } catch { }
    }
    private func receive(_ data: Data, epoch: UInt64, socketID id: UUID) {
        guard current(epoch), socketID == id, let patch = YouTubePlaybackPatch.socketMessage(data) else { return }
        wireRevision &+= 1
        apply(patch, epoch: epoch)
    }
    private func apply(_ patch: YouTubePlaybackPatch, epoch: UInt64) {
        guard current(epoch) else { return }
        let previous = state
        let now = clock.now()
        state.currentTime = state.timeline.position(at: now)
        if let paused = patch.isPaused { state.isPlaying = !paused }
        if patch.clearedFields.contains(.title) { state.title = "" } else if let title = patch.title { state.title = title }
        if patch.clearedFields.contains(.artist) { state.artist = "" } else if let artist = patch.artist { state.artist = artist }
        if patch.clearedFields.contains(.album) { state.album = "" } else if let album = patch.album { state.album = album }
        if patch.clearedFields.contains(.videoId) { state.nativeTrackID = nil } else if let id = patch.videoId { state.nativeTrackID = id }
        let recordingChanged = state.nativeTrackID != previous.nativeTrackID || state.title != previous.title || state.artist != previous.artist
        if recordingChanged {
            state.artwork = nil; state.isFavorite = false
            if patch.elapsedSeconds == nil { state.currentTime = 0 }
            if patch.songDuration == nil { state.duration = 0 }
            desiredArtwork = nil
        }
        if let elapsed = patch.elapsedSeconds, elapsed.isFinite { state.currentTime = max(0, elapsed) }
        if let duration = patch.songDuration, duration.isFinite { state.duration = max(0, duration) }
        if let volume = patch.volume, volume.isFinite { state.volume = max(0, min(1, volume / 100)) }
        if let shuffle = patch.isShuffled { state.isShuffled = shuffle }
        if let mode = patch.repeatMode { state.repeatMode = Self.repeatMode(mode) ?? state.repeatMode }
        if patch.clearedFields.contains(.imageSrc) { desiredArtwork = nil; state.artwork = nil }
        else if let source = patch.imageSrc {
            desiredArtwork = URL(string: source).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            if desiredArtwork == nil { state.artwork = nil }
        }
        state.lastUpdated = now
        if desiredArtwork != artworkURL || state.identity != artworkIdentity { fetchArtwork(epoch: epoch) }
        emit()
    }
    private var artworkURL: URL?
    private func fetchArtwork(epoch: UInt64) {
        artTask?.cancel(); artTask = nil
        artworkURL = desiredArtwork; artworkIdentity = state.identity
        let id = UUID(); artworkRequestID = id
        guard let url = desiredArtwork else { return }
        let identity = state.identity, loader = artwork
        artTask = Task.detached { [weak self] in
            do {
                let data = try await loader.fetch(from: url)
                try Task.checkCancellation()
                await self?.acceptArtwork(data, identity: identity, requestID: id, epoch: epoch)
            } catch { }
        }
    }
    private func acceptArtwork(_ data: Data, identity: MediaItemIdentity, requestID: UUID, epoch: UInt64) {
        guard current(epoch), artworkRequestID == requestID, state.identity == identity else { return }
        state.artwork = data; emit()
    }
    public func play() async { _ = await command("/play") }
    public func pause() async { _ = await command("/pause") }
    public func nextTrack() async { _ = await command("/next") }
    public func previousTrack() async { _ = await command("/previous") }
    public func togglePlay() async {
        guard !stopped, !stopIntent.isStopped else { return }
        if !present { await environment.launch(); return }
        _ = await command("/toggle-play")
    }
    public func seek(to time: Double) async {
        guard time.isFinite else { return }
        let value = state.duration > 0 ? min(state.duration, max(0, time)) : max(0, time)
        _ = await command("/seek-to", body: try? JSONEncoder().encode(["seconds": value]))
    }
    public func setVolume(_ level: Double) async {
        guard level.isFinite else { return }
        _ = await command("/volume", body: try? JSONEncoder().encode(["volume": Int(min(1, max(0, level)) * 100)]))
    }
    public func setFavorite(_ favorite: Bool) async {
        guard favorite != state.isFavorite else { return }
        let identity = state.identity, epoch = generation
        if await command("/like", refresh: false, requiredIdentity: identity) != nil, current(epoch), state.identity == identity {
            state.isFavorite = favorite; emit()
        }
    }
    public func toggleShuffle() async { await refreshShuffle(method: "POST") }
    public func fetchShuffleState() async { await refreshShuffle(method: "GET") }
    public func fetchRepeatMode() async { await refreshRepeat(endpoint: "/repeat-mode", method: "GET") }
    public func toggleRepeat() async { await refreshRepeat(endpoint: "/switch-repeat", method: "POST") }
    private func refreshShuffle(method: String) async {
        let previous = state.isShuffled, epoch = generation
        guard let data = await command("/shuffle", method: method, refresh: false), current(epoch) else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let value = json?["state"] as? Bool { state.isShuffled = value }
        else if method == "POST", state.isShuffled == previous { state.isShuffled.toggle() }
        emit()
    }
    private func refreshRepeat(endpoint: String, method: String) async {
        let previous = state.repeatMode, epoch = generation
        guard let data = await command(endpoint, method: method, refresh: false), current(epoch) else { return }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let mode = json?["mode"] as? String { state.repeatMode = ["NONE": .off, "ALL": .all, "ONE": .one][mode.uppercased()] ?? state.repeatMode }
        else if method == "POST", state.repeatMode == previous { state.repeatMode = previous == .off ? .all : previous == .all ? .one : .off }
        emit()
    }
    private func command(_ endpoint: String, method: String = "POST", body: Data? = nil, refresh: Bool = true,
                         requiredIdentity: MediaItemIdentity? = nil) async -> Data? {
        let epoch = generation
        guard current(epoch) else { return nil }
        await cleanupTask?.value
        guard current(epoch) else { return nil }
        do {
            let token = try await auth.authenticate()
            guard current(epoch), requiredIdentity == nil || requiredIdentity == state.identity else { return nil }
            let data = try await http.command(endpoint: endpoint, method: method, body: body, token: token)
            guard current(epoch), requiredIdentity == nil || requiredIdentity == state.identity else { return nil }
            if refresh { await updatePlaybackInfo() }
            guard current(epoch) else { return nil }
            return data
        } catch YouTubeMusicError.authenticationRequired {
            guard current(epoch) else { return nil }
            await auth.invalidateToken()
            guard current(epoch) else { return nil }
            scheduleReconnect(epoch: epoch)
            return nil
        } catch { return nil }
    }
    private static func repeatMode(_ value: Int) -> MediaRepeatMode? { [0: .off, 1: .all, 2: .one][value] }
    private static func interval(_ value: Double, fallback: Double) -> Double { value.isFinite ? min(300, max(0.01, value)) : fallback }
    deinit {
        stopIntent.stop()
        connection?.task.cancel(); reconnect?.task.cancel(); pollTask?.cancel(); artTask?.cancel()
        let socket = socket, auth = auth
        Task { await auth.invalidateToken(); await socket?.disconnect() }
    }
}
