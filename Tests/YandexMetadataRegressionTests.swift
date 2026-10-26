// This file is appended to the production controller by test_yandex_metadata.py so fixtures
// can exercise private wire decoding, state reduction and AX parsing without test-only app APIs.
private final class YandexMusicTokenStore {
    static let shared = YandexMusicTokenStore()
    let token = ""
}

private struct YandexMetadataFailure: Error, CustomStringConvertible {
    let description: String
}

private func favoriteMetadata(_ favorite: Bool?, title: String = "Before", artist: String = "Artist",
                              trackID: String? = nil) -> YandexAccessibilityMetadata {
    let trackURL = trackID.flatMap { URL(string: "music-application://desktop/album/123/track/\($0)") }
    return YandexAccessibilityMetadata(root: .init(role: "AXGroup", labels: [], value: nil, url: nil, children: [
        .init(role: "AXLink", labels: ["Track \(title)"], value: nil, url: trackURL, children: []),
        .init(role: "AXLink", labels: ["Artist \(artist)"], value: nil,
              url: URL(string: "music-application://desktop/artist/1"), children: []),
        .init(role: "AXCheckBox", labels: ["Like"], value: favorite.map { $0 ? "1" : "0" }, url: nil, children: []),
    ]))!
}

private actor DelayedYandexAX: YandexAccessibilityProviding {
    private var actions: [YandexPlayerAction] = []
    private var actionWaiters: [CheckedContinuation<Bool, Never>] = []
    private var favoriteWaiters: [CheckedContinuation<YandexAccessibilityMetadata?, Never>] = []
    var pendingActions: Int { actionWaiters.count }
    var pendingFavorites: Int { favoriteWaiters.count }
    var performedCount: Int { actions.count }
    private(set) var favoriteTargets: [YandexFavoriteTarget] = []
    private(set) var setRequests: [Bool] = []
    private var fullMetadataUnavailable = false
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
    func finishAction(_ result: Bool) { actionWaiters.removeFirst().resume(returning: result) }
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
    init(_ metadata: YandexAccessibilityMetadata?) { self.metadata = metadata }
    func setSnapshot(_ metadata: YandexAccessibilityMetadata?) { self.metadata = metadata }
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
    @MainActor func metadataTestTerminate() { handleYandexTerminated() }
    @MainActor func metadataTestReset() { resetAdapterState() }
    @MainActor func metadataTestNativeTrackID(_ id: String) { playbackState.nativeTrackID = id }
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
            let controller = YandexMusicController(accessibility: client, processIdentifier: { 42 },
                onTransportUnavailable: {}, startMonitoring: false)!
            try await controller.metadataTestUpdate(["bundleIdentifier": "ru.yandex.desktop.music", "title": "Before", "artist": "Artist"], diff: false)
            await controller.refreshAccessibilityMetadata()
            try expect(controller.playbackState.isFavorite && controller.currentFavoriteState != nil, "Known liked snapshot was lost")
            await client.setSnapshot(favoriteMetadata(nil))
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "An unknown pressed state retained a false positive like")
            await controller.setFavorite(true)
            let attempts = await client.attempts
            try expect(attempts == 0, "Unknown favorite state caused a blind toggle")
            await client.setSnapshot(favoriteMetadata(true))
            await controller.refreshAccessibilityMetadata()
            await client.setSnapshot(nil)
            await controller.refreshAccessibilityMetadata()
            try expect(!controller.playbackState.isFavorite && controller.currentFavoriteState == nil,
                       "A missing/untrusted AX snapshot left an old like cached")
            controller.stop()
            passed += 1
            print("PASS unknown and unavailable favorite state clear the heart without a blind toggle")
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
            let newer = Task { await controller.setFavorite(true) }
            try await waitForAX("newer explicit command did not begin its read") { await client.pendingFavorites == 2 }
            await client.finishFavorite(false)
            await older.value
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
            print("PASS overlapping favorite commands keep the newest priority and release it on completion")
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
    private static func stream(_ name: String, _ messages: [[String: Any]],
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
        var controller = YandexMusicController(accessibility: SnapshotYandexAX(nil), processIdentifier: { 42 })
        guard controller != nil else { throw YandexMetadataFailure(description: "MediaRemote initialization unavailable") }
        weak var weakController = controller
        defer { weakController = nil }
        try await waitFor("fixture stream did not complete") { FileManager.default.fileExists(atPath: done.path) }
        try await Task.sleep(for: .milliseconds(80))
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

    @MainActor
    static func main() async throws {
        try await delayedAXLifecycle()
        try await favoriteReconciliation()
        try await favoriteCommandPriority()
        try await favoriteToggleSemantics()
        try await scopedFavoriteFallback()
        try await stream("parent owner survives helper-only diff", [
            update(["parentApplicationBundleIdentifier": "ru.yandex.desktop.music", "bundleIdentifier": "ru.yandex.helper.1",
                    "title": "Old title", "artist": "Old artist"], diff: false),
            update(["bundleIdentifier": "ru.yandex.helper.2"]),
            update(["title": "New title"]), update(["artist": "New artist"]),
            update(["artworkData": Data("new art".utf8).base64EncodedString()]),
        ]) { controller in
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
        ]) { controller in
            try expect(controller.playbackState.title == "Yandex track", "Removing stale parent did not restore Yandex")
            try expect(controller.playbackState.artwork == Data("cover".utf8), "Metadata received before owner was lost")
        }

        let fields: [[String: Any]] = [["title": "Новый трек 🎵"], ["artist": "Новый артист"],
                                     ["artworkData": Data("new art".utf8).base64EncodedString()]]
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            try await stream("metadata order \(order)", [initial] + order.map { update(fields[$0]) }) { controller in
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
