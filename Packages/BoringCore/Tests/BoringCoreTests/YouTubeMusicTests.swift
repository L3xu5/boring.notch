import Foundation
import Testing
@testable import BoringCore

private enum YouTubeFixtureError: Error { case failed }
private actor YouTubeHTTPFixture: YouTubeHTTPServing {
    var authCalls = 0
    var heldAuthentication = false
    var rejectsAuthentication = false
    var authWaiters: [CheckedContinuation<String, Never>] = []
    var patch = YouTubePlaybackPatch(isPaused: false, title: "Initial", artist: "Artist", elapsedSeconds: 10, songDuration: 200)
    var commands: [String] = []
    var commandBodies: [Data?] = []
    var holdPlayback = false
    var playbackWaiters: [CheckedContinuation<YouTubePlaybackPatch, Never>] = []
    func holdAuthentication() { heldAuthentication = true }
    func rejectAuthentication() { rejectsAuthentication = true }
    func authenticate() async throws -> String {
        authCalls += 1
        if rejectsAuthentication { throw YouTubeFixtureError.failed }
        if heldAuthentication { return await withCheckedContinuation { authWaiters.append($0) } }
        return "fixture-token"
    }
    func completeAuthentication(_ index: Int, token: String) { authWaiters[index].resume(returning: token) }
    func playback(token: String) async throws -> YouTubePlaybackPatch {
        if holdPlayback { return await withCheckedContinuation { playbackWaiters.append($0) } }
        return patch
    }
    func suspendPlayback() { holdPlayback = true }
    func completePlayback(_ patch: YouTubePlaybackPatch) { holdPlayback = false; playbackWaiters.removeFirst().resume(returning: patch) }
    func likeState(token: String) async throws -> String? { nil }
    func command(endpoint: String, method: String, body: Data?, token: String) async throws -> Data {
        commands.append(endpoint); commandBodies.append(body); return Data("{}".utf8)
    }
    func setPatch(_ patch: YouTubePlaybackPatch) { self.patch = patch }
}
private actor YouTubeSocketFixture: YouTubeSocket {
    var receives = 0
    var resumes = 0
    var closes = 0
    var ignoreClose = false
    var holdResume = false
    var resumeWaiter: CheckedContinuation<Void, Never>?
    var waiters: [CheckedContinuation<Data, any Error>] = []
    var queued: [Result<Data, any Error>] = []
    func setIgnoreClose() { ignoreClose = true }
    func suspendResume() { holdResume = true }
    func completeResume() { holdResume = false; resumeWaiter?.resume(); resumeWaiter = nil }
    func resume() async {
        resumes += 1
        if holdResume { await withCheckedContinuation { resumeWaiter = $0 } }
    }
    func receive() async throws -> Data {
        receives += 1
        if !queued.isEmpty { return try queued.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func emit(_ string: String) { finish(.success(Data(string.utf8))) }
    func fail() { finish(.failure(YouTubeFixtureError.failed)) }
    private func finish(_ result: Result<Data, any Error>) {
        if waiters.isEmpty { queued.append(result) }
        else { waiters.removeFirst().resume(with: result) }
    }
    func close() async {
        closes += 1
        guard !ignoreClose else { return }
        let pending = waiters; waiters = []
        pending.forEach { $0.resume(throwing: CancellationError()) }
    }
}
private actor YouTubeSocketFactoryFixture: YouTubeSocketFactory {
    var sockets: [YouTubeSocketFixture]
    var requests: [URLRequest] = []
    init(_ sockets: [YouTubeSocketFixture]) { self.sockets = sockets }
    func makeSocket(for request: URLRequest) async throws -> any YouTubeSocket {
        requests.append(request)
        guard !sockets.isEmpty else { throw YouTubeFixtureError.failed }
        return sockets.removeFirst()
    }
}
private actor YouTubeDeliveryFixture {
    var messages: [String] = []
    var disconnects = 0
    func message(_ data: Data) { messages.append(String(decoding: data, as: UTF8.self)) }
    func disconnected() { disconnects += 1 }
}
private actor YouTubeEnvironmentFixture: YouTubeMusicEnvironment {
    var running: Bool
    var launches = 0
    init(running: Bool = true) { self.running = running }
    func isRunning() async -> Bool { running }
    func launch() async { launches += 1 }
    func setRunning(_ value: Bool) { running = value }
}
private actor YouTubeArtworkFixture: YouTubeArtworkLoading {
    var requested: [String] = []
    var waiters: [String: CheckedContinuation<Data, any Error>] = [:]
    func fetch(from url: URL) async throws -> Data {
        requested.append(url.lastPathComponent)
        return try await withCheckedThrowingContinuation { waiters[url.lastPathComponent] = $0 }
    }
    func finish(_ name: String, data: Data) { waiters.removeValue(forKey: name)?.resume(returning: data) }
}
private final class YouTubeClockFixture: YouTubeMusicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var sleeps: [(Double, CallbackResult<Result<Void, YouTubeFixtureError>>)] = []
    private var registrationCount = 0
    var registrations: Int { lock.withLock { registrationCount } }
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date.addTimeInterval(seconds) } }
    var intervals: [Double] { lock.withLock { sleeps.map(\.0) } }
    func sleep(for seconds: TimeInterval) async throws {
        let result = CallbackResult<Result<Void, YouTubeFixtureError>>()
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                lock.withLock { registrationCount += 1; sleeps.append((seconds, result)) }
            }
        } onCancel: { result.cancel(returning: .failure(.failed)) }
        try value.get()
    }
    func releaseOne(for seconds: Double) {
        let result = lock.withLock { () -> CallbackResult<Result<Void, YouTubeFixtureError>>? in
            guard let index = sleeps.firstIndex(where: { $0.0 == seconds }) else { return nil }
            return sleeps.remove(at: index).1
        }
        result?.resume(returning: .success(()))
    }
    func releaseAll() {
        let pending = lock.withLock { let copy = sleeps; sleeps = []; return copy }
        for (_, result) in pending { result.resume(returning: .success(())) }
    }
}
private func youtubeEventually(_ condition: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw YouTubeFixtureError.failed
}

