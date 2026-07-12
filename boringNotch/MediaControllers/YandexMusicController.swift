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
//  NowPlayingController) but filters it down to the Yandex Music bundle id, and issues
//  transport commands through MediaRemote. "Like"/"favorite" is not expressible over
//  MediaRemote, so it is attempted best-effort through the Accessibility API by pressing
//  the heart button inside the app window.
//

import AppKit
import ApplicationServices
import Combine
import Foundation

final class YandexMusicController: ObservableObject, MediaControllerProtocol {
    // MARK: - Constants
    static let bundleID = "ru.yandex.desktop.music"

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

    // MARK: - MediaRemote function pointers
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    // MARK: - Adapter stream
    private var process: Process?
    private var pipeHandler: JSONLinesPipeHandler?
    private var streamTask: Task<Void, Never>?

    // Whether the current system Now Playing session belongs to Yandex Music. The adapter
    // only reports the owning bundle id in full snapshots; incremental "diff" updates (a new
    // artwork, a play/pause, a rate change) arrive with no owner, so we must remember the
    // owner from the last full snapshot and apply owner-less diffs to it.
    private var sessionIsYandex = false

    // Cached AX element for Yandex's persistent bottom now-playing bar (the container holding
    // the real transport + like controls). Finding it means walking the Chromium a11y tree from
    // the app root; caching turns the per-command/per-track cost into a cheap validation plus a
    // tiny subtree search. Only touched on the main actor.
    private var cachedTransportCluster: AXUIElement?

    // Observes Yandex Music quitting so the notch can stop showing it as playing.
    private var terminationObserver: NSObjectProtocol?

