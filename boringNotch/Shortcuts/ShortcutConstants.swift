//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))

    // Media hotkeys that target the selected source directly (e.g. Yandex via Accessibility),
    // so they work even when a browser tab owns the system Now Playing session. No defaults —
    // the user assigns them in Settings.
    static let mediaPlayPause = Self("mediaPlayPause")
    static let mediaNextTrack = Self("mediaNextTrack")
    static let mediaPreviousTrack = Self("mediaPreviousTrack")
    static let mediaLike = Self("mediaLike")
    static let mediaDislike = Self("mediaDislike")
}
