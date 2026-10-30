import Defaults
import SwiftUI

struct LyricsKaraokeView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var musicManager = MusicManager.shared
    @Default(.lyricsOffset) private var lyricsOffset
    @State private var followPlayback = true

    var body: some View {
        Group {
            if musicManager.syncedLyrics.isEmpty, !musicManager.currentLyrics.isEmpty {
                ScrollView {
                    Text(musicManager.currentLyrics)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
            } else if musicManager.syncedLyrics.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "quote.bubble")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(musicManager.lyricsStatusMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if musicManager.lyricsNeedConnection {
                        Button("Connect Yandex Music") { YandexAuthWindowController.shared.present() }
                            .buttonStyle(.borderless)
                    } else if musicManager.lyricsAvailability == .temporarilyUnavailable {
                        Button("Retry") { musicManager.reloadLyricsForCurrentTrack() }
                            .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // If synced lyrics aren't available, don't strand the user on an empty tab.
                .overlay(alignment: .bottom) {
                    Button("Back to player") { vm.currentView = .home }.buttonStyle(.borderless)
                }
            } else {
                karaoke
            }
        }
        .frame(height: 130)
        .overlay(alignment: .topTrailing) {
            if !musicManager.syncedLyrics.isEmpty {
                Button { followPlayback.toggle() } label: {
                    Label(followPlayback ? "Following" : "Follow", systemImage: followPlayback ? "location.fill" : "location")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(6)
                .background(.black.opacity(0.9), in: Capsule())
                .padding(4)
                .accessibilityLabel("Follow current lyric")
                .accessibilityValue(followPlayback ? "On" : "Off")
                .help("Turn off to browse lyrics without automatic scrolling")
            }
        }
    }

    private var karaoke: some View {
        TimelineView(.animation(minimumInterval: 0.2, paused: !musicManager.isPlaying)) { timeline in
            let pos = max(0, musicManager.estimatedPlaybackPosition(at: timeline.date) - lyricsOffset)
            let current = currentIndex(at: pos)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(musicManager.syncedLyrics.enumerated()), id: \.offset) { idx, line in
                            Button { musicManager.seek(to: line.time) } label: {
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.system(size: idx == current ? 16 : 13,
                                               weight: idx == current ? .semibold : .regular))
                                .foregroundStyle(idx == current ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .id(idx)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(line.text.isEmpty ? "Instrumental" : line.text)
                            .accessibilityHint("Seek to this line")
                            .disabled(!musicManager.canSeek)
                            .help(musicManager.canSeek ? "Seek to this line" : "Seeking is unavailable for the current media session")
                            .accessibilityAddTraits(idx == current ? .isSelected : [])
                            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: current)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 48)
                }
                .onChange(of: current) { _, new in
                    guard followPlayback else { return }
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { proxy.scrollTo(new, anchor: .center) }
                }
                .onChange(of: followPlayback) { _, enabled in
                    if enabled { withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { proxy.scrollTo(current, anchor: .center) } }
                }
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }

    private func currentIndex(at pos: Double) -> Int {
        let lines = musicManager.syncedLyrics
        guard !lines.isEmpty else { return 0 }
        if pos < lines[0].time { return 0 }
        var low = 0, high = lines.count - 1, idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= pos { idx = mid; low = mid + 1 } else { high = mid - 1 }
        }
        return idx
    }
}
