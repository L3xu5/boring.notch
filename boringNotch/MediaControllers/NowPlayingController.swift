//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import BoringCore
import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        guard !stopped, !Task.isCancelled else { return }
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: ""
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }
    var capabilities: MediaCapabilities {
        .init(volume: supportsVolumeControl, favorite: supportsFavorite,
              seek: commands.canSeek, shuffle: commands.canShuffle, repeatMode: commands.canRepeat)
    }

    func setFavorite(_ favorite: Bool) async {
        guard !stopped, !Task.isCancelled else { return }
        let bundleID = playbackState.bundleIdentifier

        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }

        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    // MARK: - Media Remote Functions
    private let commands = MediaRemoteCommandClient()

    private let adapter = MediaAdapterSession<MediaWireUpdate>()
    private var wire = MediaWireState()
    private var stopped = false

    // MARK: - Initialization
    init?() {
        Task { @MainActor [weak self] in self?.startAdapter() }
    }

    deinit { adapter.stop() }
    func stop() { stopped = true; adapter.stop(); wire.reset() }

    // MARK: - Protocol Implementation
    func play() async {
        guard !stopped, !Task.isCancelled else { return }
        commands.send(0)
    }

    func pause() async {
        guard !stopped, !Task.isCancelled else { return }
        commands.send(1)
    }

    func togglePlay() async {
        guard !stopped, !Task.isCancelled else { return }
        commands.send(2)
    }

    func nextTrack() async {
        guard !stopped, !Task.isCancelled else { return }
        commands.send(4)
    }

    func previousTrack() async {
        guard !stopped, !Task.isCancelled else { return }
        commands.send(5)
    }

    func seek(to time: Double) async {
        guard !stopped, !Task.isCancelled else { return }
        commands.seek(time)
    }

    func isActive() -> Bool {
        return !stopped
    }

    func toggleShuffle() async {
        guard !stopped, !Task.isCancelled else { return }
        // commands.send(6)
        commands.shuffle(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }

    func toggleRepeat() async {
        guard !stopped, !Task.isCancelled else { return }
        // commands.send(7)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        commands.repeatMode(newRepeatMode)
    }

    func setVolume(_ level: Double) async {
        guard !stopped, !Task.isCancelled, level.isFinite else { return }
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)

        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }

        guard !stopped, !Task.isCancelled, playbackState.bundleIdentifier == bundleID else { return }
        playbackState.volume = clampedLevel
    }

    private func startAdapter() {
        guard !stopped else { return }
        adapter.start(onUpdate: { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }, onRestart: { [weak self] in await self?.resetWire() })
    }
    private func resetWire() { wire.reset() }
    private func handleAdapterUpdate(_ update: MediaWireUpdate) {
        guard !stopped else { return }
        wire.apply(update)
        playbackState = wire.playbackState(applying: update, previous: playbackState, now: Date())
    }

     private func fetchFavoriteStateIfSupported() async {
         let identity = playbackState.identity
         let bundleID = playbackState.bundleIdentifier

         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }

             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 guard !stopped, !Task.isCancelled, playbackState.identity == identity else { return }
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }

}

// Shared wire types belong to BoringCore; adapters share the same patch/null semantics.
typealias NowPlayingUpdate = MediaWireUpdate
