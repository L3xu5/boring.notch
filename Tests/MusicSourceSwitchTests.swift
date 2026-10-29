// The runner appends this fixture to the whole production MusicManager. All source routing,
// task cancellation, preference resolution and presentation-reset behavior is production code.
// Fakes replace only players, bridge probe, stores and presentation/network services.

enum MediaControllerType: String { case nowPlaying, appleMusic, spotify, youtubeMusic, yandexMusic }
enum FixtureSneakPeekStyle { case standard, compact }
extension Defaults.Keys {
    static let mediaController = Defaults.Key<MediaControllerType>("source", default: .yandexMusic)
    static let enableLyrics = Defaults.Key<Bool>("lyrics", default: false)
    static let coloredSpectrogram = Defaults.Key<Bool>("tint", default: false)
    static let waitInterval = Defaults.Key<Double>("idleWait", default: 1)
    static let enableSneakPeek = Defaults.Key<Bool>("peek", default: false)
    static let sneakPeekStyles = Defaults.Key<FixtureSneakPeekStyle>("peekStyle", default: .standard)
}
@MainActor enum MediaExecutionMode { static var isIsolatedPreview = true }
struct BoringAnimations {}
enum FixturePeekType { case music }
@MainActor final class BoringViewCoordinator {
    static let shared = BoringViewCoordinator()
    func toggleSneakPeek(status: Bool, type: FixturePeekType) {}
    func toggleExpandingView(status: Bool, type: FixturePeekType) {}
}

actor FixtureProbe {
    private var waiters: [CheckedContinuation<Bool, Error>] = []
    private(set) var entered = 0
    var pending: Int { waiters.count }
    func check() async throws -> Bool {
        entered += 1
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
    func finish(_ deprecated: Bool) { waiters.removeFirst().resume(returning: deprecated) }
    func fail() { waiters.removeFirst().resume(throwing: URLError(.timedOut)) }
}
final class MediaChecker: Sendable {
    static let probe = FixtureProbe()
    func checkDeprecationStatus() async throws -> Bool { try await Self.probe.check() }
}

@MainActor enum FixturePlayers {
    static var created: [MediaControllerType: [FixtureController]] = [:]
    static func record(_ controller: FixtureController, source: MediaControllerType) {
        created[source, default: []].append(controller)
    }
    static func last(_ source: MediaControllerType) -> FixtureController? { created[source]?.last }
}
@MainActor class FixtureController: MediaControllerProtocol {
    @Published private(set) var state: PlaybackState
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $state.eraseToAnyPublisher() }
    var supportsVolumeControl: Bool { true }
    var supportsFavorite: Bool { !stopped }
    var currentFavoriteState: Bool? { stopped ? nil : state.isFavorite }
    var supportsDislike: Bool { !stopped }
    private(set) var stopped = false
    private(set) var stopCount = 0
    private(set) var acceptedFavorites = 0
    private(set) var cancelledFavorites = 0
    private var favoriteWaiters: [CheckedContinuation<Void, Never>] = []
    var pendingFavorites: Int { favoriteWaiters.count }
    init(source: MediaControllerType) {
        state = .init(bundleIdentifier: "fixture." + source.rawValue, isPlaying: true,
                      title: source.rawValue + " title", artist: "Fixture artist", album: "Fixture album",
                      currentTime: 40, duration: 180, isShuffled: true, repeatMode: .all,
                      volume: 0.8, isFavorite: true, nativeTrackID: "123")
        FixturePlayers.record(self, source: source)
    }
    func publishLateState() { var next = state; next.title = "Late old player"; state = next }
    func stop() { stopped = true; stopCount += 1 }
    func toggleFavorite() async {
        await withCheckedContinuation { favoriteWaiters.append($0) }
        guard !Task.isCancelled, !stopped else { cancelledFavorites += 1; return }
        acceptedFavorites += 1
    }
    func finishFavorite() { favoriteWaiters.removeFirst().resume() }
    func setFavorite(_ favorite: Bool) async {}
    func dislike() async {}
    func play() async {}
    func pause() async {}
    func seek(to time: Double) async {}
    func nextTrack() async {}
    func previousTrack() async {}
    func togglePlay() async {}
    func toggleShuffle() async {}
    func toggleRepeat() async {}
    func setVolume(_ level: Double) async {}
    func isActive() -> Bool { !stopped }
    func updatePlaybackInfo() async {}
}
@MainActor final class AppleMusicController: FixtureController { init() { super.init(source: .appleMusic) } }
@MainActor final class NowPlayingController: FixtureController { init() { super.init(source: .nowPlaying) } }
@MainActor final class SpotifyController: FixtureController { init() { super.init(source: .spotify) } }
@MainActor final class YouTubeMusicController: FixtureController {
    init() { super.init(source: .youtubeMusic) }
    func pollPlaybackState() async {}
}
@MainActor final class YandexMusicController: FixtureController {
    var systemMediaOwnerBundleIdentifier: String?
    var systemMediaIsPlaying: Bool?
    var lastForeignMediaActivity: Date?
    var accessibilityIsPlaying: Bool?
    var accessibilityMetadataLastReadAt: Date?
    init() { super.init(source: .yandexMusic) }
    func refreshAccessibilityMetadata() async {}
    func togglePlayWithReceipt() async -> Bool { false }
}

