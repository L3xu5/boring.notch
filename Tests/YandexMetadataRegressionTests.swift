// This file is appended to the production controller by test_yandex_metadata.py so fixtures
// can exercise private wire decoding, state reduction and AX parsing without test-only app APIs.
private final class YandexMusicTokenStore {
    static let shared = YandexMusicTokenStore()
    let token = ""
}

private struct YandexMetadataFailure: Error, CustomStringConvertible {
    let description: String
}

private actor MetadataGetFixture {
    private var response: MediaWireUpdate?
    private var delayed = false
    private var waiters: [CheckedContinuation<MediaWireUpdate?, Never>] = []
    private(set) var reads = 0
    var pending: Int { waiters.count }
    init(_ response: MediaWireUpdate? = nil) { self.response = response }
    func set(_ response: MediaWireUpdate?) { self.response = response }
    func delay() { delayed = true }
    func read() async -> MediaWireUpdate? {
        reads += 1
        if delayed { return await withCheckedContinuation { waiters.append($0) } }
        return response
    }
    func finish(_ response: MediaWireUpdate?, index: Int = 0) { waiters.remove(at: index).resume(returning: response) }
}

@MainActor private final class MetadataClockFixture { var now: TimeInterval = 100 }

private func favoriteMetadata(_ favorite: Bool?, title: String = "Before", artist: String = "Artist",
                              trackID: String? = nil, album: String = "") -> YandexAccessibilityMetadata {
    let trackURL = trackID.flatMap { URL(string: "music-application://desktop/album/123/track/\($0)") }
    return YandexAccessibilityMetadata(root: .init(role: "AXGroup", labels: [], value: nil, url: nil, children: [
        .init(role: "AXLink", labels: ["Track \(title)"], value: nil, url: trackURL, children: []),
        .init(role: "AXLink", labels: ["Artist \(artist)"], value: nil,
              url: URL(string: "music-application://desktop/artist/1"), children: []),
        .init(role: "AXCheckBox", labels: ["Like"], value: favorite.map { $0 ? "1" : "0" }, url: nil, children: []),
        .init(role: "AXLink", labels: album.isEmpty ? [] : ["Album \(album)"], value: nil,
              url: album.isEmpty ? nil : URL(string: "music-application://desktop/album/123"), children: []),
    ]))!
}

private actor DelayedYandexAX: YandexAccessibilityProviding {
    private var actions: [YandexPlayerAction] = []
    private var actionWaiters: [CheckedContinuation<Bool, Never>] = []
    private var favoriteWaiters: [CheckedContinuation<YandexAccessibilityMetadata?, Never>] = []
    var pendingActions: Int { actionWaiters.count }
    var pendingFavorites: Int { favoriteWaiters.count }
    var performedCount: Int { actions.count }
    var performedActions: [String] { actions.map { String(describing: $0) } }
    private(set) var favoriteTargets: [YandexFavoriteTarget] = []
    private(set) var setRequests: [Bool] = []
    private var fullMetadataUnavailable = false
    private var delayPlayback = false
    private var playing: Bool?
    private var playbackWaiters: [CheckedContinuation<Bool?, Never>] = []
    var pendingPlaybackReads: Int { playbackWaiters.count }
    func setDelayPlayback() { delayPlayback = true }
    func setPlaybackState(_ playing: Bool?) { self.playing = playing }
    func playbackState(processIdentifier: pid_t) async -> Bool? {
        if delayPlayback { return await withCheckedContinuation { playbackWaiters.append($0) } }
        return playing
    }
    func finishPlayback(_ playing: Bool?, index: Int = 0) { playbackWaiters.remove(at: index).resume(returning: playing) }
    func setFullMetadataUnavailable() { fullMetadataUnavailable = true }
    func read(processIdentifier: pid_t) async -> YandexAccessibilityMetadata? {
        if fullMetadataUnavailable { return nil }
        return await delayedSnapshot()
    }
    private func delayedSnapshot() async -> YandexAccessibilityMetadata? {
        await withCheckedContinuation { favoriteWaiters.append($0) }
    }
    func perform(_ action: YandexPlayerAction, processIdentifier: pid_t,
                 isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        let success = await withCheckedContinuation { actionWaiters.append($0) }
        guard success, !Task.isCancelled, isCurrent() else { return false }
        actions.append(action)
        return true
    }
    func favoriteState(processIdentifier: pid_t) -> Bool? { nil }
    func favoriteState(processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget) async -> Bool? {
        guard let metadata = await delayedSnapshot(), expectedTrack.matches(metadata) else { return nil }
        return metadata.isFavorite
    }
    func setFavorite(_ favorite: Bool, processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget,
                     isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        setRequests.append(favorite)
        favoriteTargets.append(expectedTrack)
        return await perform(.like, processIdentifier: processIdentifier, isCurrent: isCurrent)
    }
    func toggleFavorite(processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget,
                        isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        favoriteTargets.append(expectedTrack)
        return await perform(.like, processIdentifier: processIdentifier, isCurrent: isCurrent)
    }
    func finishAction(_ result: Bool, index: Int = 0) { actionWaiters.remove(at: index).resume(returning: result) }
    func finishFavorite(_ result: Bool?) { finishSnapshot(favoriteMetadata(result)) }
    func finishSnapshot(_ result: YandexAccessibilityMetadata?, index: Int = 0) {
        favoriteWaiters.remove(at: index).resume(returning: result)
    }
}

private actor SnapshotYandexAX: YandexAccessibilityProviding {
    private var metadata: YandexAccessibilityMetadata?
    private var receipt = false
    private var afterAction: YandexAccessibilityMetadata?
    private(set) var readCount = 0
    private(set) var attempts = 0
    private(set) var accepted = 0
    private(set) var favoriteTargets: [YandexFavoriteTarget] = []
    private var scopedMetadata: YandexAccessibilityMetadata?
    private var useScopedMetadata = false
    private var satisfiedSet: YandexAccessibilityMetadata?
    private(set) var scopedReadCount = 0
    private(set) var setRequests: [Bool] = []
    private var independentPlaying: Bool?
    private var useIndependentPlaying = false
    private(set) var playbackReadCount = 0
    init(_ metadata: YandexAccessibilityMetadata?) { self.metadata = metadata }
    func setSnapshot(_ metadata: YandexAccessibilityMetadata?) { self.metadata = metadata }
    func setPlaybackState(_ playing: Bool?) { independentPlaying = playing; useIndependentPlaying = true }
    func playbackState(processIdentifier: pid_t) async -> Bool? {
        playbackReadCount += 1
        return useIndependentPlaying ? independentPlaying : metadata?.isPlaying
    }
    func setScopedSnapshot(_ metadata: YandexAccessibilityMetadata?) {
        scopedMetadata = metadata; useScopedMetadata = true
    }
    func satisfySetWithoutPress(_ metadata: YandexAccessibilityMetadata) { satisfiedSet = metadata }
    func setReceipt(_ receipt: Bool, afterAction: YandexAccessibilityMetadata? = nil) {
        self.receipt = receipt; self.afterAction = afterAction
    }
    func read(processIdentifier: pid_t) -> YandexAccessibilityMetadata? {
        readCount += 1
        return metadata
    }
    func favoriteState(processIdentifier: pid_t) -> Bool? { nil }
    func favoriteState(processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget) async -> Bool? {
        scopedReadCount += 1
        guard let metadata = useScopedMetadata ? scopedMetadata : metadata,
              expectedTrack.matches(metadata) else { return nil }
        return metadata.isFavorite
    }
    func setFavorite(_ favorite: Bool, processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget,
                     isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        setRequests.append(favorite)
        favoriteTargets.append(expectedTrack)
        guard !Task.isCancelled, isCurrent() else { return false }
        if let satisfiedSet {
            if useScopedMetadata { scopedMetadata = satisfiedSet }
            else { metadata = satisfiedSet }
            return true
        }
        return perform(.like, processIdentifier: processIdentifier, isCurrent: isCurrent)
    }
    func toggleFavorite(processIdentifier: pid_t, expectedTrack: YandexFavoriteTarget,
                        isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        favoriteTargets.append(expectedTrack)
        return perform(.like, processIdentifier: processIdentifier, isCurrent: isCurrent)
    }
    func perform(_ action: YandexPlayerAction, processIdentifier: pid_t,
                 isCurrent: @escaping @Sendable () -> Bool) -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        attempts += 1
        guard receipt else { return false }
        accepted += 1
        if let afterAction {
            if useScopedMetadata { scopedMetadata = afterAction }
            else { metadata = afterAction }
        }
        return true
    }
}

private actor FavoriteQueueGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var ready: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class PlaybackPIDBox { var value: pid_t? = 42 }

@MainActor
private final class FavoriteProtocolFixture: MediaControllerProtocol {
    let playbackStatePublisher = Just(PlaybackState(bundleIdentifier: "fixture")).eraseToAnyPublisher()
    let supportsVolumeControl = false
    var supportsFavorite = true
    var currentFavoriteState: Bool?
    private(set) var requested: [Bool] = []
    func setFavorite(_ favorite: Bool) async { requested.append(favorite) }
    func play() async {}
    func pause() async {}
    func seek(to time: Double) async {}
    func nextTrack() async {}
    func previousTrack() async {}
    func togglePlay() async {}
    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {}
    func isActive() -> Bool { true }
    func updatePlaybackInfo() async {}
}

