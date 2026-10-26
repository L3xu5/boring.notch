import Defaults
import SwiftUI

struct MusicControlsView: View {
    @ObservedObject var musicManager = MusicManager.shared
        @EnvironmentObject var vm: BoringViewModel
        @ObservedObject var webcamManager = WebcamManager.shared
    @State private var sliderValue: Double = 0
    @State private var dragging: Bool = false
    @State private var lastDragged: Date = .distantPast
    @Default(.musicControlSlots) private var slotConfig
    @Default(.musicControlSlotLimit) private var slotLimit

    var body: some View {
        VStack(alignment: .leading) {
            songInfoAndSlider
            slotToolbar
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var songInfoAndSlider: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 4) {
                songInfo(width: geo.size.width)
                musicSlider
            }
        }
        .padding(.top, 10)
        .padding(.leading, 5)
    }

    private func songInfo(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MarqueeText(
                .constant(musicManager.songTitle.isEmpty ? (musicManager.isPlaying ? "Now playing" : "No music playing") : musicManager.songTitle), font: .headline, nsFont: .headline, textColor: .white,
                frameWidth: width)
            MarqueeText(
                .constant(musicManager.artistName.isEmpty && musicManager.songTitle.isEmpty ? Defaults[.mediaController].rawValue : musicManager.artistName),
                font: .headline,
                nsFont: .headline,
                textColor: Defaults[.playerColorTinting]
                    ? Color(nsColor: musicManager.avgColor)
                        .ensureMinimumBrightness(factor: 0.6) : .gray,
                frameWidth: width
            )
            .fontWeight(.medium)
            if Defaults[.enableLyrics] && !musicManager.songTitle.isEmpty {
                TimelineView(.animation(minimumInterval: 0.25, paused: !musicManager.isPlaying)) { timeline in
                    let currentElapsed = musicManager.estimatedPlaybackPosition(at: timeline.date)
                    let line: String = {
                        if musicManager.isFetchingLyrics { return "Loading lyrics…" }
                        if !musicManager.syncedLyrics.isEmpty {
                            // Shift the lookup earlier by the user's offset so lines that run
                            // ahead of the audio (output latency, LRC timing) line up.
                            return musicManager.lyricLine(at: max(0, currentElapsed - Defaults[.lyricsOffset]))
                        }
                        let trimmed = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? "No lyrics found" : trimmed.replacingOccurrences(of: "\n", with: " ")
                    }()
                    let isPersian = line.unicodeScalars.contains { scalar in
                        let v = scalar.value
                        return v >= 0x0600 && v <= 0x06FF
                    }
                    MarqueeText(
                        .constant(line),
                        font: .subheadline,
                        nsFont: .subheadline,
                        textColor: musicManager.isFetchingLyrics ? .gray.opacity(0.7) : .gray,
                        frameWidth: width
                    )
                    .font(isPersian ? .custom("Vazirmatn-Regular", size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize) : .subheadline)
                    .lineLimit(1)
                    .opacity(musicManager.isPlaying ? 1 : 0)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var musicSlider: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !musicManager.isPlaying)) { timeline in
            MusicSliderView(
                sliderValue: $sliderValue,
                duration: $musicManager.songDuration,
                lastDragged: $lastDragged,
                color: musicManager.avgColor,
                dragging: $dragging,
                currentDate: timeline.date,
                timestampDate: musicManager.timestampDate,
                elapsedTime: musicManager.elapsedTime,
                playbackRate: musicManager.playbackRate,
                isPlaying: musicManager.isPlaying,
                canSeek: musicManager.canSeek
            ) { newValue in
                MusicManager.shared.seek(to: newValue)
            }
            .padding(.top, 5)
            .frame(height: 36)
        }
    }

    private var slotToolbar: some View {
        let slots = activeSlots
        return HStack(spacing: 6) {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                slotView(for: slot)
                    .frame(alignment: .center)
            }
            if !overflowSlots.isEmpty {
                Menu {
                    ForEach(Array(overflowSlots.enumerated()), id: \.offset) { _, slot in overflowAction(slot) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("More player controls")
                .help("More player controls")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var configuredSlots: [MusicControlButton] {
        let sanitizedLimit = min(
            max(slotLimit, MusicControlButton.minSlotCount),
            MusicControlButton.maxSlotCount
        )
        let padded = slotConfig.padded(to: sanitizedLimit, filler: .none)
        let result = Array(padded.prefix(sanitizedLimit))
        return result
    }

    private var compactLayout: Bool {
        Defaults[.showCalendar] && Defaults[.showMirror] && webcamManager.cameraAvailable && vm.isCameraExpanded && configuredSlots.count >= 5
    }

    private var activeSlots: [MusicControlButton] {
        compactLayout ? Array(configuredSlots.dropFirst().dropLast()) : configuredSlots
    }

    private var overflowSlots: [MusicControlButton] {
        guard compactLayout else { return [] }
        return [configuredSlots.first, configuredSlots.last].compactMap { $0 }.filter { $0 != .none }
    }

    @ViewBuilder
    private func overflowAction(_ slot: MusicControlButton) -> some View {
        switch slot {
        case .favorite:
            let presentation = FavoriteControlPresentation(stateKnown: musicManager.isFavoriteStateKnown,
                                                          isFavorite: musicManager.isFavoriteTrack)
            Button(LocalizedStringKey(presentation.actionLabel)) { musicManager.toggleFavoriteTrack() }
                .disabled(!musicManager.canFavoriteTrack)
                .accessibilityValue(Text(LocalizedStringKey(presentation.accessibilityValue)))
        case .dislike:
            Button("Dislike track") { musicManager.dislikeCurrentTrack() }.disabled(!musicManager.canDislikeTrack)
        case .playPause:
            Button(musicManager.isPlaying ? "Pause" : "Play") { musicManager.togglePlay() }
        case .previous:
            Button("Previous track") { musicManager.previousTrack() }
        case .next:
            Button("Next track") { musicManager.nextTrack() }
        case .shuffle:
            Button(musicManager.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On") { musicManager.toggleShuffle() }
                .disabled(!musicManager.mediaCapabilities.shuffle)
        case .repeatMode:
            Button("Change Repeat Mode") { musicManager.toggleRepeat() }
                .disabled(!musicManager.mediaCapabilities.repeatMode)
        case .goBackward:
            Button("Back 15 seconds") { musicManager.skip(seconds: -15) }.disabled(!musicManager.canSeek)
        case .goForward:
            Button("Forward 15 seconds") { musicManager.skip(seconds: 15) }.disabled(!musicManager.canSeek)
        case .volume:
            Menu("Player Volume") {
                Button("Volume Up") { musicManager.setVolume(to: min(musicManager.volume + 0.05, 1)) }
                Button("Volume Down") { musicManager.setVolume(to: max(musicManager.volume - 0.05, 0)) }
            }
            .disabled(!musicManager.volumeControlSupported)
        case .none: EmptyView()
        }
    }

    @ViewBuilder
    private func slotView(for slot: MusicControlButton) -> some View {
        switch slot {
        case .shuffle:
            HoverButton(icon: "shuffle", iconColor: musicManager.isShuffled ? .red : .primary, scale: .medium) {
                MusicManager.shared.toggleShuffle()
            }
            .accessibilityValue(musicManager.isShuffled ? "On" : "Off")
            .disabled(!musicManager.mediaCapabilities.shuffle)
        case .previous:
            HoverButton(icon: "backward.fill", scale: .medium) {
                MusicManager.shared.previousTrack()
            }
        case .playPause:
            HoverButton(icon: musicManager.isPlaying ? "pause.fill" : "play.fill", scale: .large, label: musicManager.isPlaying ? "Pause" : "Play") {
                MusicManager.shared.togglePlay()
            }
        case .next:
            HoverButton(icon: "forward.fill", scale: .medium) {
                MusicManager.shared.nextTrack()
            }
        case .repeatMode:
            HoverButton(icon: repeatIcon, iconColor: repeatIconColor, scale: .medium) {
                MusicManager.shared.toggleRepeat()
            }
            .accessibilityValue(musicManager.repeatMode == .off ? "Off" : musicManager.repeatMode == .one ? "Repeat one" : "Repeat all")
            .disabled(!musicManager.mediaCapabilities.repeatMode)
        case .volume:
            VolumeControlView()
        case .favorite:
            FavoriteControlButton()
        case .dislike:
            DislikeControlButton()
        case .goBackward:
            HoverButton(icon: "gobackward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: -15)
            }
            .disabled(!musicManager.canSeek)
        case .goForward:
            HoverButton(icon: "goforward.15", scale: .medium) {
                MusicManager.shared.skip(seconds: 15)
            }
            .disabled(!musicManager.canSeek)
        case .none:
            Color.clear.frame(height: 1)
        }
    }

    private var repeatIcon: String {
        switch musicManager.repeatMode {
        case .off:
            return "repeat"
        case .all:
            return "repeat"
        case .one:
            return "repeat.1"
        }
    }

    private var repeatIconColor: Color {
        switch musicManager.repeatMode {
        case .off:
            return .primary
        case .all, .one:
            return .red
        }
    }
}

private extension Array where Element == MusicControlButton {
    func padded(to length: Int, filler: MusicControlButton) -> [MusicControlButton] {
        if count >= length { return self }
        return self + Array(repeating: filler, count: length - count)
    }
}