@MainActor final class ArtworkPresentationService {
    @Published var image: NSImage
    @Published var usesApplicationIcon = false
    @Published var color: NSColor = .white
    init(defaultImage: NSImage, colorEnabled: @escaping () -> Bool) { image = defaultImage }
    func stop() {}
    func setImage(_ image: NSImage) { self.image = image }
    func apply(data: Data?, bundleIdentifier: String, identity: MediaItemIdentity? = nil,
               artworkItemIdentifier: String? = nil) {}
    func calculateAverageColor() {}
}
func AppIconAsNSImage(for bundle: String) -> NSImage? { nil }
struct LyricsRequest {
    let source: String; let bundleIdentifier: String?; let title: String; let artist: String
    let album: String; let duration: Double; let nativeTrackID: String?; let yandexToken: String
}
@MainActor final class LyricsService {
    @Published var document = LyricsDocument(plain: "", synced: [])
    @Published var isFetching = false
    init() {}
    init(cache: LyricsCache, nativeLyrics: @escaping @MainActor () async throws -> String?) {}
    func stop(clear: Bool) {}
    func request(_ request: LyricsRequest, enabled: Bool, force: Bool) {}
}
@MainActor final class YandexMusicTokenStore {
    static let shared = YandexMusicTokenStore()
    @Published var token = ""
}
@MainActor enum AppleScriptHelper { static func execute(_ script: String) async throws -> NSAppleEventDescriptor? { nil } }
struct FixtureRecoverySnapshot {
    let systemOwner: String?; let systemIsPlaying: Bool?; let foreignActivity: Date?; let yandexIsPlaying: Bool?
    let accessibilityObservedAt: Date?; let foregroundApp: String?; let capturedAt: Date
}
@MainActor final class MediaKeyRecoveryCoordinator {
    init(snapshot: @escaping @MainActor () -> FixtureRecoverySnapshot, refresh: @escaping @MainActor () async -> Void,
         toggle: @escaping @MainActor () async -> Bool, isActive: @escaping @MainActor () -> Bool) {}
    func stop() {}
    func handlePlayPause() {}
}
extension Notification.Name { static let mediaControllerChanged = Notification.Name("fixture.source.changed") }

private extension MusicManager {
    func sourceTestPrepare() {
        artworkPresentation = ArtworkPresentationService(defaultImage: defaultImage, colorEnabled: { false })
        lyricsService = LyricsService()
    }
    func sourceTestStart() { startSelectedSource() }
    var sourceTestSelected: MediaControllerType? { selectedSource }
    var sourceTestHasController: Bool { activeController != nil }
    var sourceTestCommandCount: Int { commandTasks.count }
    var sourceTestBridgeChecked: Bool { bridgeChecked }
    func sourceTestSeedPresentation() {
        albumArt = NSImage(size: NSSize(width: 8, height: 8))
        avgColor = .red
        usingAppIconForArtwork = true
        currentLyrics = "Old lyrics"
        syncedLyrics = [(time: 1, text: "Old synced lyrics")]
        isFetchingLyrics = true
    }
}

