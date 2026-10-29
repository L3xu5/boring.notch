//
//  MusicManager.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 03/08/24.
//
import BoringCore
import AppKit
import Combine
import CryptoKit
import Defaults
import SwiftUI

let defaultImage: NSImage = .init(
    systemSymbolName: "music.note",
    accessibilityDescription: "Album Art"
)!

@MainActor
class MusicManager: ObservableObject {
    // MARK: - Properties
    static let shared = MusicManager()
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables = Set<AnyCancellable>()
    private var debounceIdleTask: Task<Void, Never>?

    // Helper to check if macOS has removed support for NowPlayingController
    @Published public private(set) var isNowPlayingDeprecated: Bool = false
    private let mediaChecker = MediaChecker()
    private var initializationTask: Task<Void, Never>?
    private var bridgeChecked = false

    // Active controller
    private var activeController: (any MediaControllerProtocol)?
    private var selectedSource: MediaControllerType?
    private var credentialsObserved = false

    // Published properties for UI
    @Published var songTitle: String = ""
    @Published var artistName: String = ""
    @Published var albumArt: NSImage = defaultImage
    @Published var isPlaying = false
    @Published var album: String = ""
    @Published var isPlayerIdle: Bool = true
    @Published var animations: BoringAnimations = .init()
    @Published var avgColor: NSColor = .white
    @Published var bundleIdentifier: String? = nil
    @Published var songDuration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var timestampDate: Date = .init()
    @Published var playbackRate: Double = 1
    @Published var isShuffled: Bool = false
    @Published var repeatMode: RepeatMode = .off
    @Published var volume: Double = 0.5
    @Published var volumeControlSupported: Bool = true
    @Published private(set) var mediaCapabilities = MediaCapabilities()
    var canSeek: Bool { mediaCapabilities.seek }
    var coordinator: BoringViewCoordinator { BoringViewCoordinator.shared }
    @Published var usingAppIconForArtwork: Bool = false
    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []
    @Published var canFavoriteTrack: Bool = false
    @Published var canDislikeTrack: Bool = false
    @Published var isFavoriteTrack: Bool = false
    @Published private(set) var isFavoriteStateKnown: Bool = false

    private var presentationSnapshot: PlaybackState?
    private var artworkPresentation: ArtworkPresentationService!

    private var lyricsService: LyricsService!
    private var nativeTrackID: String?
    private var commandTasks: [UUID: Task<Void, Never>] = [:]
    private var mediaKeyRecoveryCoordinator: MediaKeyRecoveryCoordinator?

    @Published var isFlipping: Bool = false
    private var flipWorkItem: DispatchWorkItem?

    @Published var isTransitioning: Bool = false
    private var transitionWorkItem: DispatchWorkItem?