    // MARK: - Initialization
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let sendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let setElapsedPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let setShufflePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let setRepeatPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            sendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            setElapsedPointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            setShufflePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            setRepeatPointer, to: (@convention(c) (Int) -> Void).self)

        Task { await setupNowPlayingObserver() }

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
        sessionIsYandex = false
        cachedTransportCluster = nil
        var stopped = playbackState
        stopped.isPlaying = false
        stopped.playbackRate = 0
        playbackState = stopped
    }

    deinit {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        streamTask?.cancel()

        if let pipeHandler = self.pipeHandler {
            Task { await pipeHandler.close() }
        }

        if let process = self.process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }

        self.process = nil
        self.pipeHandler = nil
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
        if pressTransport(exact: Self.playPauseExact, contains: Self.playPauseContains) {
            applyOptimisticPlayState(true)
            return
        }
        handleTransportMiss()
    }

    @MainActor
    func pause() async {
        guard playbackState.isPlaying else { return }
        if pressTransport(exact: Self.playPauseExact, contains: Self.playPauseContains) {
            applyOptimisticPlayState(false)
            return
        }
        handleTransportMiss()
    }

    @MainActor
    func togglePlay() async {
        if pressTransport(exact: Self.playPauseExact, contains: Self.playPauseContains) {
            applyOptimisticPlayState(!playbackState.isPlaying)
            return
        }
        handleTransportMiss()
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
        playbackState = s
    }

    @MainActor
    func nextTrack() async {
        if pressTransport(exact: Self.nextExact, contains: Self.nextContains) { return }
        handleTransportMiss()
    }

    @MainActor
    func previousTrack() async {
        if pressTransport(exact: Self.previousExact, contains: Self.previousContains) { return }
        handleTransportMiss()
    }

    /// Called when an AX transport press couldn't be delivered. Rather than hijacking another
    /// app via a global MediaRemote command, ensure Yandex Music itself is the target: launch it
    /// when it isn't running, or nudge the user to grant Accessibility when it is (which is what
    /// the on-screen controls need).
    @MainActor
    private func handleTransportMiss() {
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
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    @MainActor
    func toggleShuffle() async {
        guard sessionIsYandex else { return }
        // Shuffle mode: 1 = off, 3 = on (mirrors NowPlayingController).
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }

    @MainActor
    func toggleRepeat() async {
        guard sessionIsYandex else { return }
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }

    @MainActor
    func setVolume(_ level: Double) async {
        // Not supported for the Electron app; keep the local value in sync for the UI.
        playbackState.volume = max(0.0, min(1.0, level))
    }

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    @MainActor
    func updatePlaybackInfo() async {
        // Metadata arrives continuously through the adapter stream. On an explicit refresh
        // (e.g. when this controller becomes active) re-read the like state via Accessibility.
        refreshFavoriteState()
    }

    // MARK: - Favorite (best-effort via Accessibility)
    // Honors the requested target state: a blind press would mis-toggle when the track is
    // already in the requested state (the protocol contract is "set", not "toggle").
    @MainActor
    func setFavorite(_ favorite: Bool) async {
        if let current = readLikeState(), current == favorite { return }
        pressLikeButton()
        try? await Task.sleep(for: .milliseconds(200))
        refreshFavoriteState()
    }

    @MainActor
    private func refreshFavoriteState() {
        guard let liked = readLikeState() else { return }
        if liked != playbackState.isFavorite {
            playbackState.isFavorite = liked
        }
    }

    // MARK: - Adapter stream setup
    private func setupNowPlayingObserver() async {
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()

        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                await self?.processJSONStream()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    private func processJSONStream() async {
        guard let pipeHandler = self.pipeHandler else { return }

        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    // MARK: - Update handling
    // @MainActor so playbackState/sessionIsYandex are only ever touched on the main actor
    // (the transport methods and refreshFavoriteState are too). The existing
    // `await self?.handleAdapterUpdate(update)` call hops the stream callback onto main.
    @MainActor
    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        let payload = update.payload
        let diff = update.diff ?? false

        // Route the update to the right session. Full snapshots (diff == false) carry the
        // owning bundle id and (re)set who owns the session. Diffs carry no owner and belong
        // to whatever the current session is.
        let explicitOwner = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier
        if let explicitOwner {
            sessionIsYandex = (explicitOwner == Self.bundleID)
        } else if !diff {
            // A full snapshot with no owner means the Now Playing session was cleared.
            sessionIsYandex = false
        }

        // Ignore anything that is not (part of) the Yandex Music session, so the notch keeps
        // showing the last known Yandex state instead of hijacking to a different player.
        guard sessionIsYandex else { return }

        var newState = playbackState
        newState.bundleIdentifier = Self.bundleID

        newState.title = payload.title ?? (diff ? playbackState.title : "")
        newState.artist = payload.artist ?? (diff ? playbackState.artist : "")
        newState.album = payload.album ?? (diff ? playbackState.album : "")
        newState.duration = payload.duration ?? (diff ? playbackState.duration : 0)

        // Resolve the new timestamp first so currentTime always stays a consistent pair with it
        // (the UI extrapolates position as currentTime + (now - lastUpdated) * rate).
        let newTimestamp: Date
        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newTimestamp = date
        } else if !diff {
            newTimestamp = Date()
        } else {
            newTimestamp = playbackState.lastUpdated
        }

        if let elapsedTime = payload.elapsedTime {
            newState.currentTime = elapsedTime
        } else if !diff {
            newState.currentTime = 0
        } else {
            // No fresh position in a diff: roll the previous position forward to the new
            // timestamp, advancing only for the interval we were actually playing (Yandex
            // freezes elapsedTime while playing, so this keeps the pair honest).
            let interval = newTimestamp.timeIntervalSince(playbackState.lastUpdated)
            let advance = playbackState.isPlaying ? interval * playbackState.playbackRate : 0
            newState.currentTime = playbackState.currentTime + max(0, advance)
        }
        newState.lastUpdated = newTimestamp

        if let shuffleMode = payload.shuffleMode {
            newState.isShuffled = shuffleMode != 1
        } else if !diff {
            newState.isShuffled = false
        } else {
            newState.isShuffled = playbackState.isShuffled
        }

        if let repeatModeValue = payload.repeatMode {
            newState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newState.repeatMode = .off
        } else {
            newState.repeatMode = playbackState.repeatMode
        }

        if let artworkDataString = payload.artworkData {
            newState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if !diff {
            // Yandex omits artwork on full snapshots for the CURRENT track (pause / seek / redump).
            // Keep the existing artwork for the same track — nil-ing then re-setting it would flip
            // album art and spuriously re-trigger the lyrics fetch. Only clear on a real track change.
            let sameTrack = (payload.title ?? "") == playbackState.title
                && (payload.artist ?? "") == playbackState.artist
            if !sameTrack { newState.artwork = nil }
        }

        newState.playbackRate = payload.playbackRate ?? (diff ? playbackState.playbackRate : 1.0)
        newState.isPlaying = payload.playing ?? (diff ? playbackState.isPlaying : false)
        newState.volume = payload.volume ?? (diff ? playbackState.volume : 0.5)

        // The like state is only re-read from the (expensive) accessibility tree when the track
        // actually changes; position-only diffs carry the previous value forward. On a track
        // change we read it up front and fold it into this single publish (no stale-then-correct
        // double emission). album is included so same-title/artist-different-album counts.
        let trackChanged = newState.title != playbackState.title
            || newState.artist != playbackState.artist
            || newState.album != playbackState.album
        if trackChanged {
            newState.isFavorite = readLikeState() ?? false
        } else {
            newState.isFavorite = playbackState.isFavorite
        }

        self.playbackState = newState

        if trackChanged {
            // Chromium rebuilds the like control lazily, so the up-front read may lag the new
            // track. Re-read shortly after to correct it (a no-op if already right).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.refreshFavoriteState()
            }
        }
    }
}