struct YouTubeMusicTests {
    @Test func authenticationIsSingleFlightAndInvalidationRejectsLateToken() async throws {
        let http = YouTubeHTTPFixture(); await http.holdAuthentication()
        let auth = YouTubeMusicAuthManager(httpClient: http)
        let old = Task { try await auth.authenticate() }
        try await youtubeEventually { await http.authCalls == 1 }
        await auth.invalidateToken()
        let fresh = Task { try await auth.authenticate() }
        try await youtubeEventually { await http.authCalls == 2 }
        await http.completeAuthentication(0, token: "old")
        do { _ = try await old.value; Issue.record("Invalidated authentication was accepted") } catch {}
        #expect(await auth.currentToken == nil)
        await http.completeAuthentication(1, token: "fresh")
        let token = try await fresh.value
        #expect(token == "fresh")
        #expect(await auth.currentToken == "fresh")
        let again = try await auth.authenticate()
        #expect(again == "fresh")
        #expect(await http.authCalls == 2)
    }

    @Test func oldSocketFailureAndIntentionalDisconnectCannotClearReplacement() async throws {
        let first = YouTubeSocketFixture(), second = YouTubeSocketFixture()
        await first.setIgnoreClose()
        let factory = YouTubeSocketFactoryFixture([first, second]), delivery = YouTubeDeliveryFixture()
        let client = YouTubeMusicWebSocketClient(factory: factory,
            onMessage: { await delivery.message($0) }, onDisconnect: { await delivery.disconnected() })
        let url = URL(string: "ws://localhost:26538/api/v1/ws")!
        try await client.connect(to: url, with: "first")
        try await youtubeEventually { await first.receives == 1 }
        try await client.connect(to: url, with: "second")
        try await youtubeEventually { await second.receives == 1 }
        await first.fail()
        await second.emit("replacement")
        try await youtubeEventually { await delivery.messages == ["replacement"] }
        #expect(await client.isConnected)
        #expect(await delivery.disconnects == 0)
        await client.disconnect()
        try await Task.sleep(for: .milliseconds(5))
        #expect(await delivery.disconnects == 0)
    }

