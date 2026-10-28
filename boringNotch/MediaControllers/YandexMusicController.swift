//
//  YandexMusicController.swift
//  boringNotch
//
//  Integration with the official Yandex Music desktop app (ru.yandex.desktop.music).
//
//  The Yandex Music app is Electron-based and ships no AppleScript dictionary, so the
//  AppleScript approach used by Spotify/Apple Music is not available. It does, however,
//  publish full Now Playing metadata (title, artist, album, artwork, elapsed time,
//  playback rate) to the system MediaRemote session via Chromium's MediaSession bridge.
//
//  This controller therefore reuses the MediaRemote adapter stream (like
//  NowPlayingController) but filters it down to the Yandex Music bundle id. Transport,
//  like and dislike controls use Accessibility to press Yandex's own player buttons,
//  so commands target Yandex even when another app owns the system media session.
//

import BoringCore
import AppKit
import ApplicationServices
import Combine
import Foundation

private typealias YandexMetadataValue = MediaWireValue
private typealias YandexNowPlayingUpdate = MediaWireUpdate

final class YandexMusicController: ObservableObject, MediaControllerProtocol {
    // MARK: - Constants
    nonisolated static let bundleID = "ru.yandex.desktop.music"

    // MARK: - Published state
    // Seed with empty metadata (not PlaybackState's decorative "I'm Handsome" defaults) so the
    // notch shows nothing until a real Yandex snapshot arrives — otherwise the placeholder would
    // linger whenever Yandex is running but isn't the current Now Playing session owner.
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: YandexMusicController.bundleID,
        title: "",
        artist: "",
        album: ""
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    // MediaRemote cannot set the volume of an Electron app, and there is no AppleScript
    // bridge, so volume control is unsupported.
    var supportsVolumeControl: Bool { false }

    // Best-effort via Accessibility (see setFavorite / refreshFavoriteState).
    var supportsFavorite: Bool { !stopped }
    var currentFavoriteState: Bool? { favoriteStateKnown ? playbackState.isFavorite : nil }

    // Yandex has a real "I don't like it" control that trains My Wave (pressed via Accessibility).
    var supportsDislike: Bool { true }

    var capabilities: MediaCapabilities {
        .init(volume: false, favorite: supportsFavorite, dislike: true,
              seek: sessionIsYandex && commands.canSeek,
              shuffle: sessionIsYandex && commands.canShuffle, repeatMode: sessionIsYandex && commands.canRepeat)
    }

    // MARK: - MediaRemote function pointers
    private let commands = MediaRemoteCommandClient()

    // MARK: - Adapter stream
    private let adapter = MediaAdapterSession<MediaWireUpdate>()
    private var wire = MediaWireState()
    private var adapterPayload: [String: MediaWireValue] { wire.payload }
    private var process: Process? { adapter.currentProcess }
    private var streamTask: Task<Void, Never>? { adapter.currentTask }
    private var stopped = false
    private let accessibilityReader: any YandexAccessibilityProviding
    private let currentProcessIdentifier: @MainActor () -> pid_t?
    private let unavailableTransport: (@MainActor () -> Void)?
    private let sourceLifetime = YandexCommandLifetime()
    private let favoriteLifetime = YandexCommandLifetime()
    private let transportLifetime = YandexCommandLifetime()
    private var favoriteStateKnown = false
    private var favoriteReadRevision: UInt = 0
    private var favoriteActionInFlight: UUID?
    private var favoriteQueueTail: Task<Void, Never>?
    private var favoriteQueueTailID: UUID?
    private enum FavoriteCommand { case toggle, set(Bool), dislike }
    private struct FavoriteCommandRequest {
        let source: UUID
        let lifetime: UUID
        let item: MediaItemIdentity
    }
    private struct FavoriteReadRequest {
        let source: UUID
        let lifetime: UUID
        let item: MediaItemIdentity
        let revision: UInt
    }
    private var accessibilityTask: Task<Void, Never>?
    private var accessibilityArtworkTask: Task<Void, Never>?
    private var accessibilityGeneration: UInt = 0
    private var accessibilityArtworkGeneration: UInt = 0
    private var accessibilityArtworkKey = ""
    private var accessibilityArtworkRetryAfter = Date.distantPast
    private var accessibilityTrackID: String?
    @MainActor private(set) var systemMediaOwnerBundleIdentifier: String?
    @MainActor private(set) var systemMediaIsPlaying: Bool?
    @MainActor private(set) var systemMediaLastUpdated: Date?
    @MainActor private(set) var systemMediaTimestamp: Date?
    @MainActor private(set) var lastForeignMediaActivity: Date?
    @MainActor private(set) var accessibilityIsPlaying: Bool?
    @MainActor private(set) var accessibilityMetadataLastReadAt: Date?