// MARK: - Accessibility-based control
//
// The Yandex Music app renders its UI in Chromium, which exposes an accessibility tree to
// macOS. We drive transport (play/pause/next/previous) and "like" by locating the app's own
// on-screen controls and pressing them. This targets Yandex directly — unlike MediaRemote,
// which only ever addresses the single system Now Playing session owner. It is best-effort:
// it needs Accessibility permission, the a11y tree to be built, and depends on the (localized)
// control labels. Every failure degrades gracefully (transport falls back to MediaRemote;
// like becomes a no-op).
extension YandexMusicController {
    // Label matchers. Exact labels are compared whole (lowercased); "contains" fragments are
    // substring-matched. The play/pause matcher deliberately avoids a bare "play" fragment so
    // it never hits a "Play queue"-style control that also contains the word.
    fileprivate static let playPauseExact = ["playback", "play", "pause"]
    fileprivate static let playPauseContains = ["воспроизвед", "пауза", "приостанов", "играть", "продолж"]
    fileprivate static let nextExact = ["next", "next song", "next track"]
    fileprivate static let nextContains = ["следующ", "вперёд", "вперед"]
    fileprivate static let previousExact = ["previous", "previous song", "previous track"]
    fileprivate static let previousContains = ["предыдущ", "назад"]

    // The "like" toggle. The dislike button ("I don't like it" / "Мне не нравится") also
    // contains "like"/"нравится", so its labels are excluded first.
    private static let likeLabelHints = ["like", "нравится"]
    private static let dislikeLabelHints = ["don't like", "dont like", "dislike", "не нравится"]

    // MARK: Transport