private final class YandexMetadataURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var respond: ((URLRequest) -> (URL, Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        guard let (url, status, data) = Self.respond?(request),
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension YandexMusicController {
    var metadataTestProcess: Process? { process }
    var metadataTestReader: Task<Void, Never>? { streamTask }
    @MainActor func metadataTestApplyAX(_ node: YandexAccessibilityNode) {
        if let metadata = YandexAccessibilityMetadata(root: node) {
            applyAccessibilityMetadata(metadata, generation: accessibilityGeneration)
            if let (_, request) = playbackRequest() { receivePlaybackState(metadata.isPlaying, request: request) }
        }
    }
    @MainActor func metadataTestPrimeArtwork(_ key: String) -> UInt {
        accessibilityArtworkKey = key
        return accessibilityArtworkGeneration
    }
    @MainActor func metadataTestFinishArtwork(_ data: Data?, key: String, generation: UInt) {
        applyAccessibilityArtwork(data, key: key, generation: generation)
    }
    @MainActor func metadataTestUpdate(_ payload: [String: Any], diff: Bool = true) async throws {
        let data = try JSONSerialization.data(withJSONObject: ["diff": diff, "payload": payload])
        await handleAdapterUpdate(try JSONDecoder().decode(YandexNowPlayingUpdate.self, from: data))
    }
    @MainActor func metadataTestRefreshFavorite() async { await refreshFavoriteState() }
    @MainActor func metadataTestStartMonitoring() { startAccessibilityMonitoring() }
    @MainActor func metadataTestStartPlayingMonitoring() { startPlaybackMonitoring() }
    @MainActor func metadataTestRefreshPlaying() async { await refreshPlaybackState() }
    @MainActor var metadataTestPlaybackTask: Task<Void, Never>? { playbackTask }
    @MainActor func metadataTestTerminate(processIdentifier: pid_t? = nil) { handleYandexTerminated(processIdentifier: processIdentifier) }
    @MainActor func metadataTestReset() { resetAdapterState() }
    @MainActor func metadataTestNativeTrackID(_ id: String) { playbackState.nativeTrackID = id }
    @MainActor func metadataTestSkipArtwork(_ key: String) {
        accessibilityArtworkKey = key
        accessibilityArtworkRetryAfter = .distantFuture
    }
    @MainActor func metadataTestExpireFavoriteEvidence() {
        if let id = favoriteEvidence?.id { expireFavoriteEvidence(id) }
    }
    @MainActor var metadataTestFavoriteEvidenceTask: Task<Void, Never>? { favoriteEvidenceExpiryTask }
    @MainActor var metadataTestFavoriteQueueID: UUID? { favoriteQueueTailID }
    @MainActor func metadataTestPredecessor(_ task: Task<Void, Never>) { favoriteQueueTail = task; favoriteQueueTailID = UUID() }
    @MainActor func metadataTestEnqueueToggle() -> Task<Void, Never>? { enqueueFavoriteCommand(.toggle) }
    static func metadataTestFetchArtwork(_ node: YandexAccessibilityNode, token: String,
                                         session: URLSession) async -> Data? {
        guard let metadata = YandexAccessibilityMetadata(root: node) else { return nil }
        return await fetchAccessibilityArtwork(metadata, token: token, session: session)
    }
}

@main
private struct YandexMetadataRegressionTests {
    private static var passed = 0

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw YandexMetadataFailure(description: message) }
    }

    @MainActor
    private static func waitFor(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition() {
            guard Date() < deadline else { throw YandexMetadataFailure(description: message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor
    private static func waitForAX(_ message: String, condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { throw YandexMetadataFailure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private static func expectPassiveRefreshSkipped(_ controller: YandexMusicController,
                                                   client: DelayedYandexAX, phase: String) async throws {
        let before = await client.pendingFavorites
        var finished = false
        let refresh = Task { await controller.refreshAccessibilityMetadata(); finished = true }
        try await waitFor("Passive refresh competed with the explicit favorite command during \(phase)") { finished }
        await refresh.value
        let after = await client.pendingFavorites
        try expect(after == before, "Passive favorite polling scheduled an AX read during \(phase)")
    }

    @MainActor
    private static func delayedAXLifecycle() async throws {
        for result in [false, true] {
            let client = DelayedYandexAX()
            var unavailable = 0
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: { unavailable += 1 }, startMonitoring: false)!
            let operation = Task { await controller.play() }
            try await waitForAX("transport did not enter injected AX") { await client.pendingActions == 1 }
            controller.stop()
            await client.finishAction(result)
            await operation.value
            let effects = await client.performedCount
            try expect(effects == 0 && unavailable == 0 && !controller.playbackState.isPlaying,
                       "Stopped source performed AX/launch/prompt/optimistic effects after an awaited result")
            passed += 1
            print("PASS delayed AX transport after stop (result \(result))")
        }
        do {
            let client = DelayedYandexAX()
            var unavailable = 0
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: { unavailable += 1 }, startMonitoring: false)!
            let operation = Task { await controller.togglePlay() }
            try await waitForAX("cancelled transport did not enter AX") { await client.pendingActions == 1 }
            operation.cancel()
            await client.finishAction(true)
            await operation.value
            let effects = await client.performedCount
            try expect(effects == 0 && unavailable == 0 && !controller.playbackState.isPlaying,
                       "Cancelled source command still changed playback or requested a fallback")
            controller.stop()
            passed += 1
            print("PASS cancelled AX transport has no side effects")
        }
        for settingFavorite in [false, true] {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let operation = Task {
                if settingFavorite { await controller.setFavorite(true) }
                else { await controller.metadataTestRefreshFavorite() }
            }
            try await waitForAX("favorite did not enter injected AX") { await client.pendingFavorites == 1 }
            try await controller.metadataTestUpdate(["title": "After", "artist": "New artist"])
            await client.finishFavorite(!settingFavorite)
            await operation.value
            let effects = await client.performedCount
            try expect(effects == 0 && controller.playbackState.title == "After" && !controller.playbackState.isFavorite,
                       "A previous track's late favorite read changed the new track or pressed its like button")
            controller.stop()
            try await controller.metadataTestUpdate(["title": "Queued after stop"])
            try expect(controller.playbackState.title == "After", "Stopped source accepted an already-queued adapter callback")
            passed += 1
            print("PASS stale favorite read and queued metadata after stop (set \(settingFavorite))")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let operation = Task { await controller.setFavorite(true) }
            try await waitForAX("favorite read did not start") { await client.pendingFavorites == 1 }
            await client.finishFavorite(false)
            try await waitForAX("like press did not enter AX") { await client.pendingActions == 1 }
            try await controller.metadataTestUpdate(["title": "After"])
            await client.finishAction(true)
            await operation.value
            let effects = await client.performedCount
            try expect(effects == 0 && !controller.playbackState.isFavorite, "A like lookup already in flight pressed the next track's control")
            controller.stop()
            passed += 1
            print("PASS favorite action validates track ticket at the side effect")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Track", "playing": true], diff: false)
            let operation = Task { await controller.togglePlay() }
            try await waitForAX("toggle did not enter AX") { await client.pendingActions == 1 }
            try await controller.metadataTestUpdate(["playing": false])
            await client.finishAction(true)
            await operation.value
            let effects = await client.performedCount
            try expect(effects == 0 && !controller.playbackState.isPlaying,
                       "A stale AX toggle resumed playback after a newer native pause")
            controller.stop()
            passed += 1
            print("PASS newer native transport observation cancels an unaccepted AX toggle")
        }
    }

    @MainActor
    private static func favoriteReconciliation() async throws {
        for foreignOwner in [false, true] {
            let client = SnapshotYandexAX(favoriteMetadata(false))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            if foreignOwner {
                try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser media", "playing": false], diff: false)
            }
            controller.metadataTestStartMonitoring()
            try await waitFor("initial AX favorite was not observed") { controller.currentFavoriteState != nil }
            try expect(!controller.playbackState.isFavorite, "Initial unliked track was shown liked")
            await client.setSnapshot(favoriteMetadata(true))
            try await waitFor("same-track like made in Yandex was not reconciled") { controller.playbackState.isFavorite }
            await client.setSnapshot(favoriteMetadata(false))
            try await waitFor("same-track unlike made in Yandex stayed cached forever") { !controller.playbackState.isFavorite }
            try expect(controller.currentFavoriteState != nil && controller.playbackState.title == "Before",
                       "Reconciliation lost current metadata or known-state capability")
            if foreignOwner {
                try expect(controller.systemMediaOwnerBundleIdentifier == "com.apple.Safari",
                           "Favorite polling changed the system session owner")
            }
            let attempts = await client.attempts
            try expect(attempts == 0, "Read-only favorite reconciliation pressed a player control")
            controller.stop()
            passed += 1
            print("PASS continuous same-track favorite reconciliation (foreign owner \(foreignOwner))")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true, title: "Previous track"))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil && controller.capabilities.favorite,
                       "A previous track's lazily rebuilt AX control supplied the new track's like")
            await client.setSnapshot(favoriteMetadata(false))
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.capabilities.favorite,
                       "A later matching snapshot could not correct the first stale AX read")
            controller.metadataTestNativeTrackID("2")
            await client.setSnapshot(favoriteMetadata(true, trackID: "1"))
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil && controller.capabilities.favorite,
                       "Different recording IDs with the same title/artist shared a favorite")
            controller.stop()
            passed += 1
            print("PASS favorite snapshots match current track metadata and exact recording ID")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true))
            let clock = MetadataClockFixture()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false, metadataClock: { clock.now })!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.playbackState.isFavorite && controller.currentFavoriteState != nil, "Known liked snapshot was lost")
            await client.setSnapshot(favoriteMetadata(nil))
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true, "One unknown read discarded recent matching evidence")
            clock.now += 3.1
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "Expired unknown pressed state retained a false positive like")
            await controller.setFavorite(true)
            let attempts = await client.attempts
            try expect(attempts == 0, "Unknown favorite state caused a blind toggle")
            await client.setSnapshot(favoriteMetadata(true))
            await controller.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            await controller.refreshAccessibilityMetadata()
            clock.now += 3.1
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "A missing/untrusted AX snapshot left an old like cached")
            controller.stop()
            passed += 1
            print("PASS unknown and unavailable favorite evidence expires without a blind toggle")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let older = Task { await controller.refreshAccessibilityMetadata() }
            try await waitForAX("older favorite read did not enter AX") { await client.pendingFavorites == 1 }
            let newer = Task { await controller.refreshAccessibilityMetadata() }
            try await waitForAX("newer favorite read did not enter AX") { await client.pendingFavorites == 2 }
            await client.finishSnapshot(favoriteMetadata(false), index: 1)
            await newer.value
            await client.finishSnapshot(favoriteMetadata(true))
            await older.value
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState != nil,
                       "An older same-track read overwrote the newer unlike observation")
            controller.stop()
            passed += 1
            print("PASS reversed same-track favorite reads retain the newest observation")
        }
        for transition in ["stop", "terminate", "reset"] {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let seed = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("seed favorite read did not enter AX") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await seed.value
            try expect(controller.playbackState.isFavorite, "Lifecycle fixture did not start with a known like")
            let pending = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("pending lifecycle favorite did not enter AX") { await client.pendingFavorites == 1 }
            switch transition {
            case "stop": controller.stop()
            case "terminate": controller.metadataTestTerminate()
            default: controller.metadataTestReset()
            }
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "\(transition) retained a previous session's liked state")
            await client.finishFavorite(true)
            await pending.value
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "An AX read completed after \(transition) and restored an old like")
            controller.stop()
            passed += 1
            print("PASS favorite invalidation after \(transition) rejects late AX reads")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(false))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.setFavorite(true)
            let failedAttempts = await client.attempts
            let failedAccepted = await client.accepted
            try expect(failedAttempts == 1 && failedAccepted == 0 && !controller.playbackState.isFavorite,
                       "A failed AX press was presented as an accepted like")
            await client.setReceipt(true, afterAction: favoriteMetadata(true))
            await controller.setFavorite(true)
            let accepted = await client.accepted
            try expect(accepted == 1 && controller.playbackState.isFavorite && controller.currentFavoriteState != nil,
                       "An accepted press was not verified through a new matching snapshot")
            controller.stop()
            passed += 1
            print("PASS favorite press receipt and verified state determine the displayed heart")
        }
        do {
            let client = DelayedYandexAX()
            var controller: YandexMusicController? = YandexMusicController(accessibility: client,
                processIdentifier: { 42 }, onTransportUnavailable: {}, startMonitoring: false)!
            weak var weakController = controller
            defer { weakController = nil }
            controller!.metadataTestStartMonitoring()
            try await waitForAX("poll did not enter injected AX") { await client.pendingFavorites == 1 }
            controller = nil
            try await waitFor("pending favorite poll retained the stopped source") { weakController == nil }
            await client.finishSnapshot(nil)
            passed += 1
            print("PASS supervised favorite poll releases its controller during delayed AX")
        }
    }

    @MainActor
    private static func favoriteCommandPriority() async throws {
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let command = Task { await controller.setFavorite(true) }
            try await waitForAX("favorite command did not begin its pre-read") { await client.pendingFavorites == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "the command pre-read")
            await client.finishFavorite(false)
            try await waitForAX("passive polling invalidated a valid favorite click") { await client.pendingActions == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "the AX press")
            await client.finishAction(true)
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "post-press settling")
            try await waitForAX("accepted favorite press did not verify the new state") { await client.pendingFavorites == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "the verification read")
            await client.finishFavorite(true)
            await command.value
            let performed = await client.performedCount
            try expect(performed == 1 && controller.playbackState.isFavorite && controller.currentFavoriteState != nil,
                       "The explicit favorite command was dropped or its verified state was lost")
            controller.stop()
            passed += 1
            print("PASS explicit favorite command keeps priority over passive polls through verification")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let older = Task { await controller.setFavorite(true) }
            try await waitForAX("older explicit command did not begin its read") { await client.pendingFavorites == 1 }
            let olderID = controller.metadataTestFavoriteQueueID
            let newer = Task { await controller.setFavorite(true) }
            try await waitFor("newer command was not enqueued") { controller.metadataTestFavoriteQueueID != olderID }
            await client.finishFavorite(false)
            try await waitForAX("older queued command did not reach its native setter") { await client.pendingActions == 1 }
            await client.finishAction(false)
            await older.value
            try await waitForAX("next FIFO command did not begin its read") { await client.pendingFavorites == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "a newer command after the old defer")
            await client.finishFavorite(false)
            try await waitForAX("newer explicit command lost its priority token") { await client.pendingActions == 1 }
            await client.finishAction(false)
            await newer.value
            let resumed = Task { await controller.refreshAccessibilityMetadata() }
            try await waitForAX("passive polling did not resume after the newest command finished") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await resumed.value
            try expect(controller.playbackState.isFavorite && controller.currentFavoriteState != nil,
                       "The action priority slot remained stuck after completion")
            controller.stop()
            passed += 1
            print("PASS FIFO favorite commands preserve successor priority and release the queue on completion")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let passive = Task { await controller.refreshAccessibilityMetadata() }
            try await waitForAX("old passive read did not begin") { await client.pendingFavorites == 1 }
            let command = Task { await controller.setFavorite(true) }
            try await waitForAX("explicit command did not supersede an old passive read") { await client.pendingFavorites == 2 }
            await client.finishFavorite(true)
            await passive.value
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "An old passive read changed the explicit command's observation")
            await client.finishFavorite(false)
            try await waitForAX("old passive result prevented the current command") { await client.pendingActions == 1 }
            await client.finishAction(false)
            await command.value
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState != nil,
                       "The obsolete passive read overwrote the command's newer unliked snapshot")
            controller.stop()
            passed += 1
            print("PASS explicit favorite commands invalidate already-pending passive reads")
        }
    }

    @MainActor
    private static func favoriteToggleSemantics() async throws {
        do {
            let fixture = FavoriteProtocolFixture()
            let controller: any MediaControllerProtocol = fixture
            await controller.toggleFavorite()
            fixture.currentFavoriteState = false
            await controller.toggleFavorite()
            fixture.currentFavoriteState = true
            await controller.toggleFavorite()
            fixture.supportsFavorite = false
            await controller.toggleFavorite()
            try expect(fixture.requested == [true, false],
                       "Default protocol toggle must only invert a known state from a supporting source")
            passed += 1
            print("PASS default protocol toggle preserves known-state idempotent source commands")
        }
        do {
            // Reproduces the live regression: the toggle exists, but a full metadata read is nil.
            let client = SnapshotYandexAX(nil)
            await client.setReceipt(true)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.capabilities.favorite && controller.currentFavoriteState == nil,
                       "An unreadable pressed state disabled the explicit toggle action")
            let source: any MediaControllerProtocol = controller
            await source.toggleFavorite()
            let attempts = await client.attempts
            let accepted = await client.accepted
            try expect(attempts == 1 && accepted == 1 && !controller.playbackState.isFavorite
                        && controller.currentFavoriteState == nil && controller.capabilities.favorite,
                       "An explicit unknown-state click was dropped or invented a confirmed like")
            await source.setFavorite(true)
            let afterIdempotentSet = await client.attempts
            try expect(afterIdempotentSet == 1, "Unknown idempotent set was incorrectly treated as an explicit toggle")
            controller.stop()
            passed += 1
            print("PASS explicit unknown-state toggle remains available without inventing a like")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true, "Fixture did not begin with a confirmed like")
            await client.setSnapshot(favoriteMetadata(nil))
            await client.setReceipt(true, afterAction: favoriteMetadata(false))
            await controller.toggleFavorite()
            try expect(controller.currentFavoriteState == false && !controller.playbackState.isFavorite,
                       "Explicit toggle relied on the stale displayed heart instead of its verified AX result")
            controller.stop()
            passed += 1
            print("PASS explicit toggle verifies its result independently of the previous displayed state")
        }
        for transition in ["track", "stop", "cancel"] {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let command = Task { await controller.toggleFavorite() }
            try await waitForAX("explicit toggle did not enter the targeted AX worker") { await client.pendingActions == 1 }
            switch transition {
            case "track": try await controller.metadataTestUpdate(["title": "After"])
            case "stop": controller.stop()
            default: command.cancel()
            }
            await client.finishAction(true)
            await command.value
            let performed = await client.performedCount
            try expect(performed == 0 && !controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "A \(transition) change accepted an obsolete toggle or created a phantom like")
            controller.stop()
            passed += 1
            print("PASS explicit favorite toggle rejects stale action after \(transition)")
        }
        do {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            controller.metadataTestNativeTrackID("123")
            await controller.toggleFavorite()
            let targets = await client.favoriteTargets
            try expect(targets.count == 1 && targets[0].trackID == "123" && targets[0].title == "Before" && targets[0].artist == "Artist",
                       "The native worker did not receive the displayed recording's exact identity")
            try expect(controller.currentFavoriteState == nil && !controller.playbackState.isFavorite,
                       "A rejected native press supplied a synthetic favorite value")
            controller.stop()
            passed += 1
            print("PASS explicit favorite toggle supplies exact current-track identity to its native worker")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true, artist: "", trackID: "123"))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            controller.metadataTestNativeTrackID("123")
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true && controller.playbackState.isFavorite,
                       "An exact recording match was rejected because AX omitted the artist label")
            controller.stop()
            passed += 1
            print("PASS exact recording identity establishes favorite state despite partial artist metadata")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let command = Task { await controller.toggleFavorite() }
            try await waitForAX("explicit unknown-state toggle did not enter AX") { await client.pendingActions == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "an explicit unknown-state toggle")
            await client.finishAction(true)
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "an unknown-state toggle's settling")
            try await waitForAX("explicit unknown-state toggle did not begin verification") { await client.pendingFavorites == 1 }
            try await expectPassiveRefreshSkipped(controller, client: client, phase: "an unknown-state toggle's verification")
            await client.finishSnapshot(nil)
            await command.value
            let performed = await client.performedCount
            try expect(performed == 1 && controller.currentFavoriteState == nil && controller.capabilities.favorite,
                       "Passive polling interfered with an explicit unknown-state toggle")
            controller.stop()
            passed += 1
            print("PASS explicit unknown-state toggle retains priority over passive polling")
        }
    }

    @MainActor
    private static func scopedFavoriteFallback() async throws {
        for foreignOwner in [false, true] {
            let client = SnapshotYandexAX(nil)
            await client.setScopedSnapshot(favoriteMetadata(false))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            if foreignOwner {
                try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser media", "playing": false], diff: false)
            }
            controller.metadataTestStartMonitoring()
            try await waitFor("Missing full metadata prevented a scoped unliked observation") { controller.currentFavoriteState == false }
            await client.setScopedSnapshot(favoriteMetadata(true))
            try await waitFor("Scoped same-track like did not update the current heart") { controller.currentFavoriteState == true }
            await client.setScopedSnapshot(favoriteMetadata(false))
            try await waitFor("Scoped same-track unlike remained cached") { controller.currentFavoriteState == false }
            let reads = await client.scopedReadCount
            let attempts = await client.attempts
            try expect(reads >= 3 && attempts == 0 && controller.playbackState.title == "Before",
                       "Scoped fallback changed metadata or performed a control action")
            if foreignOwner {
                try expect(controller.systemMediaOwnerBundleIdentifier == "com.apple.Safari", "Scoped favorite reads changed Safari ownership")
            }
            controller.stop()
            passed += 1
            print("PASS scoped favorite polling without full metadata (foreign owner \(foreignOwner))")
        }
        do {
            let client = SnapshotYandexAX(nil)
            await client.setScopedSnapshot(favoriteMetadata(false))
            await client.setReceipt(true, afterAction: favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.setFavorite(true)
            let requests = await client.setRequests
            let accepted = await client.accepted
            let fullReads = await client.readCount
            try expect(requests == [true] && accepted == 1 && fullReads == 0 && controller.currentFavoriteState == true,
                       "Idempotent set still depended on full display metadata or bypassed the targeted setter")
            await controller.setFavorite(true)
            let finalRequests = await client.setRequests
            try expect(finalRequests == [true], "An already satisfied known-state set pressed the toggle again")
            controller.stop()
            passed += 1
            print("PASS idempotent set and verification use scoped state without full display metadata")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(false))
            await client.satisfySetWithoutPress(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.setFavorite(true)
            let requests = await client.setRequests
            let attempts = await client.attempts
            try expect(requests == [true] && attempts == 0 && controller.currentFavoriteState == true,
                       "A native set satisfied just before pressing was converted into a stale toggle")
            controller.stop()
            passed += 1
            print("PASS idempotent desired state is delegated to the native worker's last-moment check")
        }
        for transition in ["track", "stop", "newer read"] {
            let client = DelayedYandexAX()
            await client.setFullMetadataUnavailable()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let old = Task { await controller.refreshAccessibilityMetadata() }
            try await waitForAX("Full metadata failure did not begin a targeted favorite read") { await client.pendingFavorites == 1 }
            switch transition {
            case "track": try await controller.metadataTestUpdate(["title": "After"])
            case "stop": controller.stop()
            default:
                let newer = Task { await controller.refreshAccessibilityMetadata() }
                try await waitForAX("Newer scoped favorite read did not start") { await client.pendingFavorites == 2 }
                await client.finishSnapshot(favoriteMetadata(false), index: 1)
                await newer.value
            }
            await client.finishFavorite(true)
            await old.value
            try expect(!controller.playbackState.isFavorite,
                       "A late scoped favorite read after \(transition) supplied an obsolete like")
            if transition == "newer read" {
                try expect(controller.currentFavoriteState == false, "An obsolete scoped read erased the newest confirmed false state")
            } else {
                try expect(controller.currentFavoriteState == nil, "A stale scoped observation was marked known after \(transition)")
            }
            controller.stop()
            passed += 1
            print("PASS scoped favorite fallback rejects late observation after \(transition)")
        }
        do {
            let client = SnapshotYandexAX(nil)
            await client.setScopedSnapshot(favoriteMetadata(true, title: "Other track"))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            await controller.setFavorite(true)
            let attempts = await client.attempts
            try expect(controller.currentFavoriteState == nil && !controller.playbackState.isFavorite && attempts == 0,
                       "A different track's scoped control supplied a like or authorized an idempotent set")
            controller.stop()
            passed += 1
            print("PASS scoped favorite state still requires the exact current player target")
        }
        do {
            let client = DelayedYandexAX()
            await client.setFullMetadataUnavailable()
            var controller: YandexMusicController? = YandexMusicController(accessibility: client,
                processIdentifier: { 42 }, onTransportUnavailable: {}, startMonitoring: false)!
            weak var weakController = controller
            defer { weakController = nil }
            controller!.metadataTestStartMonitoring()
            try await waitForAX("Supervised poll did not enter targeted fallback") { await client.pendingFavorites == 1 }
            controller = nil
            try await waitFor("Targeted favorite fallback retained its controller across AX IPC") { weakController == nil }
            await client.finishSnapshot(nil)
            passed += 1
            print("PASS scoped favorite fallback releases its controller while the AX read is pending")
        }
    }

    @MainActor
    private static func favoriteEvidenceContinuity() async throws {
        func seed(_ controller: YandexMusicController) async throws {
            try await controller.metadataTestUpdate(["bundleIdentifier": YandexMusicController.bundleID,
                "title": "Before", "artist": "Artist", "contentItemIdentifier": "item A"], diff: false)
        }
        for ending in ["expiry", "backward clock", "false"] {
            let clock = MetadataClockFixture(), client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false,
                metadataClock: { clock.now })!
            try await seed(controller)
            await controller.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            for age in [0.5, 1.5, 2.9] {
                clock.now = 100 + age
                await controller.refreshAccessibilityMetadata()
                try expect(controller.currentFavoriteState == true, "Transient unknown AX lost a recent same-item like")
            }
            switch ending {
            case "expiry": clock.now = 103; controller.metadataTestExpireFavoriteEvidence()
            case "backward clock": clock.now = 99; await controller.refreshAccessibilityMetadata()
            default: await client.setSnapshot(favoriteMetadata(false)); await controller.refreshAccessibilityMetadata()
            }
            try expect(!controller.playbackState.isFavorite && (ending == "false" ? controller.currentFavoriteState == false : controller.currentFavoriteState == nil),
                       "Favorite evidence did not clear immediately at \(ending)")
            controller.stop(); passed += 1
            print("PASS bounded favorite grace \(ending), with no deadline extension on nil")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            await controller.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true, "Setter fixture did not retain recent evidence")
            await controller.setFavorite(false)
            let attempts = await client.attempts
            try expect(attempts == 0 && controller.currentFavoriteState == nil,
                       "Idempotent setter used retained presentation evidence as a fresh native read")
            controller.stop(); passed += 1
            print("PASS unknown idempotent read never acts on grace-cached favorite")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            let known = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("Like seed did not read") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true); await known.value
            let toggle = Task { await controller.toggleFavorite() }
            try await waitForAX("Explicit toggle did not start") { await client.pendingActions == 1 }
            try expect(controller.currentFavoriteState == nil && !controller.playbackState.isFavorite,
                       "An explicit pending action retained stale pre-command evidence")
            await client.finishAction(false); await toggle.value
            controller.stop(); passed += 1
            print("PASS explicit favorite action immediately invalidates presentation evidence")
        }
        for boundary in ["track", "opaque", "reset", "stop", "terminate", "PID"] {
            let pid = PlaybackPIDBox(), client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value }, startMonitoring: false)!
            try await seed(controller)
            await controller.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            await controller.refreshAccessibilityMetadata()
            switch boundary {
            case "track": try await controller.metadataTestUpdate(["title": "After"])
            case "opaque": try await controller.metadataTestUpdate(["contentItemIdentifier": "item B"])
            case "reset": controller.metadataTestReset()
            case "stop": controller.stop()
            case "terminate": pid.value = nil; controller.metadataTestTerminate()
            default: pid.value = 43; await controller.metadataTestRefreshFavorite()
            }
            try expect(controller.currentFavoriteState == nil && !controller.playbackState.isFavorite,
                       "Favorite grace crossed \(boundary)")
            controller.stop(); passed += 1
            print("PASS favorite grace invalidation on \(boundary)")
        }
        do {
            let clock = MetadataClockFixture(), client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false,
                metadataClock: { clock.now }, seekDispatcher: { _ in })!
            try await seed(controller)
            await controller.refreshAccessibilityMetadata()
            try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser"], diff: false)
            await client.setSnapshot(nil)
            clock.now = 101
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true, "An unrelated system media owner discarded matching Yandex evidence")
            try await seed(controller)
            await controller.seek(to: 80)
            clock.now = 102
            await controller.refreshAccessibilityMetadata()
            try expect(controller.currentFavoriteState == true, "Same-item seek discarded matching favorite evidence")
            clock.now = 103
            controller.metadataTestExpireFavoriteEvidence()
            try expect(controller.currentFavoriteState == nil, "Owner/seek metadata extended the favorite evidence deadline")
            controller.stop(); passed += 1
            print("PASS same-item owner return and seek retain evidence without renewing its deadline")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            let known = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("Timer fixture did not seed like") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true); await known.value
            let missing = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("Timer fixture did not read missing state") { await client.pendingFavorites == 1 }
            await client.finishFavorite(nil); await missing.value
            let pending = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("No-response fixture did not enter read") { await client.pendingFavorites == 1 }
            try await waitFor("Grace did not expire while a later read never replied") { controller.currentFavoriteState == nil }
            await client.finishFavorite(true); await pending.value
            try expect(controller.currentFavoriteState == nil, "An old pre-expiry read restored expired favorite evidence")
            controller.stop(); passed += 1
            print("PASS favorite evidence timer expires without another reply and rejects its stale read")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(true))
            var controller: YandexMusicController? = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller!)
            await controller!.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            await controller!.refreshAccessibilityMetadata()
            let timer = controller!.metadataTestFavoriteEvidenceTask
            weak var released = controller
            defer { released = nil }
            controller = nil
            try await waitFor("Favorite expiry timer retained its source") { released == nil }
            await timer?.value
            passed += 1
            print("PASS favorite expiry timer releases and cancels with its source")
        }
        for kind in ["full", "targeted"] {
            let pid = PlaybackPIDBox(), client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value }, startMonitoring: false)!
            try await seed(controller)
            let known = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("PID fixture did not seed like") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true); await known.value
            let pending = Task {
                if kind == "full" { await controller.refreshAccessibilityMetadata() }
                else { await controller.metadataTestRefreshFavorite() }
            }
            try await waitForAX("Old-PID read did not enter AX") { await client.pendingFavorites == 1 }
            pid.value = 43
            await client.finishFavorite(true); await pending.value
            try expect(controller.currentFavoriteState == nil && !controller.playbackState.isFavorite,
                       "A late old-PID \(kind) response supplied evidence for the new process")
            controller.stop(); passed += 1
            print("PASS favorite \(kind) response is bound to its captured native PID")
        }
        for variant in ["missing ID", "enriched ID", "new track", "album conflict", "missing artist"] {
            let client = SnapshotYandexAX(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            if variant != "enriched ID" && variant != "new track" { controller.metadataTestNativeTrackID("123") }
            await controller.metadataTestRefreshFavorite()
            try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser"], diff: false)
            if variant == "album conflict" {
                // Establish a known current album without a native/source transition.
                controller.metadataTestSkipArtwork("Before|Artist|123|")
                controller.metadataTestApplyAX(node("AXGroup", children: [
                    node("AXLink", "Track Before", url: "music-application://desktop/track?trackId=123"),
                    node("AXLink", "Artist Artist", url: "music-application://desktop/artist/1"),
                    node("AXLink", "Album Old", url: "music-application://desktop/album/1")]))
            }
            switch variant {
            case "missing ID":
                for id: String? in [nil, "123", nil, "123"] {
                    controller.metadataTestSkipArtwork("Before|Artist|\(id ?? "")|")
                    await client.setSnapshot(favoriteMetadata(true, trackID: id))
                    await controller.refreshAccessibilityMetadata()
                    try expect(controller.currentFavoriteState == true && controller.playbackState.nativeTrackID == "123",
                               "Alternating same-track AX link availability discarded a confirmed recording like")
                }
            case "enriched ID", "new track":
                let title = variant == "new track" ? "After" : "Before"
                controller.metadataTestSkipArtwork("\(title)|Artist|123|")
                await client.setSnapshot(favoriteMetadata(true, title: title, trackID: "123"))
                await controller.refreshAccessibilityMetadata()
                try expect(controller.currentFavoriteState == true && controller.playbackState.nativeTrackID == "123",
                           "The exact applied snapshot's like was rejected after enriching/changing the item")
            case "album conflict":
                await client.setSnapshot(favoriteMetadata(false, album: "New"))
                await controller.refreshAccessibilityMetadata()
                try expect(controller.playbackState.nativeTrackID == nil && controller.playbackState.album == "New"
                    && controller.currentFavoriteState == false, "A conflicting known album inherited an old native ID or like")
            default:
                await client.setSnapshot(favoriteMetadata(nil, title: "After", artist: ""))
                await controller.refreshAccessibilityMetadata()
                try expect(controller.playbackState.nativeTrackID == nil && controller.currentFavoriteState == nil,
                           "Title-only partial metadata transferred a previous recording ID or like")
            }
            controller.stop(); passed += 1
            print("PASS favorite exact-recording continuity \(variant)")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(nil, title: "After"))
            await client.setScopedSnapshot(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.playbackState.title == "After" && controller.currentFavoriteState == nil,
                       "A scoped read for the previous request was inherited by a new AX recording")
            controller.stop(); passed += 1
            print("PASS new full metadata never inherits an old request's scoped favorite")
        }
    }

    @MainActor
    private static func favoriteHeartbeatAndOwnerChanges() async throws {
        for foreignOwner in [false, true] {
            let client = SnapshotYandexAX(favoriteMetadata(nil, artist: ""))
            await client.setScopedSnapshot(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            if foreignOwner {
                try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": false], diff: false)
            }
            for _ in 0..<2 { await controller.refreshAccessibilityMetadata() }
            try expect(controller.playbackState.artist == "Artist" && controller.currentFavoriteState == true,
                       "Partial artist metadata erased a scoped favorite confirmation (foreign owner \(foreignOwner))")
            if foreignOwner {
                await client.setSnapshot(favoriteMetadata(nil, title: "After", artist: ""))
                await controller.refreshAccessibilityMetadata()
                try expect(controller.playbackState.title == "After" && controller.playbackState.artist.isEmpty
                           && controller.currentFavoriteState == nil,
                           "A genuinely new title inherited the previous recording's missing artist or favorite")
            }
            controller.stop()
            passed += 1
            print("PASS partial same-track artist metadata retains scoped confirmation (foreign owner \(foreignOwner))")
        }
        do {
            let client = SnapshotYandexAX(favoriteMetadata(nil))
            await client.setScopedSnapshot(favoriteMetadata(true))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.metadataTestRefreshFavorite()
            try expect(controller.currentFavoriteState == true, "Heartbeat fixture did not begin with a confirmed like")
            var observations: [Bool?] = []
            let observation = controller.playbackStatePublisher.sink { state in
                observations.append(controller.currentFavoriteState == nil ? nil : state.isFavorite)
            }
            for tick in 1...3 {
                try await controller.metadataTestUpdate(["elapsedTime": Double(tick)])
                await controller.refreshAccessibilityMetadata()
            }
            observation.cancel()
            let reads = await client.scopedReadCount
            try expect(reads == 4 && controller.currentFavoriteState == true && observations.allSatisfy { $0 == true },
                       "A full metadata snapshot without Like erased a scoped confirmation during heartbeat")
            controller.stop()
            passed += 1
            print("PASS scoped confirmation survives full metadata with an unknown favorite during heartbeat")
        }
        for wrongTrack in [false, true] {
            let client = SnapshotYandexAX(favoriteMetadata(false, title: wrongTrack ? "Cached different track" : "Before",
                                                         artist: wrongTrack ? "Artist" : ""))
            await client.setScopedSnapshot(favoriteMetadata(!wrongTrack))
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            let reads = await client.scopedReadCount
            try expect(reads == 1 && controller.currentFavoriteState == !wrongTrack,
                       "A present but incomplete/mismatched metadata snapshot blocked the scoped favorite read")
            try expect(controller.playbackState.title == "Before" && controller.playbackState.artist == "Artist",
                       "Favorite fallback borrowed unrelated full metadata for the display")
            controller.stop()
            passed += 1
            print("PASS scoped favorite fallback for present metadata (different track \(wrongTrack))")
        }
        for phase in ["before press", "after acceptance", "verification", "return to Yandex"] {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            if phase == "return to Yandex" {
                try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": false], diff: false)
            }
            let identity = controller.playbackState.identity
            let command = Task { await controller.toggleFavorite() }
            try await waitForAX("Directed toggle did not enter AX") { await client.pendingActions == 1 }
            if phase == "after acceptance" || phase == "verification" {
                await client.finishAction(true)
                try await waitForAX("Native press was not accepted") { await client.performedCount == 1 }
            }
            if phase == "verification" {
                try await waitForAX("Post-press verification did not start") { await client.pendingFavorites == 1 }
            }
            if phase == "return to Yandex" {
                try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            } else {
                try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": false], diff: false)
            }
            try expect(controller.playbackState.identity == identity, "Fixture changed the Yandex recording during an unrelated owner change")
            if phase == "before press" || phase == "return to Yandex" { await client.finishAction(true) }
            try await waitForAX("Unrelated system ownership change cancelled favorite verification") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await command.value
            let performed = await client.performedCount
            try expect(performed == 1 && controller.currentFavoriteState == true,
                       "System ownership change cancelled a correctly targeted current-track toggle")
            controller.stop()
            passed += 1
            print("PASS directed favorite survives unrelated owner change during \(phase)")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let command = Task { await controller.setFavorite(true) }
            try await waitForAX("Idempotent set did not enter its pre-read") { await client.pendingFavorites == 1 }
            try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": false], diff: false)
            await client.finishFavorite(false)
            try await waitForAX("Owner change invalidated the same-track idempotent pre-read") { await client.pendingActions == 1 }
            await client.finishAction(true)
            try await waitForAX("Idempotent verification did not follow the accepted press") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await command.value
            let requests = await client.setRequests
            try expect(requests == [true] && controller.currentFavoriteState == true,
                       "An unrelated owner change erased the idempotent command or its verification")
            controller.stop()
            passed += 1
            print("PASS idempotent favorite pre-read survives an unrelated system owner change")
        }
    }

    @MainActor
    private static func favoriteFIFO() async throws {
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let first = Task { await controller.toggleFavorite() }
            try await waitForAX("First toggle did not begin") { await client.pendingActions == 1 }
            let firstID = controller.metadataTestFavoriteQueueID
            let second = Task { await controller.toggleFavorite() }
            try await waitFor("Second toggle was not enqueued") { controller.metadataTestFavoriteQueueID != firstID }
            let pendingBefore = await client.pendingActions
            try expect(pendingBefore == 1, "A rapid toggle raced an already pending native press")
            await client.finishAction(true)
            try await waitForAX("First toggle did not verify its result") { await client.pendingFavorites == 1 }
            let pendingDuringVerification = await client.pendingActions
            try expect(pendingDuringVerification == 0, "The second toggle overtook the first verification")
            await client.finishFavorite(true)
            await first.value
            try await waitForAX("A queued explicit toggle was dropped") { await client.pendingActions == 1 }
            await client.finishAction(true)
            try await waitForAX("Second toggle did not verify its result") { await client.pendingFavorites == 1 }
            await client.finishFavorite(false)
            await second.value
            let presses = await client.performedCount
            try expect(presses == 2 && controller.currentFavoriteState == false && controller.metadataTestFavoriteQueueID == nil,
                       "Two explicit same-track toggles failed to preserve their two native presses")
            controller.stop()
            passed += 1
            print("PASS rapid explicit toggles execute FIFO and preserve both presses")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let toggle = Task { await controller.toggleFavorite() }
            try await waitForAX("Mixed queue toggle did not begin") { await client.pendingActions == 1 }
            let toggleID = controller.metadataTestFavoriteQueueID
            let set = Task { await controller.setFavorite(false) }
            try await waitFor("Mixed queue set was not enqueued") { controller.metadataTestFavoriteQueueID != toggleID }
            let setID = controller.metadataTestFavoriteQueueID
            let dislike = Task { await controller.dislike() }
            try await waitFor("Mixed queue dislike was not enqueued") { controller.metadataTestFavoriteQueueID != setID }
            await client.finishAction(true)
            try await waitForAX("Mixed toggle verification did not begin") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await toggle.value
            try await waitForAX("Queued set did not read the state after the toggle") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            try await waitForAX("Queued set did not reach its native setter") { await client.pendingActions == 1 }
            await client.finishAction(true)
            try await waitForAX("Queued set did not verify its result") { await client.pendingFavorites == 1 }
            await client.finishFavorite(false)
            await set.value
            try await waitForAX("Queued dislike did not follow the setter") { await client.pendingActions == 1 }
            await client.finishAction(true)
            try await waitForAX("Queued dislike did not refresh its result") { await client.pendingFavorites == 1 }
            await client.finishFavorite(false)
            await dislike.value
            let actions = await client.performedActions
            let desired = await client.setRequests
            try expect(actions == ["like", "like", "dislike"] && desired == [false],
                       "Toggle, idempotent set and dislike lost their requested order or semantics")
            controller.stop()
            passed += 1
            print("PASS toggle, idempotent set and dislike share one FIFO")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let first = Task { await controller.toggleFavorite() }
            try await waitForAX("Cancellation queue predecessor did not begin") { await client.pendingActions == 1 }
            let firstID = controller.metadataTestFavoriteQueueID
            let cancelled = Task { await controller.toggleFavorite() }
            try await waitFor("Cancelled command was not enqueued") { controller.metadataTestFavoriteQueueID != firstID }
            let cancelledID = controller.metadataTestFavoriteQueueID
            let last = Task { await controller.toggleFavorite() }
            try await waitFor("Queue successor was not enqueued") { controller.metadataTestFavoriteQueueID != cancelledID }
            cancelled.cancel()
            await client.finishAction(false)
            await first.value
            await cancelled.value
            try await waitForAX("Cancellation of one queued click cancelled its successor") { await client.pendingActions == 1 }
            await client.finishAction(true)
            try await waitForAX("Successor verification did not begin") { await client.pendingFavorites == 1 }
            await client.finishFavorite(true)
            await last.value
            let presses = await client.performedCount
            try expect(presses == 1 && controller.currentFavoriteState == true,
                       "A cancelled queued caller pressed the control or cancelled an unrelated caller")
            controller.stop()
            passed += 1
            print("PASS queued caller cancellation preserves its predecessor and successor")
        }
        for transition in ["track", "stop", "terminate", "reset"] {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let first = Task { await controller.toggleFavorite() }
            try await waitForAX("Invalidation predecessor did not begin") { await client.pendingActions == 1 }
            let firstID = controller.metadataTestFavoriteQueueID
            let queued = Task { await controller.toggleFavorite() }
            try await waitFor("Invalidation command was not enqueued") { controller.metadataTestFavoriteQueueID != firstID }
            switch transition {
            case "track": try await controller.metadataTestUpdate(["title": "After"])
            case "stop": controller.stop()
            case "terminate": controller.metadataTestTerminate()
            default: controller.metadataTestReset()
            }
            await client.finishAction(true)
            await first.value
            await queued.value
            let presses = await client.performedCount
            let pending = await client.pendingActions
            try expect(presses == 0 && pending == 0 && controller.currentFavoriteState == nil,
                       "A \(transition) change let an obsolete queued command reach the native control")
            controller.stop()
            passed += 1
            print("PASS \(transition) invalidates active and queued favorite requests")
        }
        do {
            let client = DelayedYandexAX()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            let old = Task { await controller.toggleFavorite() }
            try await waitForAX("Old recording action did not begin") { await client.pendingActions == 1 }
            try await controller.metadataTestUpdate(["title": "After"])
            let current = Task { await controller.toggleFavorite() }
            try await waitForAX("New recording remained blocked behind the invalidated old queue") { await client.pendingActions == 2 }
            await client.finishAction(true)
            await old.value
            await client.finishAction(true)
            try await waitForAX("New recording verification did not begin") { await client.pendingFavorites == 1 }
            await client.finishSnapshot(favoriteMetadata(true, title: "After"))
            await current.value
            let targets = await client.favoriteTargets
            let presses = await client.performedCount
            try expect(targets.map(\.title) == ["Before", "After"] && presses == 1 && controller.currentFavoriteState == true,
                       "Queue reset copied an old recording target or discarded the new recording's click")
            controller.stop()
            passed += 1
            print("PASS new recording clicks use a fresh queue and exact recording target")
        }
        do {
            let gate = FavoriteQueueGate()
            let predecessor = Task { await gate.wait() }
            try await waitForAX("Queue lifetime predecessor did not block") { await gate.ready }
            let client = SnapshotYandexAX(nil)
            var controller: YandexMusicController? = YandexMusicController(accessibility: client,
                processIdentifier: { 42 }, onTransportUnavailable: {}, startMonitoring: false)!
            controller!.metadataTestPredecessor(predecessor)
            let queued = controller!.metadataTestEnqueueToggle()!
            weak var weakController = controller
            defer { weakController = nil }
            controller = nil
            try await waitFor("Waiting queue entry retained its media source") { weakController == nil }
            await gate.finish()
            await queued.value
            let attempts = await client.attempts
            try expect(attempts == 0, "A queued request outlived its source and reached the native control")
            passed += 1
            print("PASS waiting FIFO entries do not retain or reactivate their source")
        }
    }

    @MainActor
    private static func pausedTimelineReconciliation() async throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func seed(_ controller: YandexMusicController, playing: Bool = true, title: String = "Paused track") async throws {
            try await controller.metadataTestUpdate(["bundleIdentifier": YandexMusicController.bundleID,
                "title": title, "artist": "Artist", "album": "Album", "contentItemIdentifier": "item A",
                "playing": playing, "playbackRate": playing ? 1.0 : 0.0, "elapsedTime": 40.0,
                "timestamp": formatter.string(from: Date()), "duration": 240.0], diff: false)
        }
        for pauseSource in ["scoped playback", "accepted local pause", "unknown after scoped pause"] {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            if pauseSource == "accepted local pause" {
                await client.setReceipt(true)
                await controller.pause()
            } else {
                await client.setPlaybackState(false)
                await controller.metadataTestRefreshPlaying()
                if pauseSource == "unknown after scoped pause" {
                    await client.setPlaybackState(nil)
                    await controller.metadataTestRefreshPlaying()
                }
            }
            let anchor = controller.playbackState
            var observed: [PlaybackState] = []
            let subscription = controller.playbackStatePublisher.sink { observed.append($0) }
            for elapsed in [50.0, 60.0, 70.0] {
                try await controller.metadataTestUpdate(["playing": true, "playbackRate": 1.0, "elapsedTime": elapsed,
                    "timestamp": formatter.string(from: Date().addingTimeInterval(elapsed))])
            }
            try await controller.metadataTestUpdate(["timestamp": formatter.string(from: Date().addingTimeInterval(100))])
            try expect(observed.allSatisfy { !$0.isPlaying && $0.playbackRate == 0
                && $0.currentTime == anchor.currentTime && $0.lastUpdated == anchor.lastUpdated
                && $0.timeline.position(at: anchor.lastUpdated.addingTimeInterval(120)) == anchor.currentTime },
                "Stale MR elapsed/timestamp heartbeats moved the confirmed paused timeline (\(pauseSource))")
            _ = subscription
            controller.stop(); passed += 1
            print("PASS paused timeline ignores cached playing MR anchors after \(pauseSource)")
        }
        do {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            try await controller.metadataTestUpdate(["playing": false, "playbackRate": 0.0, "elapsedTime": 45.0,
                "timestamp": formatter.string(from: Date())])
            try await controller.metadataTestUpdate(["elapsedTime": 120.0, "timestamp": formatter.string(from: Date())])
            try expect(!controller.playbackState.isPlaying && controller.playbackState.currentTime == 120,
                       "An acknowledged native pause blocked a real paused position/seek update")
            try await controller.metadataTestUpdate(["playing": true, "playbackRate": 1.0, "elapsedTime": 120.0,
                "timestamp": formatter.string(from: Date())])
            let resumed = controller.playbackState
            try expect(resumed.isPlaying && resumed.timeline.position(at: resumed.lastUpdated.addingTimeInterval(10)) == 130,
                       "A fresh native resume could not replace a frozen scoped-pause anchor")
            controller.stop(); passed += 1
            print("PASS native pause acknowledgement permits paused seek and subsequent resume")
        }
        do {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            try await controller.metadataTestUpdate(["title": "Next track", "contentItemIdentifier": "item B", "elapsedTime": 0.0,
                "timestamp": formatter.string(from: Date())])
            try expect(!controller.playbackState.isPlaying && controller.playbackState.currentTime == 0,
                       "A previous recording's paused anchor leaked into a new recording")
            await client.setPlaybackState(true)
            await controller.metadataTestRefreshPlaying()
            try expect(controller.playbackState.isPlaying, "The new recording could not resume from fresh scoped evidence")
            controller.stop(); passed += 1
            print("PASS new recording resets a paused timeline and accepts fresh scoped playback")
        }
        do {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            let anchor = controller.playbackState
            try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": true], diff: false)
            try await seed(controller)
            try await controller.metadataTestUpdate(["elapsedTime": 100.0, "timestamp": formatter.string(from: Date())])
            try expect(!controller.playbackState.isPlaying && controller.playbackState.currentTime == anchor.currentTime,
                       "Returning system ownership accepted a stale position over the same paused Yandex recording")
            controller.stop(); passed += 1
            print("PASS returning Yandex owner retains the same recording's confirmed paused anchor")
        }
        do {
            let client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await seed(controller)
            await client.setPlaybackState(true)
            await controller.metadataTestRefreshPlaying()
            try await controller.metadataTestUpdate(["elapsedTime": 65.0, "timestamp": formatter.string(from: Date())])
            try expect(controller.playbackState.isPlaying && controller.playbackState.currentTime == 65,
                       "Paused-anchor protection suppressed genuine background playback position updates")
            controller.stop(); passed += 1
            print("PASS confirmed background playback continues accepting native positions")
        }
    }

    @MainActor
    private static func pausedSeekIntent() async throws {
        func seed(_ controller: YandexMusicController, duration: Double = 180) async throws {
            try await controller.metadataTestUpdate(["bundleIdentifier": YandexMusicController.bundleID,
                "title": "Seek track", "artist": "Artist", "contentItemIdentifier": "item A",
                "elapsedTime": 40.0, "duration": duration, "playing": true, "playbackRate": 1.0], diff: false)
        }
        for nativePaused in [false, true] {
            let client = SnapshotYandexAX(nil)
            var dispatched: [Double] = []
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false,
                seekDispatcher: { dispatched.append($0) })!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            if nativePaused { try await controller.metadataTestUpdate(["playing": false, "playbackRate": 0.0]) }
            for (requested, expected) in [(120.0, 120.0), (500.0, 180.0), (-20.0, 0.0)] {
                await controller.seek(to: requested)
                try expect(controller.playbackState.currentTime == expected && !controller.playbackState.isPlaying,
                           "An explicit paused seek did not update/clamp its local intent")
                if !nativePaused {
                    try await controller.metadataTestUpdate(["elapsedTime": 77.0, "playing": true])
                    try expect(controller.playbackState.currentTime == expected, "Cached MR elapsed replaced an explicit paused seek")
                }
            }
            try expect(dispatched == [120, 180, 0], "Paused seek dispatcher received unclamped or duplicate commands")
            try await controller.metadataTestUpdate(["playing": false, "playbackRate": 0.0, "elapsedTime": 12.0])
            try expect(controller.playbackState.currentTime == 12, "Native paused acknowledgement could not correct an unconfirmed seek intent")
            controller.stop(); passed += 1
            print("PASS paused seek local intent and native correction (native pause acknowledged \(nativePaused))")
        }
        do {
            let client = SnapshotYandexAX(nil)
            var dispatched: [Double] = []
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false,
                seekDispatcher: { dispatched.append($0) })!
            try await seed(controller, duration: 0)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            await controller.seek(to: 600)
            await controller.seek(to: .nan)
            await controller.seek(to: .infinity)
            await controller.seek(to: -.infinity)
            try expect(dispatched == [600] && controller.playbackState.currentTime == 600,
                       "Unknown duration clamped seek to zero or nonfinite input reached native dispatch")
            controller.stop(); passed += 1
            print("PASS paused seek handles unknown duration and rejects nonfinite positions")
        }
        for boundary in ["foreign", "stopped", "missing PID"] {
            let pid = PlaybackPIDBox(), client = SnapshotYandexAX(nil)
            var dispatched: [Double] = []
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value }, startMonitoring: false,
                seekDispatcher: { dispatched.append($0) })!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            switch boundary {
            case "foreign": try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser"], diff: false)
            case "stopped": controller.stop()
            default: pid.value = nil
            }
            let before = controller.playbackState.currentTime
            await controller.seek(to: 120)
            try expect(dispatched.isEmpty && controller.playbackState.currentTime == before,
                       "Paused seek escaped its source guard for \(boundary)")
            controller.stop(); passed += 1
            print("PASS paused seek is not dispatched for \(boundary)")
        }
        for boundary in ["track", "opaque item", "stop", "foreign", "PID", "cancel"] {
            let gate = FavoriteQueueGate(), pid = PlaybackPIDBox(), client = SnapshotYandexAX(nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value }, startMonitoring: false,
                seekDispatcher: { _ in await gate.wait() })!
            try await seed(controller)
            await client.setPlaybackState(false)
            await controller.metadataTestRefreshPlaying()
            let seek = Task { await controller.seek(to: 120) }
            try await waitForAX("Injected seek did not enter dispatch") { await gate.ready }
            switch boundary {
            case "track": try await controller.metadataTestUpdate(["title": "Other track", "contentItemIdentifier": "item B", "elapsedTime": 0.0])
            case "opaque item": try await controller.metadataTestUpdate(["title": "Seek track", "contentItemIdentifier": "item B", "elapsedTime": 0.0])
            case "stop": controller.stop()
            case "foreign": try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser"], diff: false)
            case "PID": pid.value = 43
            default: seek.cancel()
            }
            let before = controller.playbackState
            await gate.finish()
            await seek.value
            try expect(controller.playbackState.currentTime == before.currentTime && controller.playbackState.lastUpdated == before.lastUpdated,
                       "A delayed seek applied its old position after \(boundary)")
            controller.stop(); passed += 1
            print("PASS delayed paused seek cannot reanchor after \(boundary)")
        }
    }

    @MainActor
    private static func playbackEvidence() async throws {
        func seed(_ controller: YandexMusicController, playing: Bool = true) async throws {
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist",
                "playing": playing, "playbackRate": playing ? 1.0 : 0.0, "elapsedTime": 40.0, "duration": 180.0], diff: false)
        }
        for lifecycle in ["terminate", "cold ghost", "missing PID", "reset"] {
            let pid = PlaybackPIDBox(), client = SnapshotYandexAX(nil)
            if lifecycle == "cold ghost" { pid.value = nil }
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            switch lifecycle {
            case "terminate":
                pid.value = nil
                controller.metadataTestTerminate()
                try await seed(controller)
            case "missing PID":
                pid.value = nil
                await controller.metadataTestRefreshPlaying()
            case "reset":
                controller.metadataTestReset()
                await controller.metadataTestRefreshPlaying()
            default: break
            }
            let state = controller.playbackState
            try expect(!state.isPlaying && state.playbackRate == 0
                       && state.timeline.position(at: state.lastUpdated.addingTimeInterval(10)) == state.currentTime,
                       "\(lifecycle) left an old playing animation/timeline without current source evidence")
            pid.value = 43
            await client.setPlaybackState(true)
            await controller.metadataTestRefreshPlaying()
            try expect(controller.isActive() && controller.playbackState.isPlaying,
                       "\(lifecycle) permanently stopped the source or prevented fresh relaunch evidence")
            controller.stop()
            passed += 1
            print("PASS playing lifecycle \(lifecycle) stops stale state and permits fresh relaunch")
        }
        do {
            let paused = YandexAccessibilityMetadata(root: .init(role: "AXGroup", labels: [], value: nil, url: nil, children: [
                .init(role: "AXLink", labels: ["Track Before"], value: nil, url: nil, children: []),
                .init(role: "AXLink", labels: ["Artist Artist"], value: nil, url: URL(string: "music-application://desktop/artist/1"), children: []),
                .init(role: "AXButton", labels: ["Playback"], value: nil, url: nil, children: []),
            ]))!
            let client = SnapshotYandexAX(paused)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isPlaying && controller.accessibilityIsPlaying == false,
                       "A matching native-owner AX pause was ignored in favor of cached MR playing")
            controller.stop()
            passed += 1
            print("PASS matching full AX pause reconciles the native Yandex session owner")
        }
        for foreignOwner in [false, true] {
            for playing in [false, true] {
                let client = SnapshotYandexAX(nil)
                await client.setPlaybackState(playing)
                let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                    onTransportUnavailable: {}, startMonitoring: false)!
                try await seed(controller, playing: !playing)
                if foreignOwner {
                    try await controller.metadataTestUpdate(["bundleIdentifier": "com.apple.Safari", "title": "Browser", "playing": false], diff: false)
                }
                await controller.refreshAccessibilityMetadata()
                try expect(controller.playbackState.isPlaying == playing && controller.accessibilityIsPlaying == playing
                           && controller.accessibilityMetadataLastReadAt != nil,
                           "Independent playback evidence was hidden by unavailable full metadata or session ownership")
                if !foreignOwner { try await controller.metadataTestUpdate(["playing": !playing, "album": "Heartbeat"]) }
                else { try await controller.metadataTestUpdate(["title": "Browser heartbeat"]) }
                try expect(controller.playbackState.isPlaying == playing,
                           "A cached MediaRemote playing value immediately undid a newer scoped observation")
                await client.setPlaybackState(nil)
                await controller.metadataTestRefreshPlaying()
                try expect(controller.playbackState.isPlaying == playing && controller.accessibilityIsPlaying == nil,
                           "An unknown read invented a pause or resumed a previously confirmed pause")
                if !foreignOwner { try await controller.metadataTestUpdate(["album": "Another heartbeat"]) }
                try expect(controller.playbackState.isPlaying == playing,
                           "Unknown playback evidence let an unchanged cached MR value resurrect the old state")
                controller.stop()
                passed += 1
                print("PASS independent playing \(playing) with unavailable metadata (foreign owner \(foreignOwner))")
            }
        }
        do {
            let client = SnapshotYandexAX(nil)
            await client.setPlaybackState(false)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            await controller.metadataTestRefreshPlaying()
            try await controller.metadataTestUpdate(["playing": false])
            try await controller.metadataTestUpdate(["playing": true])
            try expect(controller.playbackState.isPlaying, "A real new MR playing transition could not replace previous pause evidence")
            controller.stop()
            passed += 1
            print("PASS new native playing transitions replace previous scoped evidence")
        }
        do {
            let client = SnapshotYandexAX(nil)
            await client.setPlaybackState(true)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            for rate in [0.5, 1.5] {
                try await controller.metadataTestUpdate(["playbackRate": rate])
                await controller.metadataTestRefreshPlaying()
                try await controller.metadataTestUpdate(["album": "Rate heartbeat \(rate)"])
                try expect(controller.playbackState.playbackRate == rate,
                           "A boolean scoped playback observation changed the source's actual playback speed")
            }
            controller.stop()
            passed += 1
            print("PASS scoped playing confirmation preserves native playback speed")
        }
        do {
            let client = DelayedYandexAX()
            await client.setDelayPlayback()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            let older = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Old playback request did not begin") { await client.pendingPlaybackReads == 1 }
            let newer = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("New playback request did not begin") { await client.pendingPlaybackReads == 2 }
            await client.finishPlayback(false, index: 1)
            await newer.value
            await client.finishPlayback(true)
            await older.value
            try expect(!controller.playbackState.isPlaying && controller.accessibilityIsPlaying == false,
                       "An older playing read overwrote a newer pause")
            controller.stop()
            passed += 1
            print("PASS reversed playback samples keep the newest pause")
        }
        for lifecycle in ["stop", "terminate", "reset", "PID change"] {
            let pid = PlaybackPIDBox(), client = DelayedYandexAX()
            await client.setDelayPlayback()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { pid.value },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            let pending = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Delayed playback sample did not begin") { await client.pendingPlaybackReads == 1 }
            switch lifecycle {
            case "stop": controller.stop()
            case "terminate": pid.value = nil; controller.metadataTestTerminate()
            case "reset": controller.metadataTestReset()
            default:
                pid.value = 43
                try await seed(controller, playing: false)
            }
            await client.finishPlayback(true)
            await pending.value
            try expect(!controller.playbackState.isPlaying && controller.accessibilityIsPlaying == nil,
                       "An old playback sample resurrected the source after \(lifecycle)")
            controller.stop()
            passed += 1
            print("PASS late playback sample cannot resurrect source after \(lifecycle)")
        }
        do {
            let client = DelayedYandexAX()
            await client.setPlaybackState(false)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            let favorite = Task { await controller.toggleFavorite() }
            try await waitForAX("Favorite action did not begin") { await client.pendingActions == 1 }
            controller.metadataTestStartPlayingMonitoring()
            try await waitFor("Favorite action hid a real pause from independent monitoring") { !controller.playbackState.isPlaying }
            await client.finishAction(false)
            await favorite.value
            try expect(controller.accessibilityIsPlaying == false, "Favorite completion erased an independent pause sample")
            controller.stop()
            passed += 1
            print("PASS favorite actions do not block independent pause monitoring")
        }
        do {
            let client = DelayedYandexAX()
            await client.setDelayPlayback()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            let playing = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Independent playback request did not begin") { await client.pendingPlaybackReads == 1 }
            let favorite = Task { await controller.metadataTestRefreshFavorite() }
            try await waitForAX("Concurrent favorite read did not begin") { await client.pendingFavorites == 1 }
            await client.finishFavorite(false)
            await favorite.value
            await client.finishPlayback(false)
            await playing.value
            try expect(!controller.playbackState.isPlaying && controller.accessibilityIsPlaying == false,
                       "Favorite read revisions invalidated an unrelated playback observation")
            controller.stop()
            passed += 1
            print("PASS favorite and playback reads have independent revision lifetimes")
        }
        do {
            let client = DelayedYandexAX()
            await client.setDelayPlayback()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller, playing: false)
            let oldPause = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Pre-play sample did not begin") { await client.pendingPlaybackReads == 1 }
            let play = Task { await controller.play() }
            try await waitForAX("Explicit play did not enter AX") { await client.pendingActions == 1 }
            await client.finishAction(true)
            await play.value
            await client.finishPlayback(false)
            await oldPause.value
            try await controller.metadataTestUpdate(["album": "Cached paused heartbeat"])
            try expect(controller.playbackState.isPlaying && controller.accessibilityIsPlaying == nil,
                       "A pre-command pause read/cache overrode an accepted play")
            let oldPlay = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Pre-pause sample did not begin") { await client.pendingPlaybackReads == 1 }
            let pause = Task { await controller.pause() }
            try await waitForAX("Explicit pause did not enter AX") { await client.pendingActions == 1 }
            await client.finishAction(true)
            await pause.value
            await client.finishPlayback(true)
            await oldPlay.value
            try expect(!controller.playbackState.isPlaying && controller.playbackState.playbackRate == 0,
                       "A pre-command playing read overrode an accepted pause")
            controller.stop()
            passed += 1
            print("PASS accepted native play/pause discards pre-command playback samples")
        }
        do {
            let client = DelayedYandexAX()
            await client.setDelayPlayback()
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 43 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await seed(controller)
            let current = Task { await controller.metadataTestRefreshPlaying() }
            try await waitForAX("Relaunched process sample did not begin") { await client.pendingPlaybackReads == 1 }
            controller.metadataTestTerminate(processIdentifier: 42)
            try expect(controller.playbackState.isPlaying, "A late old-process quit notification stopped the relaunched source")
            await client.finishPlayback(false)
            await current.value
            try expect(controller.accessibilityIsPlaying == false && !controller.playbackState.isPlaying,
                       "An old-process quit invalidated the new process's current evidence")
            controller.stop()
            passed += 1
            print("PASS late quit notification from the previous PID preserves the relaunched source")
        }
        do {
            let client = DelayedYandexAX()
            await client.setDelayPlayback()
            var controller: YandexMusicController? = YandexMusicController(accessibility: client,
                processIdentifier: { 42 }, onTransportUnavailable: {}, startMonitoring: false)!
            controller!.metadataTestStartPlayingMonitoring()
            let reader = controller!.metadataTestPlaybackTask
            weak var weakController = controller
            defer { weakController = nil }
            try await waitForAX("Playback monitor did not enter AX") { await client.pendingPlaybackReads == 1 }
            controller = nil
            try await waitFor("Playback monitor retained its source across AX IPC") { weakController == nil }
            await client.finishPlayback(true)
            await reader?.value
            passed += 1
            print("PASS independent playback monitor releases its source while waiting")
        }
    }

    @MainActor
    private static func stream(_ name: String, _ messages: [[String: Any]], snapshot: [String: Any]? = nil,
                               verify: (YandexMusicController) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("stream.jsonl")
        let done = directory.appendingPathComponent("done")
        var data = Data()
        for message in messages {
            data.append(try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: fixture)
        setenv("YANDEX_METADATA_FIXTURE", fixture.path, 1)
        setenv("YANDEX_METADATA_DONE", done.path, 1)
        let confirmed = try snapshot.map { try wireSnapshot($0) }
        var controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                                               snapshotReader: { confirmed })
        guard controller != nil else { throw YandexMetadataFailure(description: "MediaRemote initialization unavailable") }
        weak var weakController = controller
        defer { weakController = nil }
        try await waitFor("fixture stream did not complete") { FileManager.default.fileExists(atPath: done.path) }
        try await Task.sleep(for: .milliseconds(snapshot == nil ? 80 : 250))
        try await verify(controller!)
        let process = controller!.metadataTestProcess
        let reader = controller!.metadataTestReader
        controller = nil
        try await waitFor("stream retained controller after source switch") { weakController == nil }
        try await waitFor("source switch left adapter process running") { process?.isRunning != true }
        var finished = false
        Task { await reader?.value; finished = true }
        try await waitFor("pending pipe reader did not finish") { finished }
        passed += 1
        print("PASS \(name)")
    }

    private static func update(_ payload: [String: Any], diff: Bool = true) -> [String: Any] {
        ["type": "data", "diff": diff, "payload": payload]
    }

    private static var initial: [String: Any] {
        update(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Old title", "artist": "Old artist",
                "album": "Old album", "artworkData": Data("old art".utf8).base64EncodedString(), "playing": true], diff: false)
    }

    private static func node(_ role: String, _ label: String = "", url: String? = nil,
                             value: String? = nil, children: [YandexAccessibilityNode] = []) -> YandexAccessibilityNode {
        .init(role: role, labels: label.isEmpty ? [] : [label], value: value, url: url.flatMap(URL.init(string:)), children: children)
    }

    private static func wireSnapshot(_ payload: [String: Any]) throws -> MediaWireUpdate {
        try JSONDecoder().decode(MediaWireUpdate.self,
            from: JSONSerialization.data(withJSONObject: ["diff": false, "payload": payload]))
    }

    private static func track(_ title: String, artist: String = "Artist", album: String = "Album",
                              id: String? = nil, art: String? = nil, owner: String = YandexMusicController.bundleID) -> [String: Any] {
        var payload: [String: Any] = ["bundleIdentifier": owner, "title": title, "artist": artist, "album": album, "playing": true]
        if let id { payload["contentItemIdentifier"] = id }
        if let art { payload["artworkData"] = Data(art.utf8).base64EncodedString() }
        return payload
    }

    @MainActor
    private static func metadataOwnership() async throws {
        for release in ["matching", "novel", "expiry", "next", "previous"] {
            let clock = MetadataClockFixture()
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, metadataClock: { clock.now })!
            try await controller.metadataTestUpdate(track("A", art: "art A"), diff: false)
            try await controller.metadataTestUpdate(track("Browser", owner: "com.apple.Safari"), diff: false)
            controller.metadataTestApplyAX(node("AXGroup", children: [node("AXLink", "Track B"), node("AXLink", "Artist Artist")]))
            var titles: [String] = []
            let subscription = controller.playbackStatePublisher.sink { titles.append($0.title) }
            try await controller.metadataTestUpdate(track("A", art: "art A"), diff: false)
            try expect(!titles.contains("A") && controller.playbackState.title == "B", "Delayed MR A rolled fresh AX B back")
            switch release {
            case "matching": try await controller.metadataTestUpdate(track("B", art: "art B"), diff: false)
            case "novel": try await controller.metadataTestUpdate(track("C", art: "art C"), diff: false)
            case "expiry": clock.now += 2.1; try await controller.metadataTestUpdate(track("A"), diff: false)
            default:
                let action = Task { if release == "next" { await controller.nextTrack() } else { await controller.previousTrack() } }
                await action.value
                try await controller.metadataTestUpdate(track("A"), diff: false)
            }
            // A failed fake AX navigation cannot release authority; successful navigation is
            // covered below with an accepting worker.
            let expected = release == "matching" ? "B" : release == "novel" ? "C" : release == "expiry" ? "A" : "B"
            try expect(controller.playbackState.title == expected, "Metadata authority failed its \(release) boundary")
            _ = subscription
            controller.stop()
            passed += 1
            print("PASS fresh AX metadata barrier \(release)")
        }
        for previous in [false, true] {
            let client = SnapshotYandexAX(nil)
            await client.setReceipt(true, afterAction: nil)
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 }, startMonitoring: false)!
            try await controller.metadataTestUpdate(track("A"), diff: false)
            try await controller.metadataTestUpdate(track("Browser", owner: "com.apple.Safari"), diff: false)
            let bar = node("AXGroup", children: [node("AXLink", "Track B"), node("AXLink", "Artist Artist")])
            controller.metadataTestApplyAX(bar)
            if previous { await controller.previousTrack() } else { await controller.nextTrack() }
            controller.metadataTestApplyAX(bar)
            try await controller.metadataTestUpdate(track("A"), diff: false)
            try expect(controller.playbackState.title == "A", "Explicit navigation kept or rearmed the old AX barrier")
            controller.stop(); passed += 1
            print("PASS accepted explicit navigation releases AX metadata authority")
        }
        do {
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 }, startMonitoring: false)!
            try await controller.metadataTestUpdate(track("A", art: "art A"), diff: false)
            try await controller.metadataTestUpdate(track("Browser", art: "browser art", owner: "com.apple.Safari"), diff: false)
            var titles: [String] = []
            let subscription = controller.playbackStatePublisher.sink { titles.append($0.title) }
            try await controller.metadataTestUpdate(["bundleIdentifier": YandexMusicController.bundleID])
            try await controller.metadataTestUpdate(["elapsedTime": 20])
            try expect(!titles.contains("Browser") && controller.playbackState.artwork == Data("art A".utf8),
                       "Owner-only return relabeled a retained browser payload as Yandex")
            try await controller.metadataTestUpdate(track("B", art: "art B"))
            try expect(controller.playbackState.title == "B", "Fresh Yandex title did not release owner-only return guard")
            _ = subscription
            controller.stop(); passed += 1
            print("PASS owner-only return waits for source metadata")
        }
    }

    @MainActor
    private static func artworkAssociation() async throws {
        do {
            let fixture = MetadataGetFixture()
            await fixture.delay()
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller.metadataTestUpdate(track("A", id: "opaque A", art: "art A"), diff: false)
            var states: [PlaybackState] = []
            let subscription = controller.playbackStatePublisher.sink { states.append($0) }
            try await controller.metadataTestUpdate(["artworkData": Data("art B".utf8).base64EncodedString(), "contentItemIdentifier": "opaque B"])
            try expect(controller.playbackState.artwork == Data("art A".utf8), "Art-first diff exposed A text with B artwork")
            try await waitForAX("Staged artwork did not request validation") { await fixture.pending == 1 }
            try await controller.metadataTestUpdate(["title": "B", "album": "Album B"])
            try expect(controller.playbackState.artwork == nil, "New item retained A cover while validation was pending")
            try await waitForAX("New title did not request current artwork") { await fixture.pending == 2 }
            await fixture.finish(try wireSnapshot(track("B", album: "Album B", id: "opaque B", art: "art B")))
            try await Task.sleep(for: .milliseconds(20))
            try expect(controller.playbackState.artwork == nil, "Late pre-title snapshot applied under a different item")
            await fixture.finish(try wireSnapshot(track("B", album: "Album B", id: "opaque B", art: "art B")))
            try await waitFor("Current art-first cover was not recovered") { controller.playbackState.artwork == Data("art B".utf8) }
            try expect(!states.contains { $0.title == "A" && $0.artwork == Data("art B".utf8) }, "An intermediate publication mixed A text and B art")
            _ = subscription
            controller.stop(); passed += 1
            print("PASS art-first staging, canceled old validation and current snapshot recovery")
        }
        do {
            let fixture = MetadataGetFixture(try wireSnapshot(track("A", id: "opaque A", art: "quality A")))
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller.metadataTestUpdate(track("A", id: "opaque A", art: "art A"), diff: false)
            try await controller.metadataTestUpdate(["artworkData": Data("quality A".utf8).base64EncodedString()])
            try expect(controller.playbackState.artwork == Data("art A".utf8), "Quality change bypassed item validation")
            try await waitFor("Same-item higher quality cover was lost") { controller.playbackState.artwork == Data("quality A".utf8) }
            controller.stop(); passed += 1
            print("PASS same-item quality cover passes full snapshot validation")
        }
        for variant in ["valid", "owner", "id", "title", "artist", "album", "old art", "shared album"] {
            var response = track("B", album: "Album B", id: "opaque B", art: "art B")
            switch variant {
            case "owner": response["bundleIdentifier"] = "com.apple.Safari"
            case "id": response["contentItemIdentifier"] = "opaque A"
            case "title": response["title"] = "A"
            case "artist": response["artist"] = "Other"
            case "album": response["album"] = "Other"
            case "old art", "shared album": response["artworkData"] = Data("art A".utf8).base64EncodedString()
            default: break
            }
            let fixture = MetadataGetFixture(try wireSnapshot(response))
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller.metadataTestUpdate(track("A", album: variant == "shared album" ? "Album B" : "Album A", id: "opaque A", art: "art A"), diff: false)
            try await controller.metadataTestUpdate(["title": "B", "album": "Album B", "contentItemIdentifier": "opaque B"])
            try await waitForAX("New item did not validate missing artwork") { await fixture.reads == 1 }
            try await Task.sleep(for: .milliseconds(20))
            let accepted = variant == "valid" || variant == "shared album"
            try expect((controller.playbackState.artwork != nil) == accepted, "Snapshot association accepted/rejected wrong \(variant) cover")
            try await controller.metadataTestUpdate(["elapsedTime": 5])
            try expect((controller.playbackState.artwork != nil) == accepted, "Heartbeat resurrected previous-item cover")
            controller.stop(); passed += 1
            print("PASS missing-cover snapshot validation \(variant)")
        }
        do {
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 }, startMonitoring: false)!
            try await controller.metadataTestUpdate(track("Same base title", id: "opaque A", art: "art A"), diff: false)
            controller.metadataTestNativeTrackID("trusted native A")
            try await controller.metadataTestUpdate(["title": "Same base title", "contentItemIdentifier": "opaque B"])
            try expect(controller.playbackState.nativeTrackID == nil && controller.playbackState.artwork == nil,
                       "Different opaque item retained a previous recording's API ID or cover")
            controller.stop(); passed += 1
            print("PASS opaque item change clears API identity without promoting opaque IDs")
        }
        do {
            let fixture = MetadataGetFixture(try wireSnapshot(track("Same base title", id: "opaque B", art: "art B")))
            let controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller.metadataTestUpdate(track("Same base title", id: "opaque A", art: "art A"), diff: false)
            controller.metadataTestNativeTrackID("trusted native A")
            try await controller.metadataTestUpdate(["artworkData": Data("art B".utf8).base64EncodedString(), "contentItemIdentifier": "opaque B"])
            try expect(controller.playbackState.artwork == Data("art A".utf8), "Same-title item bypassed artwork association")
            try await waitFor("Verified same-title opaque item never promoted its cover") { controller.playbackState.artwork == Data("art B".utf8) }
            try expect(controller.playbackState.nativeTrackID == nil, "Verified new opaque item retained the old native recording ID")
            controller.stop(); passed += 1
            print("PASS same-title new opaque item verifies cover and releases old API identity")
        }
        for boundary in ["stop", "reset", "foreign"] {
            let fixture = MetadataGetFixture()
            await fixture.delay()
            var controller: YandexMusicController? = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller!.metadataTestUpdate(track("A", id: "opaque A", art: "art A"), diff: false)
            try await controller!.metadataTestUpdate(["artworkData": Data("quality A".utf8).base64EncodedString()])
            try await waitForAX("Lifecycle validation did not enter reader") { await fixture.pending == 1 }
            switch boundary {
            case "stop": controller!.stop()
            case "reset": controller!.metadataTestReset()
            default: try await controller!.metadataTestUpdate(track("Browser", owner: "com.apple.Safari"), diff: false)
            }
            await fixture.finish(try wireSnapshot(track("A", id: "opaque A", art: "quality A")))
            try await Task.sleep(for: .milliseconds(20))
            try expect(controller!.playbackState.artwork != Data("quality A".utf8), "Late artwork validation crossed \(boundary)")
            weak var weakController = controller
            controller = nil
            try await waitFor("Artwork validation retained its controller") { weakController == nil }
            passed += 1
            print("PASS artwork validation lifetime \(boundary)")
        }
        do {
            let fixture = MetadataGetFixture()
            await fixture.delay()
            var controller: YandexMusicController? = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 },
                startMonitoring: false, snapshotReader: { await fixture.read() })!
            try await controller!.metadataTestUpdate(track("A", id: "opaque A", art: "art A"), diff: false)
            try await controller!.metadataTestUpdate(["artworkData": Data("quality A".utf8).base64EncodedString()])
            try await waitForAX("Weak validation did not enter reader") { await fixture.pending == 1 }
            weak var weakController = controller
            controller = nil
            try await waitFor("In-flight snapshot read retained its controller") { weakController == nil }
            await fixture.finish(try wireSnapshot(track("A", id: "opaque A", art: "quality A")))
            passed += 1
            print("PASS in-flight artwork snapshot read releases the source before reply")
        }
    }

    @MainActor
    static func main() async throws {
        try await pausedTimelineReconciliation()
        try await pausedSeekIntent()
        try await delayedAXLifecycle()
        try await favoriteReconciliation()
        try await favoriteEvidenceContinuity()
        try await favoriteCommandPriority()
        try await favoriteToggleSemantics()
        try await scopedFavoriteFallback()
        try await favoriteHeartbeatAndOwnerChanges()
        try await favoriteFIFO()
        try await playbackEvidence()
        try await metadataOwnership()
        try await artworkAssociation()
        try await stream("parent owner survives helper-only diff", [
            update(["parentApplicationBundleIdentifier": "ru.yandex.desktop.music", "bundleIdentifier": "ru.yandex.helper.1",
                    "title": "Old title", "artist": "Old artist"], diff: false),
            update(["bundleIdentifier": "ru.yandex.helper.2"]),
            update(["title": "New title"]), update(["artist": "New artist"]),
            update(["artworkData": Data("new art".utf8).base64EncodedString()]),
        ], snapshot: ["bundleIdentifier": "ru.yandex.desktop.music", "title": "New title", "artist": "New artist",
                      "artworkData": Data("new art".utf8).base64EncodedString()]) { controller in
            try expect(controller.playbackState.title == "New title", "Helper diff lost Yandex title updates")
            try expect(controller.playbackState.artist == "New artist", "Artist update was dropped")
            try expect(controller.playbackState.artwork == Data("new art".utf8), "Artwork update was dropped")
        }

        try await stream("late parent removal recovers accumulated Yandex metadata", [
            update(["parentApplicationBundleIdentifier": "com.apple.Safari", "bundleIdentifier": "com.apple.WebKit.GPU",
                    "title": "Browser audiobook", "playing": false], diff: false),
            update(["bundleIdentifier": "ru.yandex.desktop.music"]),
            update(["title": "Yandex track", "artist": "Yandex artist", "artworkData": Data("cover".utf8).base64EncodedString()]),
            update(["parentApplicationBundleIdentifier": NSNull()]),
        ], snapshot: ["bundleIdentifier": "ru.yandex.desktop.music", "title": "Yandex track", "artist": "Yandex artist",
                      "artworkData": Data("cover".utf8).base64EncodedString()]) { controller in
            try expect(controller.playbackState.title == "Yandex track", "Removing stale parent did not restore Yandex")
            try expect(controller.playbackState.artwork == Data("cover".utf8), "Verified artwork received before owner was lost")
        }

        let fields: [[String: Any]] = [["title": "Новый трек 🎵"], ["artist": "Новый артист"],
                                     ["artworkData": Data("new art".utf8).base64EncodedString()]]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            try await stream("metadata order \(order)", [initial] + order.map { update(fields[$0]) },
                snapshot: ["bundleIdentifier": "ru.yandex.desktop.music", "title": "Новый трек 🎵", "artist": "Новый артист",
                           "album": "Old album", "artworkData": Data("new art".utf8).base64EncodedString()]) { controller in
                try expect(controller.playbackState.title == "Новый трек 🎵", "Title was lost")
                try expect(controller.playbackState.artist == "Новый артист", "Artist was lost")
                try expect(controller.playbackState.artwork == Data("new art".utf8), "Early/late artwork was lost")
            }
        }

        try await stream("explicit null removes title, artist and artwork", [initial,
            update(["title": NSNull(), "artist": NSNull(), "artworkData": NSNull()])]) { controller in
            try expect(controller.playbackState.title.isEmpty && controller.playbackState.artist.isEmpty, "Null metadata retained stale text")
            try expect(controller.playbackState.artwork == nil, "Null artwork retained previous cover")
        }

        try await stream("same-track full snapshot retains omitted artwork", [initial,
            update(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Old title", "artist": "Old artist", "album": "Old album"], diff: false)]) { controller in
            try expect(controller.playbackState.artwork == Data("old art".utf8), "Same-track redump flickered artwork")
        }

        try await stream("new-track full snapshot clears omitted artwork", [initial,
            update(["bundleIdentifier": "ru.yandex.desktop.music", "title": "New title", "artist": "New artist"], diff: false)]) { controller in
            try expect(controller.playbackState.title == "New title" && controller.playbackState.artwork == nil, "New full snapshot retained old cover")
        }

        try await stream("foreign owner does not hijack selected Yandex state", [initial,
            update(["bundleIdentifier": "com.apple.Safari", "title": "Browser title", "artist": "Browser artist", "playing": true], diff: false),
            update(["title": "Another browser title"]),
        ]) { controller in
            try expect(controller.playbackState.title == "Old title", "Browser metadata hijacked Yandex display")
            try expect(controller.systemMediaOwnerBundleIdentifier == "com.apple.Safari" && controller.systemMediaIsPlaying == true, "System observations did not expose foreign player")
        }

        try await stream("cleared full session rejects ownerless metadata", [initial, update([:], diff: false),
            update(["title": "Unowned track"])]) { controller in
            try expect(controller.playbackState.title == "Old title", "Cleared session retained Yandex ownership")
            try expect(controller.systemMediaOwnerBundleIdentifier == nil, "Empty snapshot retained old system owner")
        }

        try await stream("unknown nested fields do not discard metadata line", [initial,
            update(["title": "Nested-safe title", "unknown": ["nested": [1, 2, 3]]])]) { controller in
            try expect(controller.playbackState.title == "Nested-safe title", "Unsupported extra payload discarded update")
        }

        try await stream("initial paused foreign session has a stable quiet-time baseline", [
            update(["bundleIdentifier": "com.apple.Safari", "title": "Paused browser", "playing": false,
                    "timestamp": "2026-10-23T12:00:00Z"], diff: false),
        ]) { controller in
            let baseline = controller.lastForeignMediaActivity
            try expect(baseline != nil, "Initial paused session had no quiet-time baseline")
            try await controller.metadataTestUpdate(["timestamp": "2026-10-23T12:00:01Z"])
            try expect(controller.lastForeignMediaActivity == baseline, "Timestamp-only tick moved quiet-time baseline")
        }

        try await stream("AX fallback updates track and rejects stale image completion", [initial,
            update(["bundleIdentifier": "com.apple.Safari", "title": "Paused browser", "playing": false], diff: false)]) { controller in
            let oldGeneration = controller.metadataTestPrimeArtwork("old-request")
            let bar = node("AXGroup", children: [node("AXLink", "Track Fresh Yandex title"), node("AXButton", "Pause")])
            controller.metadataTestApplyAX(bar)
            try expect(controller.playbackState.title == "Fresh Yandex title", "Foreign system owner froze AX title")
            try expect(controller.playbackState.artwork == nil, "New AX track retained previous cover")
            try expect(controller.accessibilityIsPlaying == true && controller.accessibilityMetadataLastReadAt != nil, "AX observations were not refreshed")
            controller.metadataTestFinishArtwork(Data("old cover".utf8), key: "old-request", generation: oldGeneration)
            try expect(controller.playbackState.artwork == nil, "Previous-track image overwrote new AX track")
            let generation = controller.metadataTestPrimeArtwork("current-request")
            controller.metadataTestFinishArtwork(Data("current cover".utf8), key: "current-request", generation: generation)
            try expect(controller.playbackState.artwork == Data("current cover".utf8), "Current-track image completion was lost")
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Native title", "artist": "Native artist",
                                                    "artworkData": Data("native cover".utf8).base64EncodedString()], diff: false)
            controller.metadataTestFinishArtwork(Data("late AX cover".utf8), key: "current-request", generation: generation)
            try expect(controller.playbackState.artwork == Data("native cover".utf8), "Late AX image overwrote restored native session")
        }

        try await stream("fractional adapter timestamp and meaningful foreign activity", [
            update(["bundleIdentifier": "com.apple.Safari", "title": "Paused browser", "playing": false,
                    "timestamp": "2026-10-23T12:00:00.250Z"], diff: false),
            update(["playing": true]),
        ]) { controller in
            try expect(controller.systemMediaTimestamp != nil, "Fractional adapter timestamp was not decoded")
            try expect(controller.lastForeignMediaActivity != nil, "Actual foreign playback was not recorded")
            let activity = controller.lastForeignMediaActivity
            try await controller.metadataTestUpdate(["timestamp": "2026-10-23T12:00:01.250Z"])
            try expect(controller.lastForeignMediaActivity == activity, "Timestamp tick changed foreign activity while playing")
        }

        let bar = node("AXGroup", children: [
            node("AXLink", "Трек Новый трек", url: "https://music.yandex.ru/album/123/track/456"),
            node("AXLink", "Артист Новый артист", url: "https://music.yandex.ru/artist/789"),
            node("AXLink", "Артист Second artist", url: "https://music.yandex.ru/artist/790"),
            node("AXImage", url: "https://avatars.yandex.net/get-music-content/cover/200x200"),
            node("AXButton", "Пауза"),
        ])
        let parsed = YandexAccessibilityMetadata(root: bar)
        try expect(parsed?.title == "Новый трек" && parsed?.artist == "Новый артист, Second artist", "AX labels lost track/artist metadata")
        try expect(parsed?.trackID == "456" && parsed?.artworkURL != nil && parsed?.isPlaying == true, "AX snapshot lost track id, image or play state")
        let desktop = node("AXGroup", children: [node("AXLink", "Track Desktop track", url: "music-application://desktop/album/123/track/456"), node("AXLink", "Artist Desktop artist", url: "music-application://desktop/artist/789")])
        try expect(YandexAccessibilityMetadata(root: desktop)?.trackID == "456" && YandexAccessibilityMetadata(root: desktop)?.artist == "Desktop artist", "Desktop app's custom renderer URLs were rejected")
        let foreign = node("AXGroup", children: [node("AXLink", "Track Untrusted link", url: "https://evil.example/album/123/track/456")])
        try expect(YandexAccessibilityMetadata(root: foreign)?.trackID == nil, "Untrusted entity link triggered exact-id lookup")
        passed += 1
        print("PASS localized AX player metadata and exact track id")

        for (label, expected) in [("Pause", true), ("Пауза", true), ("Playback", false), ("Воспроизведение", false)] {
            let tree = node("AXGroup", children: [node("AXLink", "Track Example", url: "https://music.yandex.ru/album/1/track/2"), node("AXButton", label)])
            try expect(YandexAccessibilityMetadata(root: tree)?.isPlaying == expected, "Unreliable AX play/pause label")
        }
        let unknown = node("AXGroup", children: [node("AXLink", "Track Example", url: "https://music.yandex.ru/album/1/track/2"), node("AXButton", "Unknown control")])
        try expect(YandexAccessibilityMetadata(root: unknown)?.isPlaying == nil, "Unknown AX state was guessed")
        let library = node("AXGroup", children: [node("AXLink", "Track One", url: "https://music.yandex.ru/album/1/track/2"), node("AXLink", "Track Two", url: "https://music.yandex.ru/album/1/track/3")])
        try expect(YandexAccessibilityMetadata(root: library) == nil, "Library rows were mistaken for player metadata")
        let sameTitleLibrary = node("AXGroup", children: [node("AXLink", "Track Intro", url: "https://music.yandex.ru/album/1/track/2"), node("AXLink", "Track Intro", url: "https://music.yandex.ru/album/1/track/3")])
        try expect(YandexAccessibilityMetadata(root: sameTitleLibrary) == nil, "Same-title library rows were mistaken for player metadata")
        for address in ["http://avatars.yandex.net/cover", "https://evil.example/cover", "https://avatars.yandex.net.evil.example/cover", "https://user@avatars.yandex.net/cover"] {
            try expect(!YandexAccessibilityMetadata.isTrustedArtworkURL(URL(string: address)!), "Untrusted cover URL was accepted")
        }
        passed += 1
        print("PASS AX unknown state, library rejection and trusted cover hosts")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [YandexMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let lookup = node("AXGroup", children: [node("AXLink", "Track Exact lookup", url: "music-application://desktop/album/123/track/456")])
        YandexMetadataURLProtocol.requests = []
        YandexMetadataURLProtocol.respond = { request in
            if request.url?.host == "api.music.yandex.net" {
                return (request.url!, 200, Data(#"{"result":[{"coverUri":"avatars.yandex.net/get-music-content/exact/%%"}]}"#.utf8))
            }
            return (request.url!, 200, Data("exact artwork".utf8))
        }
        let cover = await YandexMusicController.metadataTestFetchArtwork(lookup, token: "fixture-token", session: session)
        try expect(cover == Data("exact artwork".utf8), "Exact track-id artwork lookup failed")
        try expect(YandexMetadataURLProtocol.requests.map { $0.url!.absoluteString } == ["https://api.music.yandex.net/tracks/456", "https://avatars.yandex.net/get-music-content/exact/200x200"], "Cover lookup searched metadata or fetched the wrong track")
        try expect(YandexMetadataURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "OAuth fixture-token", "Optional API credential was missing")
        try expect(YandexMetadataURLProtocol.requests[1].value(forHTTPHeaderField: "Authorization") == nil, "Credential was sent to artwork CDN")
        passed += 1
        print("PASS exact track-id cover lookup keeps credentials off CDN")

        YandexMetadataURLProtocol.requests = []
        _ = await YandexMusicController.metadataTestFetchArtwork(lookup, token: "", session: session)
        try expect(YandexMetadataURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == nil, "Anonymous cover lookup sent a credential")
        let withImage = node("AXGroup", children: [node("AXLink", "Track Direct image"), node("AXImage", url: "https://avatars.yandex.net/cover")])
        YandexMetadataURLProtocol.requests = []
        YandexMetadataURLProtocol.respond = { _ in (URL(string: "https://evil.example/redirected-cover")!, 200, Data("untrusted artwork".utf8)) }
        let untrusted = await YandexMusicController.metadataTestFetchArtwork(withImage, token: "fixture-token", session: session)
        try expect(untrusted == nil, "Artwork redirected outside trusted CDN was accepted")
        YandexMetadataURLProtocol.requests = []
        let cancelled = Task { await YandexMusicController.metadataTestFetchArtwork(lookup, token: "", session: session) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        try expect(cancelledResult == nil && YandexMetadataURLProtocol.requests.isEmpty, "Cancelled image request still loaded data")
        passed += 1
        print("PASS anonymous lookup, redirected image rejection and request cancellation")
        print("\(passed) Yandex metadata/lifecycle checks passed; real player controls were never invoked.")
    }
}
