//
//  MediaControllerProtocol.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import BoringCore
import Foundation
import AppKit
import Combine

@MainActor
protocol MediaControllerProtocol: ObservableObject {
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> { get }
    var capabilities: MediaCapabilities { get }
    var supportsVolumeControl: Bool { get }
    var supportsFavorite: Bool { get }
    /// Nil means the current value is unreadable; action availability is a separate capability.
    var currentFavoriteState: Bool? { get }
    var supportsDislike: Bool { get }

    func stop()
    /// Requests a specific state; an unknown value must not be implemented by a blind press.
    func setFavorite(_ favorite: Bool) async
    /// Explicit user intent to toggle the current source's control once.
    func toggleFavorite() async
    func dislike() async
    func play() async
    func pause() async
    func seek(to time: Double) async
    func nextTrack() async
    func previousTrack() async
    func togglePlay() async
    func toggleShuffle() async
    func toggleRepeat() async
    func setVolume(_ level: Double) async
    func isActive() -> Bool
    func updatePlaybackInfo() async
}

extension MediaControllerProtocol {
    var capabilities: MediaCapabilities {
        .init(volume: supportsVolumeControl, favorite: supportsFavorite, dislike: supportsDislike)
    }
    func stop() {}
    var currentFavoriteState: Bool? { nil }
    func toggleFavorite() async {
        guard !Task.isCancelled, supportsFavorite, let current = currentFavoriteState else { return }
        await setFavorite(!current)
    }
    // Most sources have no dedicated dislike; default to just removing the like.
    var supportsDislike: Bool { false }
    func dislike() async { await setFavorite(false) }
}
