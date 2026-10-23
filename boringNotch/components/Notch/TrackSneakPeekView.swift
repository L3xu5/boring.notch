import Defaults
import SwiftUI

struct TrackSneakPeekView: View {
    @ObservedObject private var music = MusicManager.shared
    @Default(.playerColorTinting) private var tinting

    var body: some View {
        HStack {
            Image(systemName: "music.note").accessibilityHidden(true)
            GeometryReader { geometry in
                MarqueeText(
                    .constant("\(music.songTitle) — \(music.artistName)"),
                    textColor: tinting ? Color(nsColor: music.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray,
                    minDuration: 1, frameWidth: geometry.size.width
                )
            }
        }
        .foregroundStyle(.gray)
    }
}
