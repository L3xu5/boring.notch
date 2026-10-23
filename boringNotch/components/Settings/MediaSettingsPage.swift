import AppKit
import Combine
import Defaults
import SwiftUI

struct Media: View {
    @Default(.waitInterval) var waitInterval
    @Default(.mediaController) var mediaController
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.hideNotchOption) var hideNotchOption
    @Default(.enableSneakPeek) private var enableSneakPeek
    @Default(.sneakPeekStyles) var sneakPeekStyles

    @Default(.enableLyrics) var enableLyrics
    @Default(.lyricsOffset) var lyricsOffset
    @State private var nowPlayingDeprecated = MusicManager.shared.isNowPlayingDeprecated

    var body: some View {
        Form {
            Section {
                Picker("Music Source", selection: $mediaController) {
                    if !availableMediaControllers.contains(mediaController) {
                        Text("\(mediaController.rawValue) — unavailable").tag(mediaController).disabled(true)
                    }
                    ForEach(availableMediaControllers) { controller in
                        Text(controller.rawValue).tag(controller)
                    }
                }
                .onChange(of: mediaController) { _, _ in
                    NotificationCenter.default.post(
                        name: Notification.Name.mediaControllerChanged,
                        object: nil
                    )
                }

                if mediaController == .yandexMusic {
                    YandexAccessibilityStatusView()
                    YandexTokenSettingsView()
                }
            } header: {
                Text("Media Source")
            } footer: {
                if nowPlayingDeprecated && mediaController == .youtubeMusic {
                    HStack {
                        Text("YouTube Music requires this third-party app to be installed: ")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Link(
                            "https://github.com/pear-devs/pear-desktop",
                            destination: URL(string: "https://github.com/pear-devs/pear-desktop")!
                        )
                        .font(.caption)
                        .foregroundColor(.blue)  // Ensures it's visibly a link
                    }
                } else {
                    Text(
                        mediaController.description
                    )
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
            }

            Section {
                Toggle(
                    "Show music live activity",
                    isOn: $coordinator.musicLiveActivityEnabled.animation()
                )
                Toggle("Show sneak peek on playback changes", isOn: $enableSneakPeek)
                Picker("Sneak Peek Style", selection: $sneakPeekStyles) {
                    ForEach(SneakPeekStyle.allCases) { style in
                        Text(style.rawValue).tag(style)
                    }
                }
                HStack {
                    Stepper(value: $waitInterval, in: 0...10, step: 1) {
                        HStack {
                            Text("Media inactivity timeout")
                            Spacer()
                            Text("\(Defaults[.waitInterval], specifier: "%.0f") seconds")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker(
                    selection: $hideNotchOption,
                    label:
                        HStack {
                            Text("Full screen behavior")
                            customBadge(text: "Beta")
                        }
                ) {
                    Text("Hide for all apps").tag(HideNotchOption.always)
                    Text("Hide for media app only").tag(
                        HideNotchOption.nowPlayingOnly)
                    Text("Never hide").tag(HideNotchOption.never)
                }
            } header: {
                Text("Media playback live activity")
            }

            Section {
                MusicSlotConfigurationView()
                Defaults.Toggle(key: .enableLyrics) {
                    HStack {
                        Text("Enable lyrics")
                        customBadge(text: "Beta")
                    }
                }
                if enableLyrics {
                    HStack {
                        Text("Lyrics offset")
                        Slider(value: $lyricsOffset, in: -2...2, step: 0.05)
                            .accessibilityLabel("Lyrics offset")
                            .accessibilityValue(String(format: "%+.2f seconds", lyricsOffset))
                        Text(String(format: "%+.2fs", lyricsOffset))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    Text("Positive delays lyrics (use if they run ahead of the sound); negative shows them earlier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Media controls")
            }  footer: {
                Text("Customize which controls appear in the music player. Volume expands when active.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accentColor(.effectiveAccent)
        .onReceive(MusicManager.shared.$isNowPlayingDeprecated.removeDuplicates()) { nowPlayingDeprecated = $0 }
    }

    // Only show controller options that are available on this macOS version
    private var availableMediaControllers: [MediaControllerType] {
        if nowPlayingDeprecated {
            return MediaControllerType.allCases.filter { $0 != .nowPlaying }
        } else {
            return MediaControllerType.allCases
        }
    }
}
