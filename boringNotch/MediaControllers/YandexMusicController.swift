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
    var supportsFavorite: Bool { true }

    // Yandex has a real "I don't like it" control that trains My Wave (pressed via Accessibility).
    var supportsDislike: Bool { true }

    var capabilities: MediaCapabilities {
        .init(volume: false, favorite: true, dislike: true,
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
        playbackState = stopped
    }

    deinit {
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        adapter.stop()
        accessibilityTask?.cancel()
        accessibilityArtworkTask?.cancel()
    }
    func stop() {
        sourceLifetime.invalidate(); favoriteLifetime.invalidate(); transportLifetime.invalidate()
        stopped = true
        sessionIsYandex = false
        wire.reset()
        adapter.stop()
        accessibilityTask?.cancel(); accessibilityTask = nil
        accessibilityArtworkTask?.cancel(); accessibilityArtworkTask = nil
        accessibilityGeneration &+= 1; accessibilityArtworkGeneration &+= 1
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
                if let (reader, pid, generation) = self?.accessibilityRequest() {
                    let metadata = await reader.read(processIdentifier: pid)
                    guard !Task.isCancelled else { return }
                    if let metadata { self?.applyAccessibilityMetadata(metadata, generation: generation) }
                    else { self?.clearAccessibilityObservations(generation: generation) }
                }
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
            }
        }
    }

    @MainActor
    private func accessibilityRequest() -> ((any YandexAccessibilityProviding), pid_t, UInt)? {
        guard !stopped, !sessionIsYandex, AXIsProcessTrusted(), let pid = currentProcessIdentifier() else { return nil }
        return (accessibilityReader, pid, accessibilityGeneration)
    }

    /// A fresh, read-only AX sample for callers that need evidence about the actual Yandex player.
    @MainActor
    func refreshAccessibilityMetadata() async {
        guard let (reader, pid, generation) = accessibilityRequest() else {
            accessibilityIsPlaying = nil
            accessibilityMetadataLastReadAt = nil
            return
        }
        let metadata = await reader.read(processIdentifier: pid)
        guard !Task.isCancelled else { return }
        if let metadata { applyAccessibilityMetadata(metadata, generation: generation) }
        else { clearAccessibilityObservations(generation: generation) }
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
        let trackChanged = metadata.title != playbackState.title || metadata.artist != playbackState.artist
            || (metadata.trackID != nil && accessibilityTrackID != nil && metadata.trackID != accessibilityTrackID)
        accessibilityTrackID = metadata.trackID
        var state = playbackState
        state.nativeTrackID = metadata.trackID
        state.title = metadata.title
        state.artist = metadata.artist
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
        if state.identity != playbackState.identity { favoriteLifetime.invalidate() }
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
        // Metadata arrives continuously through the adapter stream. On an explicit refresh
        // (e.g. when this controller becomes active) re-read the like state via Accessibility.
        await refreshFavoriteState()
        guard !stopped, !Task.isCancelled else { return }
        await refreshAccessibilityMetadata()
    }

    // MARK: - Favorite (best-effort via Accessibility)
    // Honors the requested target state: a blind press would mis-toggle when the track is
    // already in the requested state (the protocol contract is "set", not "toggle").
    @MainActor
    func setFavorite(_ favorite: Bool) async {
        let ticket = sourceLifetime.ticket(), item = playbackState.identity
        let favoriteTicket = favoriteLifetime.ticket()
        guard isCurrentCommand(ticket) else { return }
        let current = await readLikeState()
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return }
        if current == favorite { playbackState.isFavorite = favorite; return }
        _ = await performPlayerAction(.like, sourceTicket: ticket, favoriteTicket: favoriteTicket)
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return }
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return }
        await refreshFavoriteState()
    }
    @MainActor
    private func refreshFavoriteState() async {
        let ticket = sourceLifetime.ticket(), item = playbackState.identity
        guard isCurrentCommand(ticket), let liked = await readLikeState(),
              isCurrentCommand(ticket), playbackState.identity == item else { return }
        if liked != playbackState.isFavorite { playbackState.isFavorite = liked }
    }
    @MainActor
    func dislike() async {
        let ticket = sourceLifetime.ticket(), item = playbackState.identity
        let favoriteTicket = favoriteLifetime.ticket()
        guard isCurrentCommand(ticket) else { return }
        _ = await performPlayerAction(.dislike, sourceTicket: ticket, favoriteTicket: favoriteTicket)
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return }
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return }
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
    private func readLikeState() async -> Bool? {
        let ticket = sourceLifetime.ticket(), item = playbackState.identity
        let favoriteTicket = favoriteLifetime.ticket()
        guard isCurrentCommand(ticket), let pid = currentProcessIdentifier() else { return nil }
        let value = await accessibilityReader.favoriteState(processIdentifier: pid)
        guard isCurrentCommand(ticket), favoriteLifetime.isCurrent(favoriteTicket), playbackState.identity == item else { return nil }
        return value
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

        // The like state is only re-read from the (expensive) accessibility tree when the track
        // actually changes; position-only diffs carry the previous value forward. On a track
        // change we read it up front and fold it into this single publish (no stale-then-correct
        // double emission). album is included so same-title/artist-different-album counts.
        let trackChanged = newState.identity != playbackState.identity
        if trackChanged { favoriteLifetime.invalidate() }
        if trackChanged || newState.isPlaying != playbackState.isPlaying { transportLifetime.invalidate() }
        // Carry the like state forward here. Reading it inline would do a synchronous Accessibility
        // tree walk on the main actor on every track change (a visible UI stall); the bounded poll
        // below reconciles it from the (lazily-built) control off the hot path instead.
        newState.isFavorite = trackChanged ? false : playbackState.isFavorite

        self.playbackState = newState

        if trackChanged {
            // Chromium rebuilds the like control lazily; poll briefly until we get a stable read
            // for THIS track (bail if the track changes again mid-poll).
            let identity = newState.identity
            Task { @MainActor [weak self] in
                for _ in 0..<6 {
                    do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                    guard let self, !self.stopped, self.playbackState.identity == identity else { return }
                    if let liked = await self.readLikeState(), self.playbackState.identity == identity {
                        if liked != self.playbackState.isFavorite { self.playbackState.isFavorite = liked }
                        return
                    }
                }
            }
        }
    }
}