@main @MainActor private enum MusicSourceSwitchTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }
    private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()) {
            guard Date() < deadline else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func manager(_ source: MediaControllerType = .yandexMusic) async throws -> MusicManager {
        MediaExecutionMode.isIsolatedPreview = true
        let manager = MusicManager()
        manager.sourceTestPrepare()
        Defaults[.mediaController] = source
        MediaExecutionMode.isIsolatedPreview = false
        manager.sourceTestStart()
        if source != .nowPlaying {
            try await eventually("Initial fixture source did not publish") { manager.songTitle == source.rawValue + " title" }
        }
        return manager
    }
    private static func emptyPresentation(_ manager: MusicManager) {
        expect(manager.songTitle.isEmpty && manager.artistName.isEmpty && manager.album.isEmpty && manager.bundleIdentifier == nil,
               "Previous source metadata remains visible during the probe")
        expect(!manager.isPlaying && manager.isPlayerIdle && manager.elapsedTime == 0 && manager.songDuration == 0,
               "Previous source timeline remains live during the probe")
        expect(!manager.canFavoriteTrack && !manager.canDislikeTrack && !manager.canSeek && !manager.isFavoriteStateKnown && !manager.isFavoriteTrack,
               "Previous source action capabilities or heart remain active during the probe")
        expect(manager.albumArt === defaultImage && !manager.usingAppIconForArtwork && manager.avgColor == .white,
               "Previous source artwork remains visible during the probe")
        expect(manager.currentLyrics.isEmpty && manager.syncedLyrics.isEmpty && !manager.isFetchingLyrics,
               "Previous source lyrics remain visible during the probe")
    }
    static func main() async throws {
        try await cancelOldSourceBeforeProbe()
        try await preserveSameSourceCommand()
        try await preserveResolvedFallback()
        try await rejectLateProbeAfterNewSelection()
        print("Music source switching: \(checks) checks passed (whole production manager; in-memory boundaries only)")
    }
    private static func cancelOldSourceBeforeProbe() async throws {
        let manager = try await manager()
        let old = FixturePlayers.last(.yandexMusic)!
        manager.sourceTestSeedPresentation()
        manager.toggleFavoriteTrack()
        try await eventually("Old source favorite did not enter fixture") { old.pendingFavorites == 1 }
        // Queue one final old publication before the transition; its receive(on:) block must
        // not refill cleared presentation after the old source has been detached.
        old.publishLateState()
        Defaults[.mediaController] = .nowPlaying
        manager.sourceTestStart()
        expect(old.stopped && old.stopCount == 1 && !manager.sourceTestHasController && manager.sourceTestSelected == nil,
               "Old source was not stopped before the asynchronous probe")
        expect(manager.sourceTestCommandCount == 0, "Pending commands remain owned during the probe")
        emptyPresentation(manager)
        try await eventually("Bridge fixture did not begin") { await MediaChecker.probe.pending == 1 }
        old.finishFavorite()
        try await eventually("Cancelled old favorite did not return") { old.cancelledFavorites == 1 }
        expect(old.acceptedFavorites == 0, "Old source accepted a late favorite after source selection changed")
        emptyPresentation(manager)
        await MediaChecker.probe.finish(false)
        try await eventually("New source did not replace a successful probe") { manager.sourceTestSelected == .nowPlaying }
        expect(manager.sourceTestBridgeChecked, "Successful probe was not recorded")
        manager.destroy()
    }
    private static func preserveSameSourceCommand() async throws {
        let manager = try await manager()
        let source = FixturePlayers.last(.yandexMusic)!
        manager.toggleFavoriteTrack()
        try await eventually("Same-source command did not enter fixture") { source.pendingFavorites == 1 }
        manager.sourceTestStart()
        expect(!source.stopped && manager.sourceTestSelected == .yandexMusic && manager.isFavoriteTrack,
               "Same-source notification tore down the active source or presentation")
        source.finishFavorite()
        try await eventually("Same-source command was dropped") { source.acceptedFavorites == 1 }
        expect(source.cancelledFavorites == 0, "Same-source notification cancelled a user command")
        manager.destroy()
    }
    private static func preserveResolvedFallback() async throws {
        let manager = try await manager(.nowPlaying)
        try await eventually("Deprecated-source probe did not begin") { await MediaChecker.probe.pending == 1 }
        await MediaChecker.probe.finish(true)
        try await eventually("Deprecated bridge did not select Apple fallback") { manager.sourceTestSelected == .appleMusic }
        let fallback = FixturePlayers.last(.appleMusic)!
        try await eventually("Fallback capability did not publish") { manager.canFavoriteTrack }
        let probes = await MediaChecker.probe.entered
        manager.toggleFavoriteTrack()
        try await eventually("Fallback command did not enter fixture") { fallback.pendingFavorites == 1 }
        manager.sourceTestStart()
        expect(!fallback.stopped && manager.sourceTestSelected == .appleMusic, "The unchanged resolved fallback was stopped")
        fallback.finishFavorite()
        try await eventually("Resolved fallback command was dropped") { fallback.acceptedFavorites == 1 }
        let finalProbes = await MediaChecker.probe.entered
        expect(finalProbes == probes, "An already checked bridge was probed again")
        manager.destroy()
    }
    private static func rejectLateProbeAfterNewSelection() async throws {
        let manager = try await manager()
        let old = FixturePlayers.last(.yandexMusic)!
        Defaults[.mediaController] = .nowPlaying
        manager.sourceTestStart()
        try await eventually("Cancelled probe fixture did not begin") { await MediaChecker.probe.pending == 1 }
        Defaults[.mediaController] = .spotify
        manager.sourceTestStart()
        try await eventually("Direct source did not bypass the pending probe") { manager.sourceTestSelected == .spotify }
        await MediaChecker.probe.finish(true)
        try await Task.sleep(for: .milliseconds(30))
        expect(old.stopCount == 1 && manager.sourceTestSelected == .spotify && !manager.sourceTestBridgeChecked,
               "A late cancelled probe replaced the newer source or poisoned bridge status")
        manager.destroy()
    }
}
