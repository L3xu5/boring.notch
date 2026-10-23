// This file is appended to the production controller by test_yandex_metadata.py so fixtures
// can exercise private wire decoding, state reduction and AX parsing without test-only app APIs.
private final class YandexMusicTokenStore {
    static let shared = YandexMusicTokenStore()
    let token = ""
}

private struct YandexMetadataFailure: Error, CustomStringConvertible {
    let description: String
}

private actor DelayedYandexAX: YandexAccessibilityProviding {
    private var actions: [YandexPlayerAction] = []
    private var actionWaiters: [CheckedContinuation<Bool, Never>] = []
    private var favoriteWaiters: [CheckedContinuation<Bool?, Never>] = []
    var pendingActions: Int { actionWaiters.count }
    var pendingFavorites: Int { favoriteWaiters.count }
    var performedCount: Int { actions.count }
    func read(processIdentifier: pid_t) -> YandexAccessibilityMetadata? { nil }
    func perform(_ action: YandexPlayerAction, processIdentifier: pid_t,
                 isCurrent: @escaping @Sendable () -> Bool) async -> Bool {
        let success = await withCheckedContinuation { actionWaiters.append($0) }
        guard success, !Task.isCancelled, isCurrent() else { return false }
        actions.append(action)
        return true
    }
    func favoriteState(processIdentifier: pid_t) async -> Bool? {
        await withCheckedContinuation { favoriteWaiters.append($0) }
    }
    func finishAction(_ result: Bool) { actionWaiters.removeFirst().resume(returning: result) }
    func finishFavorite(_ result: Bool?) { favoriteWaiters.removeFirst().resume(returning: result) }
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
        var controller = YandexMusicController()
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