    /// Presses a transport control inside Yandex's bottom now-playing bar. Returns true on a
    /// successful press; false if Accessibility is unavailable or the control wasn't found.
    @MainActor
    func pressTransport(exact: [String], contains: [String]) -> Bool {
        // Anchor on the now-playing bar so we never match the many track-row "Playback"/"Like"
        // controls that live elsewhere in the list.
        guard AXIsProcessTrusted(), let cluster = transportCluster() else { return false }

        var visited = 0
        guard let button = firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.matchesControl($0, exact: exact, contains: contains) }
        ) else { return false }

        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: Like

    @MainActor
    func pressLikeButton() {
        guard AXIsProcessTrusted() else {
            NSLog("[YandexMusic] Accessibility permission not granted; cannot toggle like.")
            return
        }
        guard let button = findLikeButton() else {
            NSLog("[YandexMusic] Like button not found in accessibility tree.")
            return
        }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result != .success {
            NSLog("[YandexMusic] Failed to press like button (AX error \(result.rawValue)).")
        }
    }

    /// Returns the current like state if it can be determined, otherwise nil.
    @MainActor
    func readLikeState() -> Bool? {
        guard AXIsProcessTrusted(), let button = findLikeButton() else { return nil }

        // The like toggle exposes its pressed state via kAXValueAttribute (1 = liked, 0 = not).
        if let value: Int = axAttribute(button, kAXValueAttribute) {
            return value != 0
        }
        return nil
    }

    @MainActor
    private func findLikeButton() -> AXUIElement? {
        // The now-playing like control lives inside the bottom bar; anchoring there (as the
        // transport code does) excludes the per-row like buttons in the track list.
        guard let cluster = transportCluster() else { return nil }
        var visited = 0
        return firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.isLikeButton($0) }
        )
    }

    // MARK: Element access & search

    /// Returns the application AX element for Yandex Music with Chromium's web-content
    /// accessibility tree enabled, or nil when the app isn't running.
    @MainActor
    private func yandexAppElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == Self.bundleID }) else { return nil }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium only builds its web-content accessibility tree (where these
        // controls live) once a client opts in via this attribute.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return appElement
    }

    /// The persistent bottom now-playing bar's control container, reused from the cache when it
    /// is still valid, otherwise re-located.
    ///
    /// It is found by locating a "Next song" button — which exists only in the now-playing bar,
    /// never in the track rows — and walking up to the nearest ancestor that also contains a
    /// "Previous song" button. That ancestor is the transport cluster; it holds exactly one each
    /// of play/pause, prev, next and like, so subsequent searches are unambiguous. (The main
    /// page's central player has these too; either container works, since we only ever press.)
    @MainActor
    private func transportCluster() -> AXUIElement? {
        if let cached = cachedTransportCluster, isTransportCluster(cached) {
            return cached
        }
        cachedTransportCluster = nil

        guard let appElement = yandexAppElement() else { return nil }
        var visited = 0
        guard let next = firstDescendant(
            in: appElement, depth: 0, visited: &visited, maxDepth: 60, maxVisited: 8000,
            where: { self.matchesControl($0, exact: Self.nextExact, contains: Self.nextContains) }
        ) else { return nil }

        var node: AXUIElement? = axParent(next)
        var hops = 0
        while let candidate = node, hops < 8 {
            if isTransportCluster(candidate) {
                cachedTransportCluster = candidate
                return candidate
            }
            node = axParent(candidate)
            hops += 1
        }
        return nil
    }

    /// True when `element`'s subtree contains both a "Next song" and a "Previous song" control —
    /// the signature of the now-playing bar's transport cluster.
    @MainActor
    private func isTransportCluster(_ element: AXUIElement) -> Bool {
        var v1 = 0
        let hasNext = firstDescendant(
            in: element, depth: 0, visited: &v1, maxDepth: 12, maxVisited: 400,
            where: { self.matchesControl($0, exact: Self.nextExact, contains: Self.nextContains) }
        ) != nil
        guard hasNext else { return false }
        var v2 = 0
        return firstDescendant(
            in: element, depth: 0, visited: &v2, maxDepth: 12, maxVisited: 400,
            where: { self.matchesControl($0, exact: Self.previousExact, contains: Self.previousContains) }
        ) != nil
    }

    /// Bounded depth-first search returning the first descendant (or `element` itself) that
    /// satisfies `predicate`.
    @MainActor
    private func firstDescendant(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int,
        maxDepth: Int,
        maxVisited: Int,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if depth > maxDepth || visited > maxVisited { return nil }
        visited += 1

        if predicate(element) { return element }

        guard let children: [AXUIElement] = axAttribute(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = firstDescendant(
                in: child, depth: depth + 1, visited: &visited,
                maxDepth: maxDepth, maxVisited: maxVisited, where: predicate) {
                return found
            }
        }
        return nil
    }

    // MARK: Predicates

    @MainActor
    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let value = raw else {
            return nil
        }
        return (value as! AXUIElement)
    }

    @MainActor
    private func matchesControl(_ element: AXUIElement, exact: [String], contains: [String]) -> Bool {
        guard isPressableControl(element) else { return false }
        let labels = axLabels(element)
        guard !labels.isEmpty else { return false }
        // Match per-attribute: an exact token must equal one whole attribute (e.g. AXDescription
        // "playback"), a contains token need only be a substring of some attribute. Matching the
        // concatenation would break as soon as a node also exposes an empty/secondary attribute.
        if labels.contains(where: exact.contains) { return true }
        return labels.contains { label in contains.contains(where: label.contains) }
    }

    @MainActor
    private func isLikeButton(_ element: AXUIElement) -> Bool {
        guard isPressableControl(element) else { return false }
        let labels = axLabels(element)
        guard !labels.isEmpty else { return false }
        // Exclude the dislike control ("I don't like it" / "Мне не нравится") first, as it also
        // contains "like"/"нравится".
        if labels.contains(where: { label in Self.dislikeLabelHints.contains(where: label.contains) }) {
            return false
        }
        return labels.contains { label in Self.likeLabelHints.contains(where: label.contains) }
    }

    @MainActor
    private func isPressableControl(_ element: AXUIElement) -> Bool {
        let role: String? = axAttribute(element, kAXRoleAttribute)
        return role == (kAXButtonRole as String)
            || role == "AXCheckBox"
            || role == (kAXRadioButtonRole as String)
            || role == (kAXMenuButtonRole as String)
    }

    /// The element's individual, non-empty, lowercased text labels
    /// (description/title/identifier/help). Kept as separate entries — not concatenated — so
    /// exact matching isn't defeated by empty or secondary attributes.
    @MainActor
    private func axLabels(_ element: AXUIElement) -> [String] {
        [
            axAttribute(element, kAXDescriptionAttribute) as String?,
            axAttribute(element, kAXTitleAttribute) as String?,
            axAttribute(element, kAXIdentifierAttribute) as String?,
            axAttribute(element, kAXHelpAttribute) as String?,
        ]
        .compactMap { $0 }
        .map { $0.lowercased() }
        .filter { !$0.isEmpty }
    }

    // Generic AX attribute reader for String, Int and [AXUIElement].
    @MainActor
    private func axAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else {
            return nil
        }
        if let typed = value as? T { return typed }
        // aria-pressed / toggle state comes back as a CFNumber; bridge to Int when requested.
        if T.self == Int.self, let number = value as? NSNumber { return number.intValue as? T }
        return nil
    }
}