    // MARK: - Initialization
    init() {
        guard !MediaExecutionMode.isIsolatedPreview else { return }
        configureArtworkPresentation()
        configureLyricsService()

        // Listen for changes to the default controller preference
        NotificationCenter.default.publisher(for: Notification.Name.mediaControllerChanged)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.startSelectedSource() }
            }
            .store(in: &cancellables)

        // React to the lyrics toggle live: fetch for the current track when enabled, clear when off.
        Defaults.publisher(.enableLyrics)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self else { return }
                    if change.newValue {
                        self.fetchLyricsIfAvailable(bundleIdentifier: self.bundleIdentifier, title: self.songTitle, artist: self.artistName, album: self.album, duration: self.songDuration)
                    } else {
                        self.cancelLyricsFetch()
                        self.isFetchingLyrics = false
                        self.currentLyrics = ""
                        self.syncedLyrics = []
                    }
                }
            }
            .store(in: &cancellables)

        // Onboarding explicitly starts the chosen source via mediaControllerChanged. A new
        // install must not launch an adapter, probe or AppleScript before that choice.
        let firstLaunch = UserDefaults.standard.object(forKey: "firstLaunch") as? Bool ?? true
        guard MediaStartupPolicy.shouldStartAutomatically(firstLaunch: firstLaunch, isolatedPreview: MediaExecutionMode.isIsolatedPreview) else { return }
        startSelectedSource()
    }

    private func startSelectedSource() {
        guard !MediaExecutionMode.isIsolatedPreview else { return }
        initializationTask?.cancel(); initializationTask = nil
        let preferredType = Defaults[.mediaController]
        if activeController != nil, selectedSource != resolvedControllerType(preferredType) {
            // The requested source changes now, not when an optional bridge probe finishes.
            // Invalidate commands and observations before awaiting that probe so an old AX
            // lookup cannot still press the previous player's controls during the transition.
            clearActiveSource()
        }
        // Probing follows an explicit source choice (or an existing user's saved choice).
        // Direct controllers do not need a generic bridge probe before they can start.
        guard preferredType == .nowPlaying, !bridgeChecked else {
            setActiveControllerBasedOnPreference(); return
        }
        initializationTask = Task { @MainActor [weak self, mediaChecker] in
            do {
                let deprecated = try await mediaChecker.checkDeprecationStatus()
                guard let self, !Task.isCancelled else { return }
                self.isNowPlayingDeprecated = deprecated
            } catch { guard !Task.isCancelled else { return } }
            guard let self, !Task.isCancelled else { return }
            self.bridgeChecked = true
            self.setActiveControllerBasedOnPreference()
        }
    }

    private func resolvedControllerType(_ preferredType: MediaControllerType) -> MediaControllerType {
        isNowPlayingDeprecated && preferredType == .nowPlaying ? .appleMusic : preferredType
    }

    private func clearActiveSource() {
        cancelMediaKeyRecovery()
        commandTasks.values.forEach { $0.cancel() }; commandTasks.removeAll()
        controllerCancellables.removeAll()
        activeController?.stop()
        activeController = nil
        selectedSource = nil
        cancelLyricsFetch()
        artworkPresentation?.setImage(defaultImage)
        debounceIdleTask?.cancel(); debounceIdleTask = nil
        flipWorkItem?.cancel(); flipWorkItem = nil
        transitionWorkItem?.cancel(); transitionWorkItem = nil
        presentationSnapshot = nil
        nativeTrackID = nil
        songTitle = ""
        artistName = ""
        album = ""
        bundleIdentifier = nil
        isPlaying = false
        isPlayerIdle = true
        songDuration = 0
        elapsedTime = 0
        timestampDate = Date()
        playbackRate = 1
        isShuffled = false
        repeatMode = .off
        volume = 0.5
        volumeControlSupported = false
        mediaCapabilities = .init(volume: false, favorite: false, dislike: false,
                                  seek: false, shuffle: false, repeatMode: false)
        canFavoriteTrack = false
        canDislikeTrack = false
        isFavoriteStateKnown = false
        isFavoriteTrack = false
        albumArt = defaultImage
        usingAppIconForArtwork = false
        avgColor = .white
        currentLyrics = ""
        syncedLyrics = []
        isFetchingLyrics = false
        isFlipping = false
        isTransitioning = false
    }


    public func destroy() {
        initializationTask?.cancel(); initializationTask = nil
        debounceIdleTask?.cancel()
        cancelMediaKeyRecovery()
        artworkPresentation?.stop()
        cancelLyricsFetch()
        commandTasks.values.forEach { $0.cancel() }; commandTasks.removeAll()
        cancellables.removeAll()
        controllerCancellables.removeAll()
        flipWorkItem?.cancel()
        transitionWorkItem?.cancel()

        // Explicitly stop effects before releasing the selected source.
        activeController?.stop()
        activeController = nil
        selectedSource = nil
        canFavoriteTrack = false
        isFavoriteStateKnown = false
        isFavoriteTrack = false
    }

    // MARK: - Setup Methods
    private func createController(for type: MediaControllerType) -> (any MediaControllerProtocol)? {
        cancelMediaKeyRecovery()
        commandTasks.values.forEach { $0.cancel() }; commandTasks.removeAll()
        cancelLyricsFetch()
        artworkPresentation?.stop()
        // Cleanup previous controller
        if activeController != nil {
            controllerCancellables.removeAll()
            activeController?.stop()
            activeController = nil
        }

        let newController: (any MediaControllerProtocol)?

        switch type {
        case .nowPlaying:
            // Only create NowPlayingController if not deprecated on this macOS version
            if !self.isNowPlayingDeprecated {
                newController = NowPlayingController()
            } else {
                return nil
            }
        case .appleMusic:
            newController = AppleMusicController()
        case .spotify:
            newController = SpotifyController()
        case .youtubeMusic:
            newController = YouTubeMusicController()
        case .yandexMusic:
            newController = YandexMusicController()
        }

        // Set up state observation for the new controller
        if let controller = newController {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    guard let self = self,
                          self.activeController === controller else { return }
                    self.updateFromPlaybackState(state)
                }
                .store(in: &controllerCancellables)
        }

        return newController
    }

    private func observeCredentialsIfNeeded() {
        guard !credentialsObserved, Defaults[.mediaController] == .yandexMusic else { return }
        credentialsObserved = true
        YandexMusicTokenStore.shared.$token.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, Defaults[.mediaController] == .yandexMusic else { return }
                self.reloadLyricsForCurrentTrack()
            }
        }.store(in: &cancellables)
    }

    private func setActiveControllerBasedOnPreference() {
        guard !MediaExecutionMode.isIsolatedPreview else { return }
        observeCredentialsIfNeeded()
        let preferredType = Defaults[.mediaController]
        print("Preferred Media Controller: \(preferredType)")

        // If NowPlaying is deprecated but that's the preference, use Apple Music instead
        let controllerType = resolvedControllerType(preferredType)

        guard activeController == nil || selectedSource != controllerType else { return }
        if let controller = createController(for: controllerType) {
            selectedSource = controllerType
            setActiveController(controller)
        } else if controllerType != .appleMusic, let fallbackController = createController(for: .appleMusic) {
            // Fallback to Apple Music if preferred controller couldn't be created
            selectedSource = .appleMusic
            setActiveController(fallbackController)
        }
    }

    private func setActiveController(_ controller: any MediaControllerProtocol) {
        // Cancel any existing flip animation
        flipWorkItem?.cancel()

        // Set new active controller
        activeController = controller

        self.canFavoriteTrack = controller.supportsFavorite
        self.canDislikeTrack = controller.supportsDislike
        self.isFavoriteStateKnown = controller.currentFavoriteState != nil
        self.isFavoriteTrack = false

        // Get current state from active controller
        forceUpdate()
    }

    // MARK: - Update Methods
    @MainActor
    private func updateFromPlaybackState(_ state: PlaybackState) {
        // Commit metadata before triggering presentation effects.
        let playbackChanged = state.isPlaying != self.isPlaying
        if playbackChanged {
            NSLog("Playback state changed: \(state.isPlaying ? "Playing" : "Paused")")
            withAnimation(.smooth) {
                self.isPlaying = state.isPlaying
                self.updateIdleState(state: state.isPlaying)
            }

        }

        let hasContentChange = MediaContentChange.hasChanged(from: presentationSnapshot, to: state)
        presentationSnapshot = state
        if hasContentChange {
            triggerFlipAnimation()
            artworkPresentation.apply(data: state.artwork, bundleIdentifier: state.bundleIdentifier, identity: state.identity,
                                      artworkItemIdentifier: state.artworkItemIdentifier)
        }

        let timeChanged = state.currentTime != self.elapsedTime
        let durationChanged = state.duration != self.songDuration
        let playbackRateChanged = state.playbackRate != self.playbackRate
        let shuffleChanged = state.isShuffled != self.isShuffled
        let repeatModeChanged = state.repeatMode != self.repeatMode
        let volumeChanged = state.volume != self.volume

        if state.title != self.songTitle {
            self.songTitle = state.title
        }

        if state.artist != self.artistName {
            self.artistName = state.artist
        }

        if state.album != self.album {
            self.album = state.album
        }

        if timeChanged {
            self.elapsedTime = state.currentTime
        }

        if durationChanged {
            self.songDuration = state.duration
        }

        if playbackRateChanged {
            self.playbackRate = state.playbackRate
        }

        if shuffleChanged {
            self.isShuffled = state.isShuffled
        }

        let capabilities = activeController?.capabilities ?? MediaCapabilities()
        if self.mediaCapabilities != capabilities {
            self.mediaCapabilities = capabilities
            self.canFavoriteTrack = capabilities.favorite
            self.canDislikeTrack = capabilities.dislike
            self.volumeControlSupported = capabilities.volume
        }

        if state.bundleIdentifier != self.bundleIdentifier {
            self.bundleIdentifier = state.bundleIdentifier
            // Update volume control support from active controller
            self.volumeControlSupported = activeController?.supportsVolumeControl ?? false
        }

        if repeatModeChanged {
            self.repeatMode = state.repeatMode
        }
        // Action availability and an observed like state are independent: Electron can
        // expose a working toggle without exposing whether that toggle is selected.
        let favoriteStateKnown = activeController?.currentFavoriteState != nil
        if self.isFavoriteStateKnown != favoriteStateKnown {
            self.isFavoriteStateKnown = favoriteStateKnown
        }
        let favorite = favoriteStateKnown && state.isFavorite
        if favorite != self.isFavoriteTrack {
            self.isFavoriteTrack = favorite
        }

        if volumeChanged {
            self.volume = state.volume
        }

        self.timestampDate = state.lastUpdated
        self.nativeTrackID = state.nativeTrackID

        // (Re)fetch lyrics for the current (title, artist, duration). Running this every update is
        // cheap — the per-key dedup returns immediately when nothing relevant changed — and it
        // guarantees a re-fetch once the duration becomes known, so /get can match the exact
        // recording instead of a wrong-length /search result getting locked into the cache.
        self.fetchLyricsIfAvailable(bundleIdentifier: state.bundleIdentifier, title: state.title, artist: state.artist, album: state.album, duration: state.duration)
        if state.isPlaying && !state.title.isEmpty && !state.artist.isEmpty && (hasContentChange || playbackChanged) {
            updateSneakPeek()
        }
    }

    func toggleFavoriteTrack() {
        guard canFavoriteTrack else { return }
        performCommand { controller in
            await controller.toggleFavorite()
            guard !Task.isCancelled else { return }
            await controller.updatePlaybackInfo()
        }
    }

    func setFavorite(_ favorite: Bool) {
        guard canFavoriteTrack else { return }
        performCommand { controller in
            await controller.setFavorite(favorite)
            guard !Task.isCancelled else { return }
            await controller.updatePlaybackInfo()
        }
    }
    func dislikeCurrentTrack() {
        guard canDislikeTrack else { return }
        performCommand { await $0.dislike() }
    }

    // MARK: - Native media-key recovery
    private func cancelMediaKeyRecovery() {
        mediaKeyRecoveryCoordinator?.stop(); mediaKeyRecoveryCoordinator = nil
    }
    func recoverUnresponsiveSystemPlayPause() {
        guard Defaults[.mediaController] == .yandexMusic, let controller = activeController as? YandexMusicController else {
            cancelMediaKeyRecovery(); return
        }
        if mediaKeyRecoveryCoordinator == nil {
            mediaKeyRecoveryCoordinator = MediaKeyRecoveryCoordinator(snapshot: { [weak controller] in
                .init(systemOwner: controller?.systemMediaOwnerBundleIdentifier,
                      systemIsPlaying: controller?.systemMediaIsPlaying,
                      foreignActivity: controller?.lastForeignMediaActivity,
                      yandexIsPlaying: controller?.accessibilityIsPlaying,
                      accessibilityObservedAt: controller?.accessibilityMetadataLastReadAt,
                      foregroundApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, capturedAt: Date())
            }, refresh: { [weak controller] in await controller?.refreshAccessibilityMetadata() },
               toggle: { [weak controller] in await controller?.togglePlayWithReceipt() ?? false },
               isActive: { [weak self, weak controller] in
                guard let self, let controller else { return false }
                return self.activeController === controller && Defaults[.mediaController] == .yandexMusic
            })
        }
        mediaKeyRecoveryCoordinator?.handlePlayPause()
    }

    // MARK: - Lyrics facade
    private func configureLyricsService() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let owned = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "theboringteam.boringnotch", isDirectory: true)
            .appendingPathComponent("Media/Lyrics-v1.json")
        let legacy = caches.appendingPathComponent("boringNotch-lyrics-cache-v4.json")
        lyricsService = LyricsService(cache: LyricsCache(fileURL: owned, legacyURLs: [legacy]), nativeLyrics: {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else { return nil }
            return try await AppleScriptHelper.execute("""
            tell application "Music"
                if it is running then
                    try
                        set resultText to lyrics of current track
                        if resultText is not missing value then return resultText
                    end try
                end if
                return ""
            end tell
            """)?.stringValue
        })
        lyricsService.$document.sink { [weak self] document in
            self?.currentLyrics = document.plain
            self?.syncedLyrics = document.synced.map { (time: $0.time, text: $0.text) }
        }.store(in: &cancellables)
        lyricsService.$isFetching.sink { [weak self] value in self?.isFetchingLyrics = value }.store(in: &cancellables)
    }
    private func cancelLyricsFetch() { lyricsService?.stop(clear: true) }
    func reloadLyricsForCurrentTrack() {
        fetchLyricsIfAvailable(bundleIdentifier: bundleIdentifier, title: songTitle, artist: artistName,
                               album: album, duration: songDuration, force: true)
    }
    private func fetchLyricsIfAvailable(bundleIdentifier: String?, title: String, artist: String,
                                        album: String = "", duration: Double = 0, force: Bool = false) {
        let token = Defaults[.mediaController] == .yandexMusic ? YandexMusicTokenStore.shared.token : ""
        let request = LyricsRequest(source: Defaults[.mediaController].rawValue, bundleIdentifier: bundleIdentifier,
                                    title: title, artist: artist, album: album, duration: duration,
                                    nativeTrackID: nativeTrackID, yandexToken: token)
        lyricsService?.request(request, enabled: Defaults[.enableLyrics], force: force)
    }
    func lyricLine(at elapsed: Double) -> String {
        guard !syncedLyrics.isEmpty else { return currentLyrics }
        var low = 0, high = syncedLyrics.count
        while low < high {
            let middle = (low + high) / 2
            if syncedLyrics[middle].time <= elapsed { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? "" : syncedLyrics[low - 1].text
    }

    private func triggerFlipAnimation() {
        // Cancel any existing animation
        flipWorkItem?.cancel()

        // Create a new animation
        let workItem = DispatchWorkItem { [weak self] in
            self?.isFlipping = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self?.isFlipping = false
            }
        }

        flipWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func configureArtworkPresentation() {
        artworkPresentation = ArtworkPresentationService(defaultImage: defaultImage,
            colorEnabled: { Defaults[.coloredSpectrogram] })
        artworkPresentation.$image.sink { [weak self] image in
            withAnimation(.smooth) { self?.albumArt = image }
        }.store(in: &cancellables)
        artworkPresentation.$usesApplicationIcon.sink { [weak self] value in self?.usingAppIconForArtwork = value }.store(in: &cancellables)
        artworkPresentation.$color.sink { [weak self] color in
            withAnimation(.smooth) { self?.avgColor = color }
        }.store(in: &cancellables)
    }

    private func updateIdleState(state: Bool) {
        if state {
            isPlayerIdle = false
            debounceIdleTask?.cancel()
        } else {
            debounceIdleTask?.cancel()
            debounceIdleTask = Task { [weak self] in
                guard let self = self else { return }
                do { try await Task.sleep(for: .seconds(Defaults[.waitInterval])) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation {
                    self.isPlayerIdle = !self.isPlaying
                }
            }
        }
    }

    func updateAlbumArt(newAlbumArt: NSImage) {
        if let artworkPresentation { artworkPresentation.setImage(newAlbumArt) }
        else { albumArt = newAlbumArt }
    }

    // MARK: - Playback Position Estimation
    public func estimatedPlaybackPosition(at date: Date = Date()) -> TimeInterval {
        MediaTimeline(position: elapsedTime, duration: songDuration, observedAt: timestampDate,
                      rate: playbackRate, isPlaying: isPlaying).position(at: date)
    }

    func calculateAverageColor() { artworkPresentation?.calculateAverageColor() }

    private func updateSneakPeek() {
        if isPlaying && Defaults[.enableSneakPeek] {
            if Defaults[.sneakPeekStyles] == .standard {
                coordinator.toggleSneakPeek(status: true, type: .music)
            } else {
                coordinator.toggleExpandingView(status: true, type: .music)
            }
        }
    }

    // MARK: - Commands target the selected source at the instant of the user gesture.
    private func performCommand(_ operation: @escaping @MainActor (any MediaControllerProtocol) async -> Void) {
        guard let controller = activeController else { return }
        let id = UUID()
        commandTasks[id] = Task { @MainActor [weak self, weak controller] in
            guard !Task.isCancelled, let self, let controller, self.activeController === controller else { return }
            await operation(controller)
            self.commandTasks[id] = nil
        }
    }
    func playPause() { togglePlay() }
    func play() { performCommand { await $0.play() } }
    func pause() { performCommand { await $0.pause() } }
    func toggleShuffle() { performCommand { await $0.toggleShuffle() } }
    func toggleRepeat() { performCommand { await $0.toggleRepeat() } }
    func togglePlay() { performCommand { await $0.togglePlay() } }
    func nextTrack() { performCommand { await $0.nextTrack() } }
    func previousTrack() { performCommand { await $0.previousTrack() } }
    func seek(to position: TimeInterval) {
        guard position.isFinite else { return }
        performCommand { await $0.seek(to: max(0, position)) }
    }
    func skip(seconds: TimeInterval) {
        let target = max(0, estimatedPlaybackPosition() + seconds)
        seek(to: songDuration > 0 ? min(target, songDuration) : target)
    }
    func setVolume(to level: Double) {
        guard level.isFinite else { return }
        performCommand { await $0.setVolume(min(1, max(0, level))) }
    }
    func openMusicApp() {
        guard let bundleID = bundleIdentifier else {
            print("Error: appBundleIdentifier is nil")
            return
        }

        let workspace = NSWorkspace.shared
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            workspace.openApplication(at: appURL, configuration: configuration) { (app, error) in
                if let error = error {
                    print("Failed to launch app with bundle ID: \(bundleID), error: \(error)")
                } else {
                    print("Launched app with bundle ID: \(bundleID)")
                }
            }
        } else {
            print("Failed to find app with bundle ID: \(bundleID)")
        }
    }

    func forceUpdate() {
        performCommand { controller in
            guard controller.isActive() else { return }
            if let youtube = controller as? YouTubeMusicController { await youtube.pollPlaybackState() }
            else { await controller.updatePlaybackInfo() }
        }
    }
    func syncVolumeFromActiveApp() async {
        guard let controller = activeController, controller.isActive() else { return }
        await controller.updatePlaybackInfo()
    }
}
