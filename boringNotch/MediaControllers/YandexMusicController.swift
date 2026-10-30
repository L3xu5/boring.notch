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
    private let seekDispatcher: (@MainActor (Double) async -> Void)?
    private let sourceLifetime = YandexCommandLifetime()
    private let favoriteLifetime = YandexCommandLifetime()
    private let transportLifetime = YandexCommandLifetime()
    private let systemSessionLifetime = YandexCommandLifetime()
    private var favoriteStateKnown = false
    private struct FavoriteEvidence {
        let id = UUID()
        let source: UUID
        let lifetime: UUID
        let item: MediaItemIdentity
        let processIdentifier: pid_t
        let observedAt: TimeInterval
    }
    private var favoriteEvidence: FavoriteEvidence?
    private var favoriteEvidenceExpiryTask: Task<Void, Never>?
    private var favoriteReadRevision: UInt = 0
    private var favoriteActionInFlight: UUID?
    private var favoriteQueueTail: Task<Void, Never>?
    private var favoriteQueueTailID: UUID?
    private var navigationQueueTail: Task<Void, Never>?
    private var navigationQueueTailID: UUID?
    private struct NavigationRequest: Sendable {
        let source: UUID
        let processIdentifier: pid_t
    }
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
        let processIdentifier: pid_t
    }
    private var accessibilityTask: Task<Void, Never>?
    private var playbackTask: Task<Void, Never>?
    private var playbackReadRevision: UInt = 0
    private var playbackGeneration: UInt = 0
    private var observedProcessIdentifier: pid_t?
    private var confirmedPlaying: Bool?
    private var confirmedPlayingPID: pid_t?
    private struct PlaybackReadRequest {
        let source: UUID
        let processIdentifier: pid_t
        let generation: UInt
        let revision: UInt
    }
    private var accessibilityArtworkTask: Task<Void, Never>?
    private var accessibilityGeneration: UInt = 0
    private var accessibilityArtworkGeneration: UInt = 0
    private var accessibilityArtworkKey = ""
    private var accessibilityArtworkRetryAfter = Date.distantPast
    private var accessibilityTrackID: String?
    private let metadataClock: @MainActor () -> TimeInterval
    private struct MetadataRecord {
        let title: String
        let artist: String
        let album: String
        let wireItemID: String?
        init(_ state: PlaybackState, wireItemID: String? = nil) {
            title = MediaText.normalized(state.title)
            artist = MediaText.normalized(state.artist)
            album = MediaText.normalized(state.album)
            self.wireItemID = wireItemID.flatMap { $0.isEmpty ? nil : $0 }
        }
        func matches(_ other: MetadataRecord) -> Bool {
            guard !title.isEmpty, title == other.title, artist == other.artist,
                  album.isEmpty || other.album.isEmpty || album == other.album else { return false }
            if let wireItemID, let otherID = other.wireItemID { return wireItemID == otherID }
            return true
        }
    }
    private struct AXMetadataBarrier {
        let previousMR: MetadataRecord
        let currentAX: MetadataRecord
        let observedAt: TimeInterval
        let source: UUID
    }
    private var lastPublishedMRMetadata: MetadataRecord?
    private var axMetadataBarrier: AXMetadataBarrier?
    private var suppressedAXMetadata: MetadataRecord?
    private var foreignMetadataRecord: MetadataRecord?
    private var awaitingYandexTitle = false
    private var publishedMRItemID: String?
    private var previousOpaqueTrackID: String?
    private var stagedArtworkAssociation = false
    private let snapshotReader: (@Sendable () async -> MediaWireUpdate?)?
    private var artworkSnapshotTask: Task<Void, Never>?
    private var artworkSnapshotGeneration = UUID()
    private struct PreviousArtwork {
        let data: Data?
        let album: String
    }
    private var previousItemArtwork: PreviousArtwork?
    private struct ArtworkSnapshotRequest {
        let source: UUID
        let generation: UUID
        let item: MediaItemIdentity
        let wireItemID: String?
        let candidateWireItemID: String?
        let timeline: MediaTimeline
    }
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
              NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "ru.yandex.desktop.music" && !$0.isTerminated
              })?.processIdentifier
          }, onTransportUnavailable: (@MainActor () -> Void)? = nil, startMonitoring: Bool = true,
          metadataClock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
          snapshotReader: (@Sendable () async -> MediaWireUpdate?)? = nil,
          seekDispatcher: (@MainActor (Double) async -> Void)? = nil) {
        self.accessibilityReader = accessibility
        self.currentProcessIdentifier = processIdentifier
        self.unavailableTransport = onTransportUnavailable
        self.seekDispatcher = seekDispatcher
        self.metadataClock = metadataClock
        if let snapshotReader { self.snapshotReader = snapshotReader }
        else if startMonitoring { self.snapshotReader = { @Sendable in await MediaAdapterSnapshotReader().read() } }
        else { self.snapshotReader = nil }
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
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleID else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.handleYandexTerminated(processIdentifier: pid) }
        }
    }

    @MainActor
    private func handleYandexTerminated(processIdentifier terminatedPID: pid_t? = nil) {
        guard !stopped else { return }
        if let terminatedPID, let currentPID = currentProcessIdentifier(), currentPID != terminatedPID { return }
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        invalidateFavoriteQueue()
        invalidateNavigationQueue()
        favoriteActionInFlight = nil
        clearMetadataAuthority()
        sessionIsYandex = false
        wire.reset()
        accessibilityGeneration &+= 1
        accessibilityArtworkGeneration &+= 1
        accessibilityArtworkTask?.cancel()
        artworkSnapshotTask?.cancel()
        accessibilityArtworkKey = ""
        observedProcessIdentifier = nil
        invalidatePlaybackEvidence(stopPlayback: false)
        var stopped = playbackState
        let now = Date()
        stopped.currentTime = stopped.timeline.position(at: now)
        stopped.lastUpdated = now
        stopped.isPlaying = false
        stopped.playbackRate = 0
        invalidateFavoriteEvidence()
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
        playbackTask?.cancel()
        accessibilityArtworkTask?.cancel()
        artworkSnapshotTask?.cancel()
        favoriteQueueTail?.cancel()
        navigationQueueTail?.cancel()
        favoriteEvidenceExpiryTask?.cancel()
    }
    func stop() {
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        invalidateFavoriteQueue()
        invalidateNavigationQueue()
        favoriteActionInFlight = nil
        clearMetadataAuthority()
        stopped = true
        sessionIsYandex = false
        wire.reset()
        adapter.stop()
        accessibilityTask?.cancel(); accessibilityTask = nil
        playbackTask?.cancel(); playbackTask = nil
        accessibilityArtworkTask?.cancel(); accessibilityArtworkTask = nil
        accessibilityGeneration &+= 1; accessibilityArtworkGeneration &+= 1
        invalidatePlaybackEvidence(stopPlayback: true)
        clearFavoriteObservation()
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
    }

    // MARK: - Metadata when another app owns the system media session
    @MainActor
    private func startAccessibilityMonitoring() {
        guard !stopped else { return }
        startPlaybackMonitoring()
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

    private func startPlaybackMonitoring() {
        guard !stopped, playbackTask == nil else { return }
        playbackTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let (reader, request) = self?.playbackRequest() {
                    let playing = await reader.playbackState(processIdentifier: request.processIdentifier)
                    guard !Task.isCancelled else { return }
                    self?.receivePlaybackState(playing, request: request)
                }
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
            }
        }
    }

    private func observeProcessPresence() -> pid_t? {
        let pid = currentProcessIdentifier()
        if let observedProcessIdentifier, observedProcessIdentifier != pid { handleYandexTerminated() }
        observedProcessIdentifier = pid
        return pid
    }

    private func playbackRequest() -> ((any YandexAccessibilityProviding), PlaybackReadRequest)? {
        guard !stopped, !Task.isCancelled else { return nil }
        guard let pid = observeProcessPresence() else {
            invalidatePlaybackEvidence(stopPlayback: true)
            return nil
        }
        playbackReadRevision &+= 1
        return (accessibilityReader, .init(source: sourceLifetime.ticket(), processIdentifier: pid,
                                           generation: playbackGeneration, revision: playbackReadRevision))
    }

    private func refreshPlaybackState() async {
        guard let (reader, request) = playbackRequest() else { return }
        let playing = await reader.playbackState(processIdentifier: request.processIdentifier)
        receivePlaybackState(playing, request: request)
    }

    private func receivePlaybackState(_ playing: Bool?, request: PlaybackReadRequest) {
        guard isCurrentCommand(request.source), request.generation == playbackGeneration,
              request.revision == playbackReadRevision,
              currentProcessIdentifier() == request.processIdentifier else { return }
        accessibilityIsPlaying = playing
        accessibilityMetadataLastReadAt = playing == nil ? nil : Date()
        guard let playing else { return }
        confirmedPlaying = playing
        confirmedPlayingPID = request.processIdentifier
        publishPlaying(playing)
    }

    private func publishPlaying(_ playing: Bool) {
        let rate = playing ? (playbackState.playbackRate > 0 ? playbackState.playbackRate : 1) : 0
        guard playbackState.isPlaying != playing || playbackState.playbackRate != rate else { return }
        var state = playbackState
        let now = Date()
        state.currentTime = state.timeline.position(at: now)
        state.lastUpdated = now
        state.isPlaying = playing
        state.playbackRate = rate
        if playbackState.isPlaying != playing { transportLifetime.invalidate() }
        playbackState = state
    }

    private func invalidatePlaybackEvidence(stopPlayback: Bool) {
        playbackGeneration &+= 1
        playbackReadRevision &+= 1
        confirmedPlaying = nil
        confirmedPlayingPID = nil
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
        if stopPlayback { publishPlaying(false) }
    }

    @MainActor
    private func accessibilityRequest() -> ((any YandexAccessibilityProviding), pid_t, UInt, FavoriteReadRequest)? {
        // A user command owns its pre-read, press and verification. A passive refresh must not
        // supersede that read revision and silently turn a valid click into an unknown state.
        guard !stopped, !Task.isCancelled, favoriteActionInFlight == nil else { return nil }
        guard let pid = observeProcessPresence() else {
            clearFavoriteObservation()
            return nil
        }
        // The worker performs the no-prompt AX trust check. Reading the same bounded player-bar
        // snapshot also reconciles likes when Yandex owns MediaRemote, without replacing its metadata.
        return (accessibilityReader, pid, accessibilityGeneration, beginFavoriteRead(processIdentifier: pid))
    }

    /// A fresh, read-only AX sample for callers that need evidence about the actual Yandex player.
    @MainActor
    func refreshAccessibilityMetadata() async {
        await refreshPlaybackState()
        guard let (reader, pid, generation, favorite) = accessibilityRequest() else { return }
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
        if !stopped, currentProcessIdentifier() != favorite.processIdentifier {
            _ = observeProcessPresence()
            return
        }
        guard !stopped, !Task.isCancelled, generation == accessibilityGeneration,
              isCurrentFavoriteRead(favorite) else { return }
        if let metadata {
            if !sessionIsYandex { applyAccessibilityMetadata(metadata, generation: generation) }
            else { enrichMatchedAccessibilityIdentity(metadata) }
        }
        if !isCurrentFavoriteRead(favorite) {
            // Applying this exact AX snapshot may establish a new track or trusted ID.
            // Only its own matched Like belongs to that new item; the scoped read above
            // was requested for the old item and must never be transferred to it.
            if isCurrentCommand(favorite.source), generation == accessibilityGeneration,
               currentProcessIdentifier() == favorite.processIdentifier,
               let metadata, metadataMatchesCurrentTrack(metadata), let liked = metadata.isFavorite {
                reconcileFavoriteObservation(liked, processIdentifier: favorite.processIdentifier)
            }
            return
        }
        let metadataFavorite = metadata.flatMap { metadataMatchesCurrentTrack($0) ? $0.isFavorite : nil }
        reconcileFavoriteObservation(metadataFavorite ?? scopedFavorite, processIdentifier: favorite.processIdentifier)
    }

    /// The system session carries opaque queue IDs. A fresh matching player-bar sample
    /// supplies Yandex's actual recording ID, so lyrics never have to guess its edition.
    private func enrichMatchedAccessibilityIdentity(_ metadata: YandexAccessibilityMetadata) {
        guard sessionIsYandex, !hasPendingOpaqueRecording, playbackState.nativeTrackID == nil,
              let trackID = metadata.trackID, trackID != previousOpaqueTrackID,
              metadataMatchesCurrentTrack(metadata) else { return }
        accessibilityTrackID = trackID
        var state = playbackState
        state.nativeTrackID = trackID
        playbackReadRevision &+= 1
        favoriteLifetime.invalidate()
        invalidateFavoriteQueue()
        favoriteActionInFlight = nil
        favoriteReadRevision &+= 1
        invalidateFavoriteEvidence()
        favoriteStateKnown = false
        state.isFavorite = false
        playbackState = state
        // A pending read was tied to the less specific identity. Validate the current
        // cover again with the enriched identity rather than abandoning its recovery.
        if state.artwork == nil || stagedArtworkAssociation || artworkSnapshotTask != nil {
            requestArtworkSnapshot()
        }
    }

    private var hasPendingOpaqueRecording: Bool {
        guard stagedArtworkAssociation, let publishedMRItemID,
              let candidate = adapterPayload.string("contentItemIdentifier") else { return false }
        return candidate != publishedMRItemID
    }

    @MainActor
    private func applyAccessibilityMetadata(_ metadata: YandexAccessibilityMetadata, generation: UInt) {
        guard !stopped, !Task.isCancelled, !sessionIsYandex, generation == accessibilityGeneration else { return }
        let trackIDChanged: Bool
        if let currentID = playbackState.nativeTrackID ?? accessibilityTrackID, let observedID = metadata.trackID {
            trackIDChanged = currentID != observedID
        } else { trackIDChanged = false }
        // A renderer can expose the current title but omit its artist links. Missing data for
        // the same title must not erase the identity that a scoped favorite read just verified.
        let artist = metadata.artist.isEmpty && metadata.title == playbackState.title && !trackIDChanged
            ? playbackState.artist : metadata.artist
        let trackChanged = metadata.title != playbackState.title || artist != playbackState.artist || trackIDChanged
        let sameCompleteText = !MediaText.normalized(metadata.title).isEmpty
            && !MediaText.normalized(metadata.artist).isEmpty
            && MediaText.normalized(metadata.title) == MediaText.normalized(playbackState.title)
            && MediaText.normalized(metadata.artist) == MediaText.normalized(playbackState.artist)
            && (metadata.album.isEmpty || playbackState.album.isEmpty
                || MediaText.normalized(metadata.album) == MediaText.normalized(playbackState.album))
        let retainedID = !trackChanged && sameCompleteText ? playbackState.nativeTrackID ?? accessibilityTrackID : nil
        accessibilityTrackID = metadata.trackID ?? retainedID
        var state = playbackState
        state.nativeTrackID = metadata.trackID ?? retainedID
        state.title = metadata.title
        state.artist = artist
        state.album = metadata.album.isEmpty && !trackChanged ? state.album : metadata.album
        if trackChanged {
            previousOpaqueTrackID = nil
            cancelArtworkSnapshot()
            if playbackState.artwork != nil {
                previousItemArtwork = .init(data: playbackState.artwork, album: playbackState.album)
            }
            publishedMRItemID = nil
            state.artworkItemIdentifier = nil
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
            playbackReadRevision &+= 1
            favoriteLifetime.invalidate()
            invalidateFavoriteQueue()
            favoriteActionInFlight = nil
            favoriteReadRevision &+= 1
            invalidateFavoriteEvidence()
            favoriteStateKnown = false
            state.isFavorite = false
        }
        if transportRecordingChanged(from: playbackState, to: state) || state.isPlaying != playbackState.isPlaying {
            transportLifetime.invalidate()
        }
        recordAXMetadataAuthority(state)
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
        return await performTransport(.playPause, optimisticState: requestedState, allowUnavailableFallback: false,
                                      requiresStableSystemSession: true)
    }
    @discardableResult
    private func performTransport(_ action: YandexPlayerAction, optimisticState: Bool? = nil,
                                  allowUnavailableFallback: Bool = true, requiresStableSystemSession: Bool = false) async -> Bool {
        let ticket = sourceLifetime.ticket(), transportTicket = transportLifetime.ticket()
        let systemTicket = requiresStableSystemSession ? systemSessionLifetime.ticket() : nil
        let pid = currentProcessIdentifier()
        guard isCurrentCommand(ticket) else { return false }
        let performed = await performPlayerAction(action, sourceTicket: ticket, transportTicket: transportTicket,
                                                systemTicket: systemTicket, explicitTransport: allowUnavailableFallback,
                                                desiredPlaying: optimisticState)
        if currentProcessIdentifier() != pid {
            _ = observeProcessPresence()
            return false
        }
        guard isCurrentCommand(ticket), transportLifetime.isCurrent(transportTicket),
              systemTicket.map({ systemSessionLifetime.isCurrent($0) }) ?? true else {
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
        guard let pid = observeProcessPresence() else {
            invalidatePlaybackEvidence(stopPlayback: true)
            return
        }
        playbackReadRevision &+= 1
        confirmedPlaying = playing
        confirmedPlayingPID = pid
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
        var s = playbackState
        let now = Date()
        if s.isPlaying {
            let advance = now.timeIntervalSince(s.lastUpdated) * s.playbackRate
            s.currentTime = min(max(0, s.currentTime + advance), s.duration > 0 ? s.duration : .greatestFiniteMagnitude)
        }
        s.isPlaying = playing
        if playing && s.playbackRate <= 0 { s.playbackRate = 1 }
        if !playing { s.playbackRate = 0 }
        s.lastUpdated = now
        if s.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        playbackState = s
    }

    @MainActor
    func nextTrack() async {
        guard let queued = enqueueNavigation(.next) else { return }
        await Self.waitForNavigationCommand(queued)
    }
    @MainActor
    func previousTrack() async {
        guard let queued = enqueueNavigation(.previous) else { return }
        await Self.waitForNavigationCommand(queued)
    }

    private func enqueueNavigation(_ action: YandexPlayerAction) -> Task<Void, Never>? {
        guard !stopped, !Task.isCancelled else { return nil }
        guard let pid = observeProcessPresence() else {
            handleTransportMiss(ticket: sourceLifetime.ticket(), transportTicket: transportLifetime.ticket())
            return nil
        }
        let request = NavigationRequest(source: sourceLifetime.ticket(), processIdentifier: pid)
        let previous = navigationQueueTail, id = UUID()
        let reader = accessibilityReader, source = sourceLifetime
        let queued = Task { @MainActor [weak self] in
            defer { self?.finishNavigationQueueEntry(id) }
            await previous?.value
            guard !Task.isCancelled, self?.isCurrentNavigation(request) == true else { return }
            let metadataTicket = self?.transportLifetime.ticket()
            // Next/Previous target this player's current queue, including the item reached
            // by the preceding click. Record/playing updates cannot cancel that intent.
            let isCurrent: @Sendable () -> Bool = { !Task.isCancelled && source.isCurrent(request.source) }
            let performed = await reader.performExplicitTransport(action, desiredPlaying: nil,
                processIdentifier: request.processIdentifier, isCurrent: isCurrent)
            guard let self, self.isCurrentNavigation(request) else { return }
            if performed {
                // The accepted press may already have produced new MR/AX content while
                // its receipt was suspended. Release only the authority we started with.
                if let metadataTicket, self.transportLifetime.isCurrent(metadataTicket) {
                    self.clearMetadataAuthorityForNavigation()
                }
            } else {
                self.handleTransportMiss(ticket: request.source, transportTicket: self.transportLifetime.ticket())
            }
        }
        navigationQueueTail = queued
        navigationQueueTailID = id
        return queued
    }

    private static func waitForNavigationCommand(_ queued: Task<Void, Never>) async {
        await withTaskCancellationHandler { await queued.value } onCancel: { queued.cancel() }
    }

    private func isCurrentNavigation(_ request: NavigationRequest) -> Bool {
        guard isCurrentCommand(request.source) else { return false }
        guard currentProcessIdentifier() == request.processIdentifier else {
            _ = observeProcessPresence()
            return false
        }
        return true
    }

    private func finishNavigationQueueEntry(_ id: UUID) {
        if navigationQueueTailID == id {
            navigationQueueTail = nil
            navigationQueueTailID = nil
        }
    }

    private func invalidateNavigationQueue() {
        navigationQueueTail?.cancel()
        navigationQueueTail = nil
        navigationQueueTailID = nil
    }

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
        let source = sourceLifetime.ticket(), item = playbackState.identity, wireItem = publishedMRItemID
        guard time.isFinite, isCurrentCommand(source), sessionIsYandex, seekDispatcher != nil || commands.canSeek,
              let pid = currentProcessIdentifier() else { return }
        let position = playbackState.duration > 0 ? min(max(0, time), playbackState.duration) : max(0, time)
        if let seekDispatcher { await seekDispatcher(position) }
        else { commands.seek(position) }
        guard isCurrentCommand(source), sessionIsYandex, playbackState.identity == item, publishedMRItemID == wireItem,
              currentProcessIdentifier() == pid, !playbackState.isPlaying else { return }
        // MediaRemote gives no delivery receipt. Reflect this explicit paused seek locally;
        // an eventual native paused snapshot can still correct the requested position.
        playbackState.currentTime = position
        playbackState.lastUpdated = Date()
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
        let hadYandexSession = sessionIsYandex
        transportLifetime.invalidate()
        favoriteLifetime.invalidate()
        invalidateFavoriteQueue()
        favoriteActionInFlight = nil
        clearMetadataAuthority()
        clearFavoriteObservation()
        wire.reset(); sessionIsYandex = false
        systemMediaOwnerBundleIdentifier = nil; systemMediaIsPlaying = nil
        systemMediaLastUpdated = nil; systemMediaTimestamp = nil
        accessibilityGeneration &+= 1
        invalidatePlaybackEvidence(stopPlayback: true)
        if hadYandexSession { publishCapabilitiesChange() }
    }
    private func performPlayerAction(_ action: YandexPlayerAction, sourceTicket: UUID, favoriteTicket: UUID? = nil,
                                     transportTicket: UUID? = nil, systemTicket: UUID? = nil,
                                     explicitTransport: Bool = false, desiredPlaying: Bool? = nil) async -> Bool {
        guard isCurrentCommand(sourceTicket), let pid = currentProcessIdentifier() else { return false }
        let scope = sourceLifetime, favoriteScope = favoriteLifetime, transportScope = transportLifetime
        let systemScope = systemSessionLifetime
        let isCurrent: @Sendable () -> Bool = {
            !Task.isCancelled && scope.isCurrent(sourceTicket)
                && (favoriteTicket.map { favoriteScope.isCurrent($0) } ?? true)
                && (transportTicket.map { transportScope.isCurrent($0) } ?? true)
                && (systemTicket.map { systemScope.isCurrent($0) } ?? true)
        }
        let performed: Bool
        if explicitTransport {
            performed = await accessibilityReader.performExplicitTransport(action, desiredPlaying: desiredPlaying,
                processIdentifier: pid, isCurrent: isCurrent)
        } else { performed = await accessibilityReader.perform(action, processIdentifier: pid, isCurrent: isCurrent) }
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
        guard previousOpaqueTrackID == nil || playbackState.nativeTrackID != nil else {
            clearFavoriteObservation()
            return nil
        }
        guard let pid = observeProcessPresence() else { clearFavoriteObservation(); return nil }
        let request = beginFavoriteRead(processIdentifier: pid)
        let liked = await accessibilityReader.favoriteState(processIdentifier: pid, expectedTrack: Self.favoriteTarget(request.item))
        if !stopped, currentProcessIdentifier() != request.processIdentifier {
            _ = observeProcessPresence()
            return nil
        }
        guard isCurrentFavoriteRead(request) else { return nil }
        reconcileFavoriteObservation(liked, processIdentifier: pid)
        return liked
    }

    private func beginFavoriteRead(processIdentifier: pid_t) -> FavoriteReadRequest {
        favoriteReadRevision &+= 1
        return .init(source: sourceLifetime.ticket(), lifetime: favoriteLifetime.ticket(),
                     item: playbackState.identity, revision: favoriteReadRevision, processIdentifier: processIdentifier)
    }

    private func beginFavoriteAction() -> UUID {
        clearFavoriteObservation()
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
            && currentProcessIdentifier() == request.processIdentifier
    }

    private func metadataMatchesCurrentTrack(_ metadata: YandexAccessibilityMetadata) -> Bool {
        let state = playbackState
        if state.nativeTrackID == nil, let previousOpaqueTrackID,
           metadata.trackID == nil || metadata.trackID == previousOpaqueTrackID { return false }
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
        if playbackState.nativeTrackID == nil, previousOpaqueTrackID != nil { return false }
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
        invalidateFavoriteEvidence()
        publishFavoriteObservation(nil)
    }

    private func invalidateFavoriteEvidence() {
        favoriteEvidence = nil
        favoriteEvidenceExpiryTask?.cancel()
        favoriteEvidenceExpiryTask = nil
    }

    private func reconcileFavoriteObservation(_ liked: Bool?, processIdentifier: pid_t) {
        if let liked {
            invalidateFavoriteEvidence()
            favoriteEvidence = .init(source: sourceLifetime.ticket(), lifetime: favoriteLifetime.ticket(),
                item: playbackState.identity, processIdentifier: processIdentifier, observedAt: metadataClock())
            publishFavoriteObservation(liked)
            return
        }
        guard let evidence = favoriteEvidence, isCurrentFavoriteEvidence(evidence) else {
            invalidateFavoriteEvidence()
            publishFavoriteObservation(nil)
            return
        }
        scheduleFavoriteEvidenceExpiry(evidence)
    }

    private func isCurrentFavoriteEvidence(_ evidence: FavoriteEvidence) -> Bool {
        let age = metadataClock() - evidence.observedAt
        return !stopped && sourceLifetime.isCurrent(evidence.source) && favoriteLifetime.isCurrent(evidence.lifetime)
            && evidence.item == playbackState.identity && currentProcessIdentifier() == evidence.processIdentifier
            && age >= 0 && age < 3
    }

    private func scheduleFavoriteEvidenceExpiry(_ evidence: FavoriteEvidence) {
        guard favoriteEvidenceExpiryTask == nil else { return }
        let remaining = max(0, 3 - (metadataClock() - evidence.observedAt))
        favoriteEvidenceExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.expireFavoriteEvidence(evidence.id)
        }
    }

    private func expireFavoriteEvidence(_ id: UUID) {
        guard let evidence = favoriteEvidence, evidence.id == id else { return }
        favoriteEvidenceExpiryTask = nil
        if isCurrentFavoriteEvidence(evidence) { scheduleFavoriteEvidenceExpiry(evidence) }
        else { clearFavoriteObservation() }
    }

    private func recordAXMetadataAuthority(_ state: PlaybackState) {
        let current = MetadataRecord(state)
        if let suppressedAXMetadata {
            if current.matches(suppressedAXMetadata) { return }
            self.suppressedAXMetadata = nil
        }
        guard let previous = lastPublishedMRMetadata, !current.matches(previous) else {
            axMetadataBarrier = nil
            return
        }
        axMetadataBarrier = .init(previousMR: previous, currentAX: current,
                                  observedAt: metadataClock(), source: sourceLifetime.ticket())
    }

    private func shouldDeferMRMetadata(_ candidate: MetadataRecord) -> Bool {
        guard let barrier = axMetadataBarrier else { return false }
        let age = metadataClock() - barrier.observedAt
        guard sourceLifetime.isCurrent(barrier.source), age >= 0, age < 2,
              !candidate.matches(barrier.currentAX), candidate.matches(barrier.previousMR) else {
            axMetadataBarrier = nil
            return false
        }
        return true
    }

    private func clearMetadataAuthorityForNavigation() {
        axMetadataBarrier = nil
        cancelArtworkSnapshot()
        stagedArtworkAssociation = false
        suppressedAXMetadata = MetadataRecord(playbackState)
        // A pre-navigation AX reply must not reinstate the authority just released by the user.
        accessibilityGeneration &+= 1
    }

    private func clearMetadataAuthority() {
        lastPublishedMRMetadata = nil
        axMetadataBarrier = nil
        suppressedAXMetadata = nil
        foreignMetadataRecord = nil
        awaitingYandexTitle = false
        publishedMRItemID = nil
        previousOpaqueTrackID = nil
        stagedArtworkAssociation = false
        previousItemArtwork = nil
        cancelArtworkSnapshot()
    }

    private func cancelArtworkSnapshot() {
        artworkSnapshotGeneration = UUID()
        artworkSnapshotTask?.cancel()
        artworkSnapshotTask = nil
    }

    private func requestArtworkSnapshot(candidateWireItemID: String? = nil) {
        guard let snapshotReader else { return }
        cancelArtworkSnapshot()
        let request = ArtworkSnapshotRequest(source: sourceLifetime.ticket(), generation: artworkSnapshotGeneration,
                                              item: playbackState.identity, wireItemID: publishedMRItemID,
                                              candidateWireItemID: candidateWireItemID ?? publishedMRItemID,
                                              timeline: playbackState.timeline)
        artworkSnapshotTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard self?.isCurrentArtworkSnapshot(request) == true else { return }
            let snapshot = await snapshotReader()
            guard !Task.isCancelled else { return }
            self?.receiveArtworkSnapshot(snapshot, request: request)
        }
    }

    private func isCurrentArtworkSnapshot(_ request: ArtworkSnapshotRequest) -> Bool {
        !stopped && sessionIsYandex && !Task.isCancelled && sourceLifetime.isCurrent(request.source)
            && request.generation == artworkSnapshotGeneration && playbackState.identity == request.item
            && publishedMRItemID == request.wireItemID
    }

    private func isPreviousItemArtwork(_ data: Data, album: String) -> Bool {
        guard let previousItemArtwork, data == previousItemArtwork.data else { return false }
        let currentAlbum = MediaText.normalized(album), oldAlbum = MediaText.normalized(previousItemArtwork.album)
        return currentAlbum.isEmpty || oldAlbum.isEmpty || currentAlbum != oldAlbum
    }

    private func receiveArtworkSnapshot(_ snapshot: MediaWireUpdate?, request: ArtworkSnapshotRequest) {
        guard isCurrentArtworkSnapshot(request) else { return }
        artworkSnapshotTask = nil
        guard let snapshot, snapshot.diff != true else { return }
        var confirmed = MediaWireState()
        confirmed.apply(snapshot)
        let payload = confirmed.payload
        guard confirmed.owner == Self.bundleID,
              !request.item.title.isEmpty,
              MediaText.normalized(payload.string("title") ?? "") == MediaText.normalized(request.item.title),
              MediaText.normalized(payload.string("artist") ?? "") == MediaText.normalized(request.item.artist),
              request.item.album.isEmpty || MediaText.normalized(payload.string("album") ?? "") == MediaText.normalized(request.item.album),
              request.candidateWireItemID == nil || payload.string("contentItemIdentifier") == request.candidateWireItemID,
              let encoded = payload.string("artworkData"), let data = Data(base64Encoded: encoded),
              !isPreviousItemArtwork(data, album: payload.string("album") ?? playbackState.album) else { return }
        var state = playbackState
        var reconciled: [String: MediaWireValue] = [:]
        if state.album.isEmpty, let album = payload.string("album"), !album.isEmpty {
            state.album = album
            reconciled["album"] = .string(album)
        }
        if let duration = payload.number("duration"), duration > 0,
           state.duration == request.timeline.duration {
            state.duration = duration
            reconciled["duration"] = .number(duration)
        }
        if payload.number("elapsedTime") != nil, state.timeline.position == request.timeline.position,
           state.lastUpdated == request.timeline.observedAt {
            // This is a full, freshly read snapshot of the verified recording. Its time
            // belongs with its cover; a later heartbeat or explicit seek keeps precedence.
            let sampled = confirmed.playbackState(applying: snapshot, previous: state, now: Date())
            state.currentTime = sampled.currentTime
            state.lastUpdated = sampled.lastUpdated
            reconciled["elapsedTime"] = payload["elapsedTime"]
            if let timestamp = payload["timestamp"] { reconciled["timestamp"] = timestamp }
        }
        wire.apply(.init(payload: reconciled))
        if let candidate = request.candidateWireItemID, let current = publishedMRItemID, candidate != current {
            previousOpaqueTrackID = playbackState.nativeTrackID ?? previousOpaqueTrackID
            publishedMRItemID = candidate
            state.artworkItemIdentifier = candidate
            state.nativeTrackID = nil
            accessibilityTrackID = nil
            playbackReadRevision &+= 1
            favoriteLifetime.invalidate()
            invalidateFavoriteQueue()
            favoriteActionInFlight = nil
            favoriteReadRevision &+= 1
            invalidateFavoriteEvidence()
            favoriteStateKnown = false
            state.isFavorite = false
            transportLifetime.invalidate()
            lastPublishedMRMetadata = MetadataRecord(state, wireItemID: candidate)
        }
        state.artwork = data
        playbackState = state
        stagedArtworkAssociation = false
    }

    private func retainMetadata(reconciling transport: PlaybackState) {
        var held = playbackState
        if held.isPlaying != transport.isPlaying || held.playbackRate != transport.playbackRate {
            if held.isPlaying != transport.isPlaying { transportLifetime.invalidate() }
            let now = Date()
            held.currentTime = held.timeline.position(at: now)
            held.lastUpdated = now
            held.isPlaying = transport.isPlaying
            held.playbackRate = transport.playbackRate
        }
        playbackState = held
    }

    private func publishCapabilitiesChange() {
        // The facade refreshes capabilities from this publisher. Ownership can disable
        // global seek/shuffle/repeat while every Yandex content field stays unchanged.
        let held = playbackState
        playbackState = held
    }

    private func transportRecordingChanged(from old: PlaybackState, to new: PlaybackState) -> Bool {
        if MediaText.normalized(old.title) != MediaText.normalized(new.title)
            || MediaText.normalized(old.artist) != MediaText.normalized(new.artist) { return true }
        if !old.album.isEmpty, !new.album.isEmpty,
           MediaText.normalized(old.album) != MediaText.normalized(new.album) { return true }
        if let oldID = old.nativeTrackID, let newID = new.nativeTrackID, oldID != newID { return true }
        return false
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
        let processIdentifier = observeProcessPresence()
        if processIdentifier == nil { invalidatePlaybackEvidence(stopPlayback: true) }
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
            || previousForeignActivity != lastForeignMediaActivity { systemSessionLifetime.invalidate() }
        sessionIsYandex = (parent ?? payload.string("bundleIdentifier")) == Self.bundleID
        if sessionIsYandex != wasYandex {
            // This only changes which metadata stream is authoritative. Directed AX favorite
            // commands still target the same Yandex track and retain their own lifetime ticket.
            accessibilityGeneration &+= 1
            accessibilityArtworkGeneration &+= 1
            accessibilityArtworkTask?.cancel()
            accessibilityArtworkKey = ""
            cancelArtworkSnapshot()
        }

        // Ignore anything that is not (part of) the Yandex Music session, so the notch keeps
        // showing the last known Yandex state instead of hijacking to a different player.
        guard sessionIsYandex else {
            awaitingYandexTitle = false
            // A stale parent may arrive after Yandex's own title. Cache only content
            // whose helper also unambiguously belongs to the foreign application.
            if payload.string("bundleIdentifier") != Self.bundleID {
                let foreign = wire.playbackState(applying: update, previous: playbackState, now: Date())
                foreignMetadataRecord = MetadataRecord(foreign, wireItemID: payload.string("contentItemIdentifier"))
            }
            if wasYandex { publishCapabilitiesChange() }
            return
        }

        // A changed Yandex playing value is new source evidence. Repeated cached playing
        // values and metadata/timeline heartbeats must not undo a newer scoped pause sample.
        if wasYandex, let playing = systemMediaIsPlaying, playing != previousSystemPlaying {
            playbackReadRevision &+= 1
            confirmedPlaying = nil
            confirmedPlayingPID = nil
            accessibilityIsPlaying = nil
            accessibilityMetadataLastReadAt = nil
        }

        var newState = wire.playbackState(applying: update, previous: playbackState, now: Date())
        newState.bundleIdentifier = Self.bundleID
        if processIdentifier == nil {
            let now = Date()
            newState.currentTime = playbackState.timeline.position(at: now)
            newState.lastUpdated = now
            newState.isPlaying = false
            newState.playbackRate = 0
        } else if confirmedPlayingPID == processIdentifier, let playing = confirmedPlaying {
            newState.isPlaying = playing
            newState.playbackRate = playing ? (newState.playbackRate > 0 ? newState.playbackRate : 1) : 0
        }

        let metadataRecord = MetadataRecord(newState, wireItemID: payload.string("contentItemIdentifier"))
        if !wasYandex, update.payload["title"] == nil,
           let foreignMetadataRecord, metadataRecord.matches(foreignMetadataRecord) {
            awaitingYandexTitle = true
        }
        if update.payload["title"] != nil { awaitingYandexTitle = false }
        if awaitingYandexTitle || shouldDeferMRMetadata(metadataRecord) {
            // A fresh AX record can precede the system owner's delayed old-item redump.
            // Keep its content while still reconciling independent transport observations.
            retainMetadata(reconciling: newState)
            return
        }

        let freshMetadata = ["title", "artist", "album"].contains { update.payload[$0] != nil }
        let sameText = MetadataRecord(newState).matches(MetadataRecord(playbackState))
        let freshArtwork = update.payload["artworkData"] != nil
        let stageArtwork = !freshMetadata && sameText && freshArtwork && newState.artwork != nil
            && newState.artwork != playbackState.artwork && diff
        if stageArtwork {
            // Artwork diffs have no item tag. Keep the displayed cover until a fresh full
            // snapshot proves that the bytes still belong to the displayed recording.
            stagedArtworkAssociation = true
            newState.artwork = playbackState.artwork
        } else if freshMetadata { stagedArtworkAssociation = false }
        let nextItemID = payload.string("contentItemIdentifier")
        newState.artworkItemIdentifier = stagedArtworkAssociation ? publishedMRItemID : nextItemID
        let opaqueItemChanged = !stagedArtworkAssociation && publishedMRItemID != nil
            && nextItemID != nil && publishedMRItemID != nextItemID
        if opaqueItemChanged {
            // AX can lag the new opaque recording while its base title stays identical.
            // Do not attach that retired native ID (and its lyrics) to the new recording.
            previousOpaqueTrackID = sameText ? playbackState.nativeTrackID ?? previousOpaqueTrackID : nil
            newState.nativeTrackID = nil
            accessibilityTrackID = nil
            if !freshArtwork { newState.artwork = nil }
        }
        let trackChanged = newState.identity != playbackState.identity || opaqueItemChanged
        let recordingChanged = opaqueItemChanged || transportRecordingChanged(from: playbackState, to: newState)
        if recordingChanged && !sameText { previousOpaqueTrackID = nil }
        if hasPendingOpaqueRecording {
            newState.currentTime = playbackState.currentTime
            newState.lastUpdated = playbackState.lastUpdated
            newState.duration = playbackState.duration
        } else if recordingChanged {
            // A partial new-item patch cannot carry the old song's clock into its lyrics.
            // Remove unobserved fields from the merged wire state too, so a heartbeat
            // cannot resurrect the previous duration after this publication.
            var stale: [String: MediaWireValue] = [:]
            if update.payload["duration"] == nil {
                newState.duration = 0
                stale["duration"] = .null
            }
            if update.payload.number("elapsedTime") == nil {
                newState.currentTime = 0
                newState.lastUpdated = Date()
                stale["elapsedTime"] = .null
            }
            if update.payload.string("timestamp").flatMap(Self.adapterDate) == nil {
                newState.lastUpdated = Date()
                stale["timestamp"] = .null
            }
            wire.apply(.init(payload: stale))
        }
        if confirmedPlayingPID == processIdentifier, confirmedPlaying == false, systemMediaIsPlaying == true,
           MetadataRecord(newState, wireItemID: stagedArtworkAssociation ? publishedMRItemID : nextItemID)
            .matches(MetadataRecord(playbackState, wireItemID: publishedMRItemID)) {
            // Chromium can keep advancing elapsedTime after AX/power confirms a pause. Its
            // cached playing session cannot replace this recording's frozen position anchor.
            newState.currentTime = playbackState.currentTime
            newState.lastUpdated = playbackState.lastUpdated
        }
        if trackChanged {
            cancelArtworkSnapshot()
            if let oldArtwork = playbackState.artwork {
                previousItemArtwork = .init(data: oldArtwork, album: playbackState.album)
            }
            if !freshArtwork { newState.artwork = nil }
            playbackReadRevision &+= 1
            favoriteLifetime.invalidate()
            invalidateFavoriteQueue()
            favoriteActionInFlight = nil
            favoriteReadRevision &+= 1
            invalidateFavoriteEvidence()
            favoriteStateKnown = false
        }
        if opaqueItemChanged || transportRecordingChanged(from: playbackState, to: newState)
            || newState.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        // Chromium does not reliably publish likes through MediaRemote. The supervised AX poll
        // reconciles the current bar continuously, including same-track edits made in Yandex.
        newState.isFavorite = trackChanged ? false : playbackState.isFavorite

        if !stagedArtworkAssociation { publishedMRItemID = nextItemID }
        lastPublishedMRMetadata = MetadataRecord(newState, wireItemID: publishedMRItemID)
        self.playbackState = newState
        if stageArtwork || (trackChanged && newState.artwork == nil) {
            requestArtworkSnapshot(candidateWireItemID: stageArtwork ? nextItemID : nil)
        } else if freshArtwork && !stageArtwork { cancelArtworkSnapshot() }
    }
}
