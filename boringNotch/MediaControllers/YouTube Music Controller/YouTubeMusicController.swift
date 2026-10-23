import AppKit
import Combine
import Foundation
import BoringCore

private struct YouTubeWorkspaceEnvironment: YouTubeMusicEnvironment {
    let bundleIdentifier: String
    func isRunning() async -> Bool {
        await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty }
    }
    func launch() async {
        await MainActor.run {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
private struct YouTubeNativeArtworkLoader: YouTubeArtworkLoading {
    func fetch(from url: URL) async throws -> Data { try await ImageService.shared.fetchImageData(from: url) }
}

/// Workspace/Combine adapter. The core session owns every network, polling, backoff and
/// artwork task; source stop is final, while application termination keeps launch observation.
@MainActor
final class YouTubeMusicController: MediaControllerProtocol {
    @Published private(set) var playbackState: PlaybackState
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { $playbackState.eraseToAnyPublisher() }
    var supportsVolumeControl: Bool { true }
    var supportsFavorite: Bool { true }
    private let configuration: YouTubeMusicConfiguration
    private var session: YouTubeMusicSession?
    private var startupTask: Task<Void, Never>?
    private var observations: [NotificationObservation] = []
    private var stopped = false
    private var latestSequence: UInt64 = 0

    init(configuration: YouTubeMusicConfiguration = .default) {
        self.configuration = configuration
        playbackState = .init(bundleIdentifier: configuration.bundleIdentifier)
        let session = YouTubeMusicSession(configuration: configuration,
            http: YouTubeMusicHTTPClient(baseURL: configuration.baseURL),
            environment: YouTubeWorkspaceEnvironment(bundleIdentifier: configuration.bundleIdentifier),
            artwork: YouTubeNativeArtworkLoader()) { [weak self] event in
                Task { @MainActor in
                    guard let self, !self.stopped, event.sequence > self.latestSequence else { return }
                    self.latestSequence = event.sequence
                    self.playbackState = event.state
                }
            }
        self.session = session
        let center = NSWorkspace.shared.notificationCenter
        for (name, running) in [(NSWorkspace.didLaunchApplicationNotification, true),
                                (NSWorkspace.didTerminateApplicationNotification, false)] {
            observations.append(NotificationObservation(center: center, name: name, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      application.bundleIdentifier == configuration.bundleIdentifier else { return }
                Task { @MainActor in
                    guard let self, !self.stopped else { return }
                    await self.session?.applicationStateChanged(isRunning: running)
                }
            })
        }
        startupTask = Task { await session.start() }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        startupTask?.cancel(); startupTask = nil
        observations.forEach { $0.cancel() }; observations.removeAll()
        let session = session; self.session = nil
        session?.requestStop()
        Task { await session?.stop() }
    }
    func isActive() -> Bool {
        !stopped && !NSRunningApplication.runningApplications(withBundleIdentifier: configuration.bundleIdentifier).isEmpty
    }
    func play() async { await session?.play() }
    func pause() async { await session?.pause() }
    func togglePlay() async { await session?.togglePlay() }
    func nextTrack() async { await session?.nextTrack() }
    func previousTrack() async { await session?.previousTrack() }
    func seek(to time: Double) async { await session?.seek(to: time) }
    func setVolume(_ level: Double) async { await session?.setVolume(level) }
    func setFavorite(_ favorite: Bool) async { await session?.setFavorite(favorite) }
    func toggleShuffle() async { await session?.toggleShuffle() }
    func toggleRepeat() async { await session?.toggleRepeat() }
    func fetchShuffleState() async { await session?.fetchShuffleState() }
    func fetchRepeatMode() async { await session?.fetchRepeatMode() }
    func updatePlaybackInfo() async { await session?.updatePlaybackInfo() }
    func pollPlaybackState() async {
        await startupTask?.value
        guard !stopped else { return }
        await session?.fetchRepeatMode()
        await session?.fetchShuffleState()
        await session?.updatePlaybackInfo()
    }
    deinit {
        startupTask?.cancel()
        observations.forEach { $0.cancel() }
        let session = session
        session?.requestStop()
        Task { await session?.stop() }
    }
}
