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

import AppKit
import ApplicationServices
import Combine
import Foundation

// The adapter distinguishes missing fields (unchanged) from explicit nulls (removed).
// Optional properties alone lose that distinction when decoding incremental updates.
private enum YandexMetadataValue: Decodable, Equatable {
    case string(String), number(Double), boolean(Bool), null, unsupported

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .unsupported }
    }
}

private struct YandexNowPlayingUpdate: Decodable {
    let payload: [String: YandexMetadataValue]
    let diff: Bool?
}

private extension Dictionary where Key == String, Value == YandexMetadataValue {
    func string(_ key: String) -> String? {
        guard case .string(let value) = self[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value) = self[key] else { return nil }
        return value
    }

    func boolean(_ key: String) -> Bool? {
        guard case .boolean(let value) = self[key] else { return nil }
        return value
    }
}

private struct YandexAccessibilityNode: Decodable {
    let role: String
    let labels: [String]
    let value: String?
    let url: URL?
    let children: [YandexAccessibilityNode]
}

private struct YandexAccessibilityMetadata {
    let title: String
    let artist: String
    let album: String
    let trackID: String?
    let artworkURL: URL?
    let isPlaying: Bool?

    init?(root: YandexAccessibilityNode) {
        var nodes: [YandexAccessibilityNode] = []
        func visit(_ node: YandexAccessibilityNode) { nodes.append(node); node.children.forEach(visit) }
        visit(root)
        func text(_ node: YandexAccessibilityNode, prefixes: [String]) -> String {
            for label in node.labels {
                for prefix in prefixes where label.lowercased().hasPrefix(prefix) {
                    return String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let value = node.value, !value.isEmpty { return value }
            return node.children.compactMap { $0.value }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let tracks = nodes.filter { node in
            node.role == "AXLink" && ((node.url.map(Self.isEntityURL) == true && node.url?.path.contains("/track/") == true)
                || node.labels.contains { $0.lowercased().hasPrefix("track ") || $0.lowercased().hasPrefix("трек ") })
        }
        let titles = tracks.map { text($0, prefixes: ["track ", "трек "]) }.filter { !$0.isEmpty }
        // A whole library/list is not the persistent player bar. Never borrow a random row's title.
        let trackPaths = Set(tracks.compactMap { $0.url }.filter(Self.isEntityURL).map(\.path))
        guard let title = titles.first, Set(titles).count == 1, trackPaths.count <= 1 else { return nil }
        let track = tracks.first { $0.url.map(Self.isEntityURL) == true && $0.url?.path.contains("/track/") == true }
        let components = track?.url?.pathComponents ?? []
        let id = components.firstIndex(of: "track").flatMap { $0 + 1 < components.count ? components[$0 + 1] : nil }
        self.trackID = id.flatMap { !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) ? $0 : nil }
        self.title = title
        var artists: [String] = []
        for node in nodes where node.role == "AXLink" && node.url.map(Self.isEntityURL) == true && node.url?.path.contains("/artist/") == true {
            let name = text(node, prefixes: ["artist ", "артист ", "исполнитель "])
            if !name.isEmpty && !artists.contains(name) { artists.append(name) }
        }
        artist = artists.joined(separator: ", ")
        album = nodes.first { $0.role == "AXLink" && $0.url.map(Self.isEntityURL) == true && $0.url?.path.contains("/album/") == true
            && $0.url?.path.contains("/track/") != true }
            .map { text($0, prefixes: ["album ", "альбом "]) } ?? ""
        artworkURL = nodes.lazy.filter { $0.role == "AXImage" }.compactMap(\.url)
            .first(where: Self.isTrustedArtworkURL)
        let controls = nodes.filter { ["AXButton", "AXCheckBox"].contains($0.role) }
            .flatMap(\.labels).map { $0.lowercased() }
        if controls.contains(where: { $0 == "pause" || $0.contains("пауза") || $0.contains("приостанов") }) { isPlaying = true }
        else if controls.contains(where: { $0 == "play" || $0 == "playback" || $0.contains("воспроизвед") || $0 == "продолжить" }) { isPlaying = false }
        else { isPlaying = nil }
    }

    static func isEntityURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        if url.scheme?.lowercased() == "music-application", url.host?.lowercased() == "desktop" { return true }
        return url.scheme?.lowercased() == "https"
            && ["music.yandex.ru", "music.yandex.com", "music.yandex.by", "music.yandex.kz", "music.yandex.uz"].contains(url.host?.lowercased() ?? "")
    }

    static func isTrustedArtworkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && ["avatars.yandex.net", "avatars.mds.yandex.net"].contains(url.host?.lowercased() ?? "")
    }
}