    @Test func localOriginNeverAuthorizesRemoteHostOrDifferentScheme() async throws {
        let origin = try YouTubeLocalOrigin("http://localhost:26538")
        #expect(origin.contains(URL(string: "ws://localhost:26538/api/v1/ws")!))
        #expect(!origin.contains(URL(string: "http://example.com:26538/api/v1/song")!))
        #expect(!origin.contains(URL(string: "https://localhost:26538/api/v1/song")!))
        for invalid in ["https://example.com", "file:///tmp/token", "http://user:password@localhost:26538", "http://localhost:26538/path"] {
            #expect(throws: YouTubeMusicError.self) { try YouTubeLocalOrigin(invalid) }
        }
        let ipv6 = try YouTubeLocalOrigin("http://[::1]:26538")
        #expect(try ipv6.url(path: "/song").host == "[::1]" || ipv6.url(path: "/song").host == "::1")
    }

    @Test func incrementalVolumeAndArtworkDoNotInventPauseOrRestoreOldRecording() async throws {
        let http = YouTubeHTTPFixture(), socket = YouTubeSocketFixture(), art = YouTubeArtworkFixture()
        await http.setPatch(.init(isPaused: false, title: "Old", artist: "Artist", elapsedSeconds: 10, songDuration: 200, imageSrc: "https://images.invalid/old"))
        let factory = YouTubeSocketFactoryFixture([socket]), environment = YouTubeEnvironmentFixture(), clock = YouTubeClockFixture()
        let session = YouTubeMusicSession(http: http, socketFactory: factory, environment: environment, artwork: art, clock: clock)
        await session.start()
        try await youtubeEventually { await art.requested.contains("old") }
        try await youtubeEventually { await socket.receives > 0 }
        await socket.emit(#"{"type":"VIDEO_CHANGED","song":{"title":"New","artist":"Artist","elapsedSeconds":40,"songDuration":200,"imageSrc":"https://images.invalid/new","isPaused":false}}"#)
        try await youtubeEventually { await art.requested.contains("new") }
        await art.finish("new", data: Data("new art".utf8))
        try await youtubeEventually { await session.playbackState.artwork == Data("new art".utf8) }
        clock.advance(5)
        await socket.emit(#"{"type":"VOLUME_CHANGED","volume":90}"#)
        try await youtubeEventually { await session.playbackState.volume == 0.9 }
        await art.finish("old", data: Data("stale".utf8))
        await socket.emit(#"{"type":"PLAYER_INFO","song":{"imageSrc":"https://images.invalid/updated"}}"#)
        try await youtubeEventually { await art.requested.contains("updated") }
        await art.finish("updated", data: Data("updated art".utf8))
        try await youtubeEventually { await session.playbackState.artwork == Data("updated art".utf8) }
        let state = await session.playbackState
        #expect(state.title == "New" && state.isPlaying && state.volume == 0.9)
        #expect(state.currentTime == 45)
        await session.stop()
    }

    @Test func intentionalStopDuringBackoffNeverReconnects() async throws {
        let http = YouTubeHTTPFixture(), factory = YouTubeSocketFactoryFixture([]), art = YouTubeArtworkFixture()
        let environment = YouTubeEnvironmentFixture(), clock = YouTubeClockFixture()
        let session = YouTubeMusicSession(http: http, socketFactory: factory, environment: environment, artwork: art, clock: clock)
        await session.start()
        try await youtubeEventually { clock.intervals.contains(1) }
        let attempts = await factory.requests.count
        await session.stop()
        clock.releaseAll()
        try await Task.sleep(for: .milliseconds(5))
        #expect(await factory.requests.count == attempts)
        #expect(await session.isStopped)
    }

    @Test func terminationDoesNotDisableRelaunchAndFinalStopRejectsIt() async throws {
        let http = YouTubeHTTPFixture(), first = YouTubeSocketFixture(), second = YouTubeSocketFixture()
        let factory = YouTubeSocketFactoryFixture([first, second]), environment = YouTubeEnvironmentFixture(running: false)
        let session = YouTubeMusicSession(http: http, socketFactory: factory, environment: environment,
            artwork: YouTubeArtworkFixture(), clock: YouTubeClockFixture())
        await session.start()
        await environment.setRunning(true); await session.applicationStateChanged(isRunning: true)
        try await youtubeEventually { await first.resumes == 1 }
        await environment.setRunning(false); await session.applicationStateChanged(isRunning: false)
        try await youtubeEventually { await first.closes > 0 }
        await environment.setRunning(true); await session.applicationStateChanged(isRunning: true)
        try await youtubeEventually { await second.resumes == 1 }
        await session.stop()
        let requests = await factory.requests.count
        await session.applicationStateChanged(isRunning: true)
        #expect(await factory.requests.count == requests)
    }

    @Test func stoppedSourceCannotSendCommandAfterHeldAuthenticationCompletes() async throws {
        let http = YouTubeHTTPFixture(); await http.holdAuthentication()
        let session = YouTubeMusicSession(http: http, socketFactory: YouTubeSocketFactoryFixture([]),
            environment: YouTubeEnvironmentFixture(), artwork: YouTubeArtworkFixture(), clock: YouTubeClockFixture())
        await session.start()
        try await youtubeEventually { await http.authCalls == 1 }
        let command = Task { await session.nextTrack() }
        session.requestStop()
        await http.completeAuthentication(0, token: "late")
        await command.value
        #expect(await http.commands.isEmpty)
        await session.stop()
    }
}

private actor YouTubeHTTPTransportFixture: YouTubeHTTPTransport {
    var requests: [URLRequest] = []
    let responseURL: URL?
    init(responseURL: URL? = nil) { self.responseURL = responseURL }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data("{}".utf8), HTTPURLResponse(url: responseURL ?? request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
struct YouTubeBoundaryTests {
    @Test func bearerCannotBeSentToInvalidOriginAndCrossOriginResponsesAreRejected() async throws {
        let fake = YouTubeHTTPTransportFixture()
        let invalid = YouTubeMusicHTTPClient(baseURL: "https://example.com", transport: fake)
        do { _ = try await invalid.command(endpoint: "/song", method: "GET", token: "private"); Issue.record("Remote origin accepted") } catch {}
        #expect(await fake.requests.isEmpty)
        let valid = YouTubeMusicHTTPClient(baseURL: "http://localhost:26538", transport: fake)
        _ = try await valid.command(endpoint: "/song", method: "GET", token: "private")
        let sent = try #require(await fake.requests.first)
        #expect(sent.url?.host == "localhost")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer private")
        let foreign = YouTubeHTTPTransportFixture(responseURL: URL(string: "https://example.com/song")!)
        let redirected = YouTubeMusicHTTPClient(baseURL: "http://localhost:26538", transport: foreign)
        do { _ = try await redirected.command(endpoint: "/song", method: "GET", token: "private"); Issue.record("Foreign response accepted") } catch {}
    }
    @Test func redirectDelegateRefusesForwardingAuthenticatedRequestToRemoteHost() async throws {
        let origin = try YouTubeLocalOrigin("http://localhost:26538")
        let delegate = YouTubeRedirectDelegate(origin: origin)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = try origin.url(path: "/api/v1/song")
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var request = URLRequest(url: URL(string: "https://example.com/steal")!)
        request.setValue("Bearer private", forHTTPHeaderField: "Authorization")
        let result = CallbackResult<URLRequest?>()
        let accepted = await withCheckedContinuation { continuation in
            result.install(continuation)
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { result.resume(returning: $0) }
        }
        #expect(accepted == nil)
    }
    @Test func lateHTTPPlaybackCannotReplaceNewerSocketMetadata() async throws {
        let http = YouTubeHTTPFixture(); await http.suspendPlayback()
        let socket = YouTubeSocketFixture()
        let engine = YouTubeMusicSession(http: http, socketFactory: YouTubeSocketFactoryFixture([socket]),
            environment: YouTubeEnvironmentFixture(), artwork: YouTubeArtworkFixture(), clock: YouTubeClockFixture())
        await engine.start()
        try await youtubeEventually { await !http.playbackWaiters.isEmpty }
        try await youtubeEventually { await socket.receives > 0 }
        await socket.emit(#"{"type":"VIDEO_CHANGED","song":{"title":"Socket recording","artist":"Artist","isPaused":false},"volume":75}"#)
        try await youtubeEventually { await engine.playbackState.title == "Socket recording" }
        await http.completePlayback(.init(isPaused: true, title: "Stale HTTP", volume: 10))
        try await Task.sleep(for: .milliseconds(5))
        let state = await engine.playbackState
        #expect(state.title == "Socket recording" && state.volume == 0.75 && state.isPlaying)
        await engine.stop()
    }
}

struct YouTubePowerTests {
    @Test func fallbackPollingCannotBypassAuthenticationBackoff() async throws {
        let http = YouTubeHTTPFixture(); await http.rejectAuthentication()
        let clock = YouTubeClockFixture()
        let session = YouTubeMusicSession(http: http, socketFactory: YouTubeSocketFactoryFixture([]),
            environment: YouTubeEnvironmentFixture(), artwork: YouTubeArtworkFixture(), clock: clock)
        await session.start()
        try await youtubeEventually { clock.intervals.contains(1) && clock.intervals.contains(2) }
        let count = clock.registrations
        clock.releaseOne(for: 2)
        try await youtubeEventually { clock.registrations > count }
        #expect(await http.authCalls == 1)
        await session.stop()
    }
}

struct YouTubeConnectionRaceTests {
    @Test func delayedOldHandshakeCannotReplaceNewConnectedSocket() async throws {
        let first = YouTubeSocketFixture(), second = YouTubeSocketFixture()
        await first.suspendResume(); await first.setIgnoreClose()
        let factory = YouTubeSocketFactoryFixture([first, second]), delivery = YouTubeDeliveryFixture()
        let client = YouTubeMusicWebSocketClient(factory: factory,
            onMessage: { await delivery.message($0) }, onDisconnect: { await delivery.disconnected() })
        let url = URL(string: "ws://localhost:26538/api/v1/ws")!
        let old = Task { try await client.connect(to: url, with: "old") }
        try await youtubeEventually { await first.resumes == 1 }
        #expect(await !client.isConnected)
        try await client.connect(to: url, with: "new")
        await first.completeResume()
        do { try await old.value; Issue.record("Old handshake accepted after replacement") } catch {}
        #expect(await client.isConnected)
        await second.emit("new connection")
        try await youtubeEventually { await delivery.messages == ["new connection"] }
        #expect(await delivery.disconnects == 0)
        await client.disconnect()
    }
}

struct YouTubeCommandBoundsTests {
    @Test func nonFiniteCommandsAreIgnoredAndVolumePayloadIsBounded() async throws {
        let http = YouTubeHTTPFixture()
        let session = YouTubeMusicSession(http: http, socketFactory: YouTubeSocketFactoryFixture([]),
            environment: YouTubeEnvironmentFixture(), artwork: YouTubeArtworkFixture(), clock: YouTubeClockFixture())
        await session.start()
        await session.seek(to: .nan)
        await session.seek(to: .infinity)
        await session.setVolume(.nan)
        #expect(await http.commands.isEmpty)
        await session.setVolume(Double.greatestFiniteMagnitude)
        let bodies = await http.commandBodies
        let data = try #require(bodies.first ?? nil)
        let payload = try JSONDecoder().decode([String: Int].self, from: data)
        #expect(payload["volume"] == 100)
        await session.stop()
    }
}