    // Whether the merged system Now Playing snapshot belongs to Yandex Music. Parent and
    // helper bundle identifiers can change independently in diffs, alongside metadata fields.
    private var sessionIsYandex = false

    // Cached AX element for Yandex's persistent bottom now-playing bar (the container holding
    // the real transport + like controls). Finding it means walking the Chromium a11y tree from
    // the app root; caching turns the per-command/per-track cost into a cheap validation plus a
    // tiny subtree search. Only touched on the main actor.


    // Observes Yandex Music quitting so the notch can stop showing it as playing.
    private var terminationObserver: NSObjectProtocol?

    // MARK: - Initialization
    init?(accessibility: any YandexAccessibilityProviding = YandexAccessibilityClient(),
          processIdentifier: @escaping @MainActor () -> pid_t? = {
              NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "ru.yandex.desktop.music" })?.processIdentifier
          }, onTransportUnavailable: (@MainActor () -> Void)? = nil, startMonitoring: Bool = true) {
        self.accessibilityReader = accessibility
        self.currentProcessIdentifier = processIdentifier
        self.unavailableTransport = onTransportUnavailable
        guard startMonitoring else { return }
        Task { @MainActor [weak self] in
            self?.startAccessibilityMonitoring()
            self?.setupNowPlayingObserver()
        }

        // When Yandex Music quits, the adapter stops reporting for it but the last state would
        // otherwise linger as "playing"; flip it to stopped so the notch goes idle.
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier == Self.bundleID else { return }
            Task { @MainActor [weak self] in self?.handleYandexTerminated() }
        }
    }

    @MainActor
    private func handleYandexTerminated() {
        guard !stopped else { return }
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        invalidateFavoriteQueue()
        favoriteActionInFlight = nil
        sessionIsYandex = false
        wire.reset()
        accessibilityGeneration &+= 1
        accessibilityArtworkGeneration &+= 1
        accessibilityArtworkTask?.cancel()
        accessibilityArtworkKey = ""
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
        var stopped = playbackState
        stopped.isPlaying = false
        stopped.playbackRate = 0
        favoriteStateKnown = false
        favoriteReadRevision &+= 1
        stopped.isFavorite = false
        playbackState = stopped
    }

    deinit {
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        adapter.stop()
        accessibilityTask?.cancel()
        accessibilityArtworkTask?.cancel()
        favoriteQueueTail?.cancel()
    }
    func stop() {
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        invalidateFavoriteQueue()
        favoriteActionInFlight = nil
        stopped = true
        sessionIsYandex = false
        wire.reset()
        adapter.stop()
        accessibilityTask?.cancel(); accessibilityTask = nil
        accessibilityArtworkTask?.cancel(); accessibilityArtworkTask = nil
        accessibilityGeneration &+= 1; accessibilityArtworkGeneration &+= 1
        clearFavoriteObservation()
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    // MARK: - Metadata when another app owns the system media session
    @MainActor
    private func startAccessibilityMonitoring() {
        guard !stopped else { return }
        accessibilityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Capture only the reader/request across AX IPC; releasing the controller while
                // a read is in flight must still stop monitoring and cancel image downloads.
                if let (reader, pid, generation, favorite) = self?.accessibilityRequest() {
                    let metadata = await reader.read(processIdentifier: pid)
                    guard !Task.isCancelled else { return }
                    var scopedFavorite: Bool?
                    if self?.needsScopedFavorite(metadata, request: favorite) == true {
                        scopedFavorite = await reader.favoriteState(processIdentifier: pid,
                            expectedTrack: Self.favoriteTarget(favorite.item))
                        guard !Task.isCancelled else { return }
                    }
                    self?.receiveAccessibilitySnapshot(metadata, scopedFavorite: scopedFavorite,
                                                       generation: generation, favorite: favorite)
                }
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
            }
        }
    }

    @MainActor
    private func accessibilityRequest() -> ((any YandexAccessibilityProviding), pid_t, UInt, FavoriteReadRequest)? {
        // A user command owns its pre-read, press and verification. A passive refresh must not
        // supersede that read revision and silently turn a valid click into an unknown state.
        guard !stopped, !Task.isCancelled, favoriteActionInFlight == nil else { return nil }
        guard let pid = currentProcessIdentifier() else {
            clearFavoriteObservation()
            return nil
        }
        // The worker performs the no-prompt AX trust check. Reading the same bounded player-bar
        // snapshot also reconciles likes when Yandex owns MediaRemote, without replacing its metadata.
        return (accessibilityReader, pid, accessibilityGeneration, beginFavoriteRead())
    }

    /// A fresh, read-only AX sample for callers that need evidence about the actual Yandex player.
    @MainActor
    func refreshAccessibilityMetadata() async {
        guard let (reader, pid, generation, favorite) = accessibilityRequest() else {
            accessibilityIsPlaying = nil
            accessibilityMetadataLastReadAt = nil
            return
        }
        let metadata = await reader.read(processIdentifier: pid)
        guard !Task.isCancelled else { return }
        var scopedFavorite: Bool?
        if needsScopedFavorite(metadata, request: favorite) {
            scopedFavorite = await reader.favoriteState(processIdentifier: pid, expectedTrack: Self.favoriteTarget(favorite.item))
            guard !Task.isCancelled else { return }
        }
        receiveAccessibilitySnapshot(metadata, scopedFavorite: scopedFavorite, generation: generation, favorite: favorite)
    }

    private func receiveAccessibilitySnapshot(_ metadata: YandexAccessibilityMetadata?, scopedFavorite: Bool?, generation: UInt,
                                              favorite: FavoriteReadRequest) {
        guard !stopped, !Task.isCancelled, generation == accessibilityGeneration,
              isCurrentFavoriteRead(favorite) else { return }
        if let metadata {
            if !sessionIsYandex { applyAccessibilityMetadata(metadata, generation: generation) }
        } else { clearAccessibilityObservations(generation: generation) }
        guard isCurrentFavoriteRead(favorite) else { return }
        let metadataFavorite = metadata.flatMap { metadataMatchesCurrentTrack($0) ? $0.isFavorite : nil }
        publishFavoriteObservation(metadataFavorite ?? scopedFavorite)
    }

    @MainActor
    private func clearAccessibilityObservations(generation: UInt) {
        guard !stopped, generation == accessibilityGeneration else { return }
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
    }

    @MainActor
    private func applyAccessibilityMetadata(_ metadata: YandexAccessibilityMetadata, generation: UInt) {
        guard !stopped, !Task.isCancelled, !sessionIsYandex, generation == accessibilityGeneration else { return }
        accessibilityMetadataLastReadAt = Date()
        accessibilityIsPlaying = metadata.isPlaying
        let trackIDChanged: Bool
        if let currentID = playbackState.nativeTrackID ?? accessibilityTrackID, let observedID = metadata.trackID {
            trackIDChanged = currentID != observedID
        } else { trackIDChanged = false }
        // A renderer can expose the current title but omit its artist links. Missing data for
        // the same title must not erase the identity that a scoped favorite read just verified.
        let artist = metadata.artist.isEmpty && metadata.title == playbackState.title && !trackIDChanged
            ? playbackState.artist : metadata.artist
        let trackChanged = metadata.title != playbackState.title || artist != playbackState.artist || trackIDChanged
        accessibilityTrackID = metadata.trackID
        var state = playbackState
        state.nativeTrackID = metadata.trackID
        state.title = metadata.title
        state.artist = artist
        state.album = metadata.album.isEmpty && !trackChanged ? state.album : metadata.album
        if let playing = metadata.isPlaying {
            if state.isPlaying {
                state.currentTime += max(0, Date().timeIntervalSince(state.lastUpdated)) * state.playbackRate
            }
            state.isPlaying = playing
            state.playbackRate = playing ? 1 : 0
            state.lastUpdated = Date()
        }
        if trackChanged {
            accessibilityArtworkGeneration &+= 1
            accessibilityArtworkTask?.cancel()
            accessibilityArtworkKey = ""
            state.artwork = nil
            state.currentTime = 0
            state.duration = 0
            state.isFavorite = false
            state.lastUpdated = Date()
        }
        if state.identity != playbackState.identity {
            favoriteLifetime.invalidate()
            invalidateFavoriteQueue()
            favoriteActionInFlight = nil
            favoriteReadRevision &+= 1
            favoriteStateKnown = false
            state.isFavorite = false
        }
        if state.identity != playbackState.identity || state.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        playbackState = state

        let artworkKey = [metadata.title, metadata.artist, metadata.trackID ?? "", metadata.artworkURL?.absoluteString ?? ""].joined(separator: "|")
        guard metadata.artworkURL != nil || metadata.trackID != nil,
              artworkKey != accessibilityArtworkKey || Date() >= accessibilityArtworkRetryAfter else { return }
        accessibilityArtworkKey = artworkKey
        accessibilityArtworkRetryAfter = .distantFuture
        accessibilityArtworkTask?.cancel()
        let artworkGeneration = accessibilityArtworkGeneration
        let token = YandexMusicTokenStore.shared.token
        accessibilityArtworkTask = Task { [weak self] in
            let data = await Self.fetchAccessibilityArtwork(metadata, token: token)
            guard !Task.isCancelled else { return }
            self?.applyAccessibilityArtwork(data, key: artworkKey, generation: artworkGeneration)
        }
    }

    @MainActor
    private func applyAccessibilityArtwork(_ data: Data?, key: String, generation: UInt) {
        guard !stopped, !Task.isCancelled, !sessionIsYandex, accessibilityArtworkKey == key, accessibilityArtworkGeneration == generation else { return }
        if let data { playbackState.artwork = data }
        else { accessibilityArtworkRetryAfter = Date().addingTimeInterval(10) }
    }

    private static func fetchAccessibilityArtwork(_ metadata: YandexAccessibilityMetadata, token: String,
                                                  session: URLSession = .shared) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let client = session === URLSession.shared ? YandexMediaAPIClient.shared : YandexMediaAPIClient(session: session)
        return await client.artwork(for: metadata, token: token)
    }

    // MARK: - Transport controls
    //
    // Transport commands are sent to Yandex Music ONLY, by pressing its own on-screen controls
    // through Accessibility. There is deliberately no MediaRemote fallback: a global MediaRemote
    // command targets whatever app owns the system Now Playing session, which can be a Safari
    // video, so falling back would hijack the wrong app. When the press can't be delivered we
    // instead make sure Yandex is the target — launching it if it isn't running (see
    // handleTransportMiss).
    //
    // These methods are @MainActor because they read/write `playbackState`/`sessionIsYandex`,
    // which are also mutated by the adapter stream callback; running them all on the main actor
    // serializes every access to that shared state and removes the data race.
    @MainActor
    func play() async {
        guard !playbackState.isPlaying else { return }
        await performTransport(.playPause, optimisticState: true)
    }
    @MainActor
    func pause() async {
        guard playbackState.isPlaying else { return }
        await performTransport(.playPause, optimisticState: false)
    }
    @MainActor
    func togglePlay() async { await performTransport(.playPause, optimisticState: !playbackState.isPlaying) }
    func togglePlayWithReceipt() async -> Bool {
        let requestedState = !playbackState.isPlaying
        // Recovery of a native key has already proved a running, authorized player. Losing
        // that evidence while AX waits must never turn F8 into a launch/permission prompt.
        return await performTransport(.playPause, optimisticState: requestedState, allowUnavailableFallback: false)
    }
    @discardableResult
    private func performTransport(_ action: YandexPlayerAction, optimisticState: Bool? = nil,
                                  allowUnavailableFallback: Bool = true) async -> Bool {
        let ticket = sourceLifetime.ticket(), transportTicket = transportLifetime.ticket()
        guard isCurrentCommand(ticket) else { return false }
        let performed = await performPlayerAction(action, sourceTicket: ticket, transportTicket: transportTicket)
        guard isCurrentCommand(ticket), transportLifetime.isCurrent(transportTicket) else {
            // A native update emitted by our accepted action may arrive before AX returns.
            // Preserve its receipt but never invert that newer playback observation.
            return performed && isCurrentCommand(ticket)
        }
        if performed {
            if let optimisticState { applyOptimisticPlayState(optimisticState) }
        } else if allowUnavailableFallback { handleTransportMiss(ticket: ticket, transportTicket: transportTicket) }
        return performed
    }
    private func isCurrentCommand(_ ticket: UUID) -> Bool {
        !stopped && !Task.isCancelled && sourceLifetime.isCurrent(ticket)
    }

    /// After an AX transport press, reflect the new play/pause state locally right away. When
    /// another app (e.g. a browser tab) owns the system Now Playing session, MediaRemote won't
    /// report Yandex's change, so without this the notch would keep advancing lyrics/progress
    /// for a track that is actually paused (or vice-versa). Re-anchors the position at `now`.
    @MainActor
    private func applyOptimisticPlayState(_ playing: Bool) {
        var s = playbackState
        let now = Date()
        if s.isPlaying {
            let advance = now.timeIntervalSince(s.lastUpdated) * s.playbackRate
            s.currentTime = min(max(0, s.currentTime + advance), s.duration > 0 ? s.duration : .greatestFiniteMagnitude)
        }
        s.isPlaying = playing
        if playing && s.playbackRate <= 0 { s.playbackRate = 1 }
        s.lastUpdated = now
        if s.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        playbackState = s
    }

    @MainActor
    func nextTrack() async { await performTransport(.next) }
    @MainActor
    func previousTrack() async { await performTransport(.previous) }

    /// Called when an AX transport press couldn't be delivered. Rather than hijacking another
    /// app via a global MediaRemote command, ensure Yandex Music itself is the target: launch it
    /// when it isn't running, or nudge the user to grant Accessibility when it is (which is what
    /// the on-screen controls need).
    @MainActor
    private func handleTransportMiss(ticket: UUID, transportTicket: UUID) {
        guard isCurrentCommand(ticket), transportLifetime.isCurrent(transportTicket) else { return }
        if let unavailableTransport { unavailableTransport(); return }
        if !isActive() {
            launchYandexMusic()
        } else if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    /// Opens the Yandex Music app (used when a transport command arrives while it isn't running).
    @MainActor
    private func launchYandexMusic() {
        guard !stopped, !Task.isCancelled else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            NSLog("[YandexMusic] Yandex Music app not found to launch.")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("[YandexMusic] Failed to launch Yandex Music: \(error)") }
        }
    }

    @MainActor
    func seek(to time: Double) async {
        // MediaRemote seeks the session owner; only do so while Yandex owns the session, to
        // avoid scrubbing whatever else (e.g. a browser tab) currently holds it.
        guard sessionIsYandex else { return }
        commands.seek(time)
    }

    @MainActor
    func toggleShuffle() async {
        guard sessionIsYandex else { return }
        // Shuffle mode: 1 = off, 3 = on (mirrors NowPlayingController).
        commands.shuffle(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }

    @MainActor
    func toggleRepeat() async {
        guard sessionIsYandex else { return }
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        commands.repeatMode(newRepeatMode)
    }

    @MainActor
    func setVolume(_ level: Double) async {
        // Not supported for the Electron app; keep the local value in sync for the UI.
        playbackState.volume = max(0.0, min(1.0, level))
    }

    func isActive() -> Bool { !stopped && currentProcessIdentifier() != nil }

    @MainActor
    func updatePlaybackInfo() async {
        guard !stopped, !Task.isCancelled else { return }
        // A single bar snapshot keeps metadata and its like control associated with one track.
        await refreshAccessibilityMetadata()
    }

    // MARK: - Favorite (best-effort via Accessibility)
    /// A user click requests one press of the current player's toggle. Its pressed state may
    /// be unreadable; that must not disable the action or turn the click into an assumed "set".
    func toggleFavorite() async {
        guard let queued = enqueueFavoriteCommand(.toggle) else { return }
        await Self.waitForFavoriteCommand(queued)
    }

    // Honors the requested target state: a blind press would mis-toggle when the track is
    // already in the requested state (the protocol contract is "set", not "toggle").
    @MainActor
    func setFavorite(_ favorite: Bool) async {
        guard let queued = enqueueFavoriteCommand(.set(favorite)) else { return }
        await Self.waitForFavoriteCommand(queued)
    }
    @MainActor
    private func refreshFavoriteState() async {
        _ = await readLikeState()
    }
    @MainActor
    func dislike() async {
        guard let queued = enqueueFavoriteCommand(.dislike) else { return }
        await Self.waitForFavoriteCommand(queued)
    }

    private func enqueueFavoriteCommand(_ command: FavoriteCommand) -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        let request = FavoriteCommandRequest(source: sourceLifetime.ticket(), lifetime: favoriteLifetime.ticket(),
                                             item: playbackState.identity)
        let previous = favoriteQueueTail, id = UUID()
        let queued = Task { @MainActor [weak self] in
            defer { self?.finishFavoriteQueueEntry(id) }
            // Waiting commands retain only the preceding task and value request, never their source.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.executeFavoriteCommand(command, request: request)
        }
        favoriteQueueTail = queued
        favoriteQueueTailID = id
        return queued
    }

    private static func waitForFavoriteCommand(_ queued: Task<Void, Never>) async {
        await withTaskCancellationHandler { await queued.value } onCancel: { queued.cancel() }
    }

    private func finishFavoriteQueueEntry(_ id: UUID) {
        if favoriteQueueTailID == id {
            favoriteQueueTail = nil
            favoriteQueueTailID = nil
        }
    }

    private func invalidateFavoriteQueue() {
        favoriteQueueTail?.cancel()
        favoriteQueueTail = nil
        favoriteQueueTailID = nil
    }

    private func isCurrentFavoriteCommand(_ request: FavoriteCommandRequest) -> Bool {
        isCurrentCommand(request.source) && favoriteLifetime.isCurrent(request.lifetime)
            && playbackState.identity == request.item
    }

    private func executeFavoriteCommand(_ command: FavoriteCommand, request: FavoriteCommandRequest) async {
        guard isCurrentFavoriteCommand(request) else { return }
        let action = beginFavoriteAction()
        defer { finishFavoriteAction(action) }
        let performed: Bool
        switch command {
        case .toggle:
            performed = await performFavoriteAction(item: request.item, sourceTicket: request.source, favoriteTicket: request.lifetime)
        case .set(let favorite):
            let current = await readLikeState()
            guard isCurrentFavoriteCommand(request), let current else { return }
            if current == favorite { return }
            performed = await performFavoriteAction(item: request.item, desiredState: favorite,
                                                     sourceTicket: request.source, favoriteTicket: request.lifetime)
        case .dislike:
            performed = await performPlayerAction(.dislike, sourceTicket: request.source, favoriteTicket: request.lifetime)
        }
        guard isCurrentFavoriteCommand(request) else { return }
        guard performed else { return }
        clearFavoriteObservation()
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        guard isCurrentFavoriteCommand(request) else { return }
        await refreshFavoriteState()
    }

    // MARK: - Adapter stream setup
    @MainActor
    private func setupNowPlayingObserver() {
        guard !stopped else { return }
        adapter.start(arguments: ["--debounce=100"], onUpdate: { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }, onRestart: { [weak self] in await self?.resetAdapterState() })
    }
    private func resetAdapterState() {
        transportLifetime.invalidate()
        favoriteLifetime.invalidate()
        invalidateFavoriteQueue()
        favoriteActionInFlight = nil
        clearFavoriteObservation()
        wire.reset(); sessionIsYandex = false
        systemMediaOwnerBundleIdentifier = nil; systemMediaIsPlaying = nil
        systemMediaLastUpdated = nil; systemMediaTimestamp = nil
        accessibilityGeneration &+= 1
        accessibilityIsPlaying = nil; accessibilityMetadataLastReadAt = nil
    }
    private func performPlayerAction(_ action: YandexPlayerAction, sourceTicket: UUID, favoriteTicket: UUID? = nil,
                                     transportTicket: UUID? = nil) async -> Bool {
        guard isCurrentCommand(sourceTicket), let pid = currentProcessIdentifier() else { return false }
        let scope = sourceLifetime, favoriteScope = favoriteLifetime, transportScope = transportLifetime
        let performed = await accessibilityReader.perform(action, processIdentifier: pid, isCurrent: {
            !Task.isCancelled && scope.isCurrent(sourceTicket)
                && (favoriteTicket.map { favoriteScope.isCurrent($0) } ?? true)
                && (transportTicket.map { transportScope.isCurrent($0) } ?? true)
        })
        guard isCurrentCommand(sourceTicket), favoriteTicket.map({ favoriteScope.isCurrent($0) }) ?? true else { return false }
        return performed
    }
    private static func favoriteTarget(_ item: MediaItemIdentity) -> YandexFavoriteTarget {
        .init(trackID: item.nativeID, title: item.title, artist: item.artist)
    }

    private func performFavoriteAction(item: MediaItemIdentity, desiredState: Bool? = nil,
                                       sourceTicket: UUID, favoriteTicket: UUID) async -> Bool {
        guard isCurrentCommand(sourceTicket), playbackState.identity == item, let pid = currentProcessIdentifier() else { return false }
        let scope = sourceLifetime, favoriteScope = favoriteLifetime
        let target = Self.favoriteTarget(item)
        let isCurrent: @Sendable () -> Bool = {
            !Task.isCancelled && scope.isCurrent(sourceTicket) && favoriteScope.isCurrent(favoriteTicket)
        }
        let performed: Bool
        if let desiredState {
            performed = await accessibilityReader.setFavorite(desiredState, processIdentifier: pid, expectedTrack: target, isCurrent: isCurrent)
        } else {
            performed = await accessibilityReader.toggleFavorite(processIdentifier: pid, expectedTrack: target, isCurrent: isCurrent)
        }
        guard isCurrentCommand(sourceTicket), favoriteScope.isCurrent(favoriteTicket), playbackState.identity == item else { return false }
        return performed
    }
    private func readLikeState() async -> Bool? {
        guard !stopped, !Task.isCancelled else { return nil }
        guard let pid = currentProcessIdentifier() else { clearFavoriteObservation(); return nil }
        let request = beginFavoriteRead()
        let liked = await accessibilityReader.favoriteState(processIdentifier: pid, expectedTrack: Self.favoriteTarget(request.item))
        guard isCurrentFavoriteRead(request) else { return nil }
        publishFavoriteObservation(liked)
        return liked
    }

    private func beginFavoriteRead() -> FavoriteReadRequest {
        favoriteReadRevision &+= 1
        return .init(source: sourceLifetime.ticket(), lifetime: favoriteLifetime.ticket(),
                     item: playbackState.identity, revision: favoriteReadRevision)
    }

    private func beginFavoriteAction() -> UUID {
        favoriteReadRevision &+= 1
        let action = UUID()
        favoriteActionInFlight = action
        return action
    }

    private func finishFavoriteAction(_ action: UUID) {
        // A newer explicit command may already own the slot when an older awaited read returns.
        if favoriteActionInFlight == action { favoriteActionInFlight = nil }
    }

    private func isCurrentFavoriteRead(_ request: FavoriteReadRequest) -> Bool {
        isCurrentCommand(request.source) && favoriteLifetime.isCurrent(request.lifetime)
            && request.revision == favoriteReadRevision && request.item == playbackState.identity
    }

    private func metadataMatchesCurrentTrack(_ metadata: YandexAccessibilityMetadata) -> Bool {
        let state = playbackState
        // Both IDs come from trusted Yandex track links, rather than opaque MediaRemote IDs.
        // A partial/localized artist label must not defeat an exact recording match.
        if let currentID = state.nativeTrackID, let observedID = metadata.trackID { return currentID == observedID }
        let title = MediaText.normalized(state.title), artist = MediaText.normalized(state.artist)
        guard !title.isEmpty, !artist.isEmpty, MediaText.normalized(metadata.title) == title,
              MediaText.normalized(metadata.artist) == artist else { return false }
        if !state.album.isEmpty, !metadata.album.isEmpty, state.album != metadata.album { return false }
        return true
    }

    private func needsScopedFavorite(_ metadata: YandexAccessibilityMetadata?, request: FavoriteReadRequest) -> Bool {
        guard isCurrentFavoriteRead(request) else { return false }
        guard let metadata else { return true }
        return metadata.isFavorite == nil || !metadataMatchesCurrentTrack(metadata)
    }

    private func publishFavoriteObservation(_ liked: Bool?) {
        let known = liked != nil
        guard favoriteStateKnown != known || playbackState.isFavorite != (liked ?? false) else { return }
        favoriteStateKnown = known
        var state = playbackState
        state.isFavorite = liked ?? false
        // Publish even when only known/unknown changes so the facade refreshes its status label.
        playbackState = state
    }

    private func clearFavoriteObservation() {
        favoriteReadRevision &+= 1
        publishFavoriteObservation(nil)
    }

    // MARK: - Update handling
    private static func adapterDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    // @MainActor so playbackState/sessionIsYandex are only ever touched on the main actor
    // (the transport methods and refreshFavoriteState are too). The existing
    // `await self?.handleAdapterUpdate(update)` call hops the stream callback onto main.
    @MainActor
    private func handleAdapterUpdate(_ update: YandexNowPlayingUpdate) async {
        guard !stopped, !Task.isCancelled else { return }
        let diff = update.diff ?? false
        let previousPayload = adapterPayload

        // Merge the complete adapter state before resolving the owner. A diff can change only
        // the helper bundle id while its parent is still Yandex, or remove the old parent only
        // after the new bundle id and metadata have arrived. Looking at that diff in isolation
        // would lose the session and ignore every later title/artwork update without an owner.
        wire.apply(update)
        let payload = adapterPayload
        let parent = payload.string("parentApplicationBundleIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        let previousOwner = systemMediaOwnerBundleIdentifier
        let previousSystemPlaying = systemMediaIsPlaying
        let previousForeignActivity = lastForeignMediaActivity
        let wasYandex = sessionIsYandex
        systemMediaOwnerBundleIdentifier = parent ?? payload.string("bundleIdentifier")
        systemMediaIsPlaying = payload.boolean("playing")
        systemMediaLastUpdated = Date()
        if let timestamp = payload.string("timestamp") {
            systemMediaTimestamp = Self.adapterDate(timestamp)
        } else { systemMediaTimestamp = nil }
        if systemMediaOwnerBundleIdentifier != nil, systemMediaOwnerBundleIdentifier != Self.bundleID {
            let changed = ["title", "artist", "album", "duration", "elapsedTime", "playing",
                           "contentItemIdentifier", "uniqueIdentifier"].contains { previousPayload[$0] != payload[$0] }
            // A newly observed paused session still needs a conservative quiet-time baseline.
            // Timestamp-only refreshes must not keep moving that baseline forward forever.
            if previousOwner != systemMediaOwnerBundleIdentifier
                || (changed && (diff || systemMediaIsPlaying == true || previousOwner != nil)) {
                lastForeignMediaActivity = Date()
            }
        }
        if previousOwner != systemMediaOwnerBundleIdentifier || previousSystemPlaying != systemMediaIsPlaying
            || previousForeignActivity != lastForeignMediaActivity { transportLifetime.invalidate() }
        sessionIsYandex = (parent ?? payload.string("bundleIdentifier")) == Self.bundleID
        if sessionIsYandex != wasYandex {
            // This only changes which metadata stream is authoritative. Directed AX favorite
            // commands still target the same Yandex track and retain their own lifetime ticket.
            accessibilityGeneration &+= 1
            accessibilityIsPlaying = nil
            accessibilityMetadataLastReadAt = nil
            accessibilityArtworkGeneration &+= 1
            accessibilityArtworkTask?.cancel()
            accessibilityArtworkKey = ""
        }

        // Ignore anything that is not (part of) the Yandex Music session, so the notch keeps
        // showing the last known Yandex state instead of hijacking to a different player.
        guard sessionIsYandex else { return }

        var newState = wire.playbackState(applying: update, previous: playbackState, now: Date())
        newState.bundleIdentifier = Self.bundleID

        let trackChanged = newState.identity != playbackState.identity
        if trackChanged {
            favoriteLifetime.invalidate()
            invalidateFavoriteQueue()
            favoriteActionInFlight = nil
            favoriteReadRevision &+= 1
            favoriteStateKnown = false
        }
        if trackChanged || newState.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        // Chromium does not reliably publish likes through MediaRemote. The supervised AX poll
        // reconciles the current bar continuously, including same-track edits made in Yandex.
        newState.isFavorite = trackChanged ? false : playbackState.isFavorite

        self.playbackState = newState
    }
}