/// All AX IPC and tree walking stays on this actor's executor, away from hover/UI updates.
private actor YandexAccessibilityReader {
    private var cachedBar: AXUIElement?
    private var cachedPID: pid_t?
    private var nextSearch = Date.distantPast

    private func attributes(_ element: AXUIElement) -> (node: YandexAccessibilityNode, children: [AXUIElement])? {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXURLAttribute, kAXChildrenAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == names.count, let role = values[0] as? String else { return nil }
        let url = (values[4] as? URL) ?? (values[4] as? String).flatMap(URL.init(string:))
        let labels = [values[1] as? String, values[2] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        return (.init(role: role, labels: labels, value: values[3] as? String, url: url, children: []), values[5] as? [AXUIElement] ?? [])
    }

    private func tree(_ element: AXUIElement, remaining: inout Int, deadline: Date, depth: Int = 0) -> YandexAccessibilityNode? {
        guard !Task.isCancelled, remaining > 0, depth < 18, Date() < deadline,
              let (node, children) = attributes(element) else { return nil }
        remaining -= 1
        var descendants: [YandexAccessibilityNode] = []
        for child in children {
            guard let snapshot = tree(child, remaining: &remaining, deadline: deadline, depth: depth + 1) else { return nil }
            descendants.append(snapshot)
        }
        return .init(role: node.role, labels: node.labels, value: node.value, url: node.url, children: descendants)
    }

    private func nextButton(_ element: AXUIElement, remaining: inout Int, deadline: Date, depth: Int = 0) -> AXUIElement? {
        guard !Task.isCancelled, remaining > 0, depth < 60, Date() < deadline,
              let (node, children) = attributes(element) else { return nil }
        remaining -= 1
        if node.role == "AXButton", node.labels.contains(where: { label in
            let label = label.lowercased()
            return ["next", "next song", "next track"].contains(label) || label.contains("следующ")
        }) { return element }
        for child in children {
            if let found = nextButton(child, remaining: &remaining, deadline: deadline, depth: depth + 1) { return found }
        }
        return nil
    }

    func read(processIdentifier: pid_t) -> YandexAccessibilityMetadata? {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        if cachedPID != processIdentifier { cachedBar = nil; nextSearch = .distantPast; cachedPID = processIdentifier }
        if let cachedBar {
            var budget = 500
            if let node = tree(cachedBar, remaining: &budget, deadline: Date().addingTimeInterval(0.25)),
               let metadata = YandexAccessibilityMetadata(root: node) { return metadata }
            self.cachedBar = nil
            nextSearch = .distantPast
        }
        guard Date() >= nextSearch else { return nil }
        nextSearch = Date().addingTimeInterval(5)
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var budget = 6000
        guard let next = nextButton(application, remaining: &budget, deadline: Date().addingTimeInterval(1)) else { return nil }
        var candidate = next
        for _ in 0..<7 {
            var parent: CFTypeRef?
            guard !Task.isCancelled, AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            candidate = parent as! AXUIElement
            guard let (node, _) = attributes(candidate), !["AXWebArea", "AXWindow", "AXApplication"].contains(node.role) else { break }
            var budget = 500
            if let snapshot = tree(candidate, remaining: &budget, deadline: Date().addingTimeInterval(0.25)),
               let metadata = YandexAccessibilityMetadata(root: snapshot) {
                cachedBar = candidate
                return metadata
            }
        }
        return nil
    }
}

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

    // Yandex has a real "I don't like it" control that trains My Wave (pressed via Accessibility).
    var supportsDislike: Bool { true }

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
    private var adapterPayload: [String: YandexMetadataValue] = [:]
    private let accessibilityReader = YandexAccessibilityReader()
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
    private var cachedTransportCluster: AXUIElement?

    // Observes Yandex Music quitting so the notch can stop showing it as playing.
    private var terminationObserver: NSObjectProtocol?

    // Watchdog: how many times in a row the adapter subprocess has died, for capped backoff.
    private var restartAttempts = 0

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

        Task { @MainActor [weak self] in
            self?.startAccessibilityMonitoring()
            await self?.setupNowPlayingObserver()
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
        sessionIsYandex = false
        adapterPayload.removeAll()
        accessibilityGeneration &+= 1
        accessibilityArtworkGeneration &+= 1
        accessibilityArtworkTask?.cancel()
        accessibilityArtworkKey = ""
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
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
        let streamTask = self.streamTask
        streamTask?.cancel()
        accessibilityTask?.cancel()
        accessibilityArtworkTask?.cancel()

        // Tear the adapter subprocess/pipe down OFF the calling thread — waitUntilExit() would
        // otherwise block whatever thread deallocs the controller (e.g. the main thread during a
        // media-source switch).
        let process = self.process
        let pipeHandler = self.pipeHandler
        Task.detached {
            // Let a pending read finish with EOF before closing its reader. Closing the handler
            // first removes the readability callback and can leave that read suspended forever.
            if let pipeHandler {
                let pipe = await pipeHandler.getPipe()
                try? pipe.fileHandleForWriting.close()
            }
            if let process, process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            await streamTask?.value
            await pipeHandler?.close()
        }

        self.process = nil
        self.pipeHandler = nil
    }

    // MARK: - Metadata when another app owns the system media session
    @MainActor
    private func startAccessibilityMonitoring() {
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
    private func accessibilityRequest() -> (YandexAccessibilityReader, pid_t, UInt)? {
        guard !sessionIsYandex, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.bundleID }),
              !app.isTerminated else { return nil }
        return (accessibilityReader, app.processIdentifier, accessibilityGeneration)
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
        guard generation == accessibilityGeneration else { return }
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
    }

    @MainActor
    private func applyAccessibilityMetadata(_ metadata: YandexAccessibilityMetadata, generation: UInt) {
        guard !sessionIsYandex, generation == accessibilityGeneration else { return }
        accessibilityMetadataLastReadAt = Date()
        accessibilityIsPlaying = metadata.isPlaying
        let trackChanged = metadata.title != playbackState.title || metadata.artist != playbackState.artist
            || (metadata.trackID != nil && accessibilityTrackID != nil && metadata.trackID != accessibilityTrackID)
        accessibilityTrackID = metadata.trackID
        var state = playbackState
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
        guard !sessionIsYandex, accessibilityArtworkKey == key, accessibilityArtworkGeneration == generation else { return }
        if let data { playbackState.artwork = data }
        else { accessibilityArtworkRetryAfter = Date().addingTimeInterval(10) }
    }

    private static func fetchAccessibilityArtwork(_ metadata: YandexAccessibilityMetadata, token: String,
                                                  session: URLSession = .shared) async -> Data? {
        guard !Task.isCancelled else { return nil }
        var artworkURL = metadata.artworkURL
        if artworkURL == nil, let id = metadata.trackID,
           let url = URL(string: "https://api.music.yandex.net/tracks/\(id)") {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("YandexMusicAndroid/24023621", forHTTPHeaderField: "X-Yandex-Music-Client")
            if !token.isEmpty { request.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization") }
            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               response.url?.scheme == "https", response.url?.host == "api.music.yandex.net",
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tracks = json["result"] as? [[String: Any]], let cover = tracks.first?["coverUri"] as? String {
                let path = cover.replacingOccurrences(of: "%%", with: "200x200")
                artworkURL = URL(string: path.hasPrefix("https://") ? path : "https://" + path)
            }
        }
        guard !Task.isCancelled, let artworkURL, YandexAccessibilityMetadata.isTrustedArtworkURL(artworkURL) else { return nil }
        let request = URLRequest(url: artworkURL, timeoutInterval: 5)
        guard let (data, response) = try? await session.data(for: request), !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let finalURL = response.url, YandexAccessibilityMetadata.isTrustedArtworkURL(finalURL),
              !data.isEmpty, data.count <= 10_000_000 else { return nil }
        return data
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
        await refreshAccessibilityMetadata()
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

    // MARK: - Dislike (best-effort via Accessibility)
    @MainActor
    func dislike() async {
        pressDislikeButton()
        // Dislike un-likes and skips; reconcile the heart shortly after.
        try? await Task.sleep(for: .milliseconds(200))
        refreshFavoriteState()
    }

    // MARK: - Adapter stream setup
    @MainActor
    private func setupNowPlayingObserver() async {
        guard !Task.isCancelled else { return }
        let process = Process()
        guard
            let scriptURL = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
            let frameworkPath = Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
        else {
            assertionFailure("Could not find mediaremote-adapter.pl script or framework path")
            return
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, frameworkPath, "stream", "--debounce=100"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        guard !Task.isCancelled else {
            await pipeHandler.close()
            return
        }

        self.process = process
        self.pipeHandler = pipeHandler

        do {
            try process.run()
            streamTask = Task { [weak self] in
                guard !Task.isCancelled else { return }
                // Capture the handler directly: an instance method would retain the controller
                // for the entire stream, preventing deinit when the media source changes.
                await pipeHandler.readJSONLines(as: YandexNowPlayingUpdate.self) { [weak self] update in
                    guard !Task.isCancelled else { return }
                    await self?.handleAdapterUpdate(update)
                }
                guard !Task.isCancelled, let delay = self?.streamEnded() else { return }
                // Sleep without holding the controller, so a source switch can cancel a pending
                // restart as well as an active stream.
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.setupNowPlayingObserver()
            }
        } catch {
            assertionFailure("Failed to launch mediaremote-adapter.pl: \(error)")
        }
    }

    /// Watchdog: restarts the adapter subprocess (with capped exponential backoff) when its
    /// stream ends unexpectedly, so a crashed perl process doesn't freeze the notch forever.
    @MainActor
    private func streamEnded() -> TimeInterval {
        // Tear down the dead process/pipe off the main thread.
        let oldProcess = process
        let oldHandler = pipeHandler
        process = nil
        pipeHandler = nil
        adapterPayload.removeAll()
        sessionIsYandex = false
        systemMediaOwnerBundleIdentifier = nil
        systemMediaIsPlaying = nil
        systemMediaLastUpdated = nil
        systemMediaTimestamp = nil
        accessibilityGeneration &+= 1
        accessibilityIsPlaying = nil
        accessibilityMetadataLastReadAt = nil
        Task.detached {
            await oldHandler?.close()
            if let oldProcess, oldProcess.isRunning {
                oldProcess.terminate()
                oldProcess.waitUntilExit()
            }
        }

        restartAttempts = min(restartAttempts + 1, 6)
        let delay = min(pow(2.0, Double(restartAttempts)), 30) // 2, 4, 8, 16, 30, 30…s
        NSLog("[YandexMusic] Adapter stream ended; restarting in \(Int(delay))s.")
        return delay
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
        restartAttempts = 0   // receiving data → the stream is healthy; reset watchdog backoff
        let patch = update.payload
        let diff = update.diff ?? false
        let previousPayload = adapterPayload

        // Merge the complete adapter state before resolving the owner. A diff can change only
        // the helper bundle id while its parent is still Yandex, or remove the old parent only
        // after the new bundle id and metadata have arrived. Looking at that diff in isolation
        // would lose the session and ignore every later title/artwork update without an owner.
        if !diff { adapterPayload.removeAll() }
        for (key, value) in patch {
            if case .null = value { adapterPayload.removeValue(forKey: key) }
            else { adapterPayload[key] = value }
        }
        let payload = adapterPayload
        let parent = payload.string("parentApplicationBundleIdentifier").flatMap { $0.isEmpty ? nil : $0 }
        let previousOwner = systemMediaOwnerBundleIdentifier
        let wasYandex = sessionIsYandex
        systemMediaOwnerBundleIdentifier = parent ?? payload.string("bundleIdentifier")
        systemMediaIsPlaying = payload.boolean("playing")
        systemMediaLastUpdated = Date()
        if let timestamp = payload.string("timestamp") {
            systemMediaTimestamp = Self.adapterDate(timestamp)
        } else { systemMediaTimestamp = nil }
        if systemMediaOwnerBundleIdentifier != nil, systemMediaOwnerBundleIdentifier != Self.bundleID {
            let changed = ["title", "artist", "elapsedTime", "playing"].contains { previousPayload[$0] != payload[$0] }
            // A newly observed paused session still needs a conservative quiet-time baseline.
            // Timestamp-only refreshes must not keep moving that baseline forward forever.
            if previousOwner != systemMediaOwnerBundleIdentifier
                || (changed && (diff || systemMediaIsPlaying == true || previousOwner != nil)) {
                lastForeignMediaActivity = Date()
            }
        }
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

        var newState = playbackState
        newState.bundleIdentifier = Self.bundleID

        newState.title = payload.string("title") ?? ""
        newState.artist = payload.string("artist") ?? ""
        newState.album = payload.string("album") ?? ""
        newState.duration = payload.number("duration") ?? 0

        // Resolve the new timestamp first so currentTime always stays a consistent pair with it
        // (the UI extrapolates position as currentTime + (now - lastUpdated) * rate).
        let newTimestamp: Date
        if let dateString = patch.string("timestamp"),
           let date = Self.adapterDate(dateString) {
            newTimestamp = date
        } else if !diff {
            newTimestamp = Date()
        } else {
            newTimestamp = playbackState.lastUpdated
        }

        if let elapsedTime = patch.number("elapsedTime") {
            newState.currentTime = elapsedTime
        } else if !diff || patch["elapsedTime"] != nil {
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

        // Shuffle/repeat are player-wide settings — carry them forward whenever an update omits
        // them (Yandex leaves them out of pause/seek/redump snapshots), never reset to off.
        if let shuffleMode = payload.number("shuffleMode") {
            newState.isShuffled = shuffleMode != 1
        } else {
            newState.isShuffled = playbackState.isShuffled
        }

        if let repeatModeValue = payload.number("repeatMode"), let mode = Int(exactly: repeatModeValue) {
            newState.repeatMode = RepeatMode(rawValue: mode) ?? .off
        } else {
            newState.repeatMode = playbackState.repeatMode
        }

        if let artworkDataString = payload.string("artworkData") {
            newState.artwork = Data(
                base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if patch["artworkData"] != nil {
            newState.artwork = nil
        } else {
            // Yandex omits artwork on full snapshots for the CURRENT track (pause / seek / redump).
            // Keep the existing artwork for the same track — nil-ing then re-setting it would flip
            // album art and spuriously re-trigger the lyrics fetch. Only clear on a real track change.
            let sameTrack = newState.title == playbackState.title
                && newState.artist == playbackState.artist
                && newState.album == playbackState.album
            if !sameTrack { newState.artwork = nil }
        }

        newState.playbackRate = payload.number("playbackRate") ?? 1.0
        newState.isPlaying = payload.boolean("playing") ?? false
        newState.volume = payload.number("volume") ?? 0.5

        // The like state is only re-read from the (expensive) accessibility tree when the track
        // actually changes; position-only diffs carry the previous value forward. On a track
        // change we read it up front and fold it into this single publish (no stale-then-correct
        // double emission). album is included so same-title/artist-different-album counts.
        let trackChanged = newState.title != playbackState.title
            || newState.artist != playbackState.artist
            || newState.album != playbackState.album
        // Carry the like state forward here. Reading it inline would do a synchronous Accessibility
        // tree walk on the main actor on every track change (a visible UI stall); the bounded poll
        // below reconciles it from the (lazily-built) control off the hot path instead.
        newState.isFavorite = playbackState.isFavorite

        self.playbackState = newState

        if trackChanged {
            // Chromium rebuilds the like control lazily; poll briefly until we get a stable read
            // for THIS track (bail if the track changes again mid-poll).
            let trackTitle = newState.title
            Task { @MainActor [weak self] in
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard let self, self.playbackState.title == trackTitle else { return }
                    if let liked = self.readLikeState() {
                        if liked != self.playbackState.isFavorite { self.playbackState.isFavorite = liked }
                        return
                    }
                }
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

    @MainActor
    func pressDislikeButton() {
        guard AXIsProcessTrusted() else {
            NSLog("[YandexMusic] Accessibility permission not granted; cannot dislike.")
            return
        }
        guard let cluster = transportCluster() else { return }
        var visited = 0
        guard let button = firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.isDislikeButton($0) }
        ) else {
            NSLog("[YandexMusic] Dislike button not found in accessibility tree.")
            return
        }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    @MainActor
    private func isDislikeButton(_ element: AXUIElement) -> Bool {
        guard isPressableControl(element) else { return false }
        let labels = axLabels(element)
        guard !labels.isEmpty else { return false }
        return labels.contains { label in Self.dislikeLabelHints.contains(where: label.contains) }
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
