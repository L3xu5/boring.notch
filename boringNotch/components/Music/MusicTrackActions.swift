import Defaults
import SwiftUI

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: iconName, iconColor: iconColor, scale: .medium, label: musicManager.isFavoriteTrack ? "Unlike track" : "Like track") {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
        .accessibilityValue(musicManager.isFavoriteTrack ? "Liked" : "Not liked")
    }

    private var iconName: String {
        musicManager.isFavoriteTrack ? "heart.fill" : "heart"
    }

    private var iconColor: Color {
        musicManager.isFavoriteTrack ? .red : .primary
    }
}

struct DislikeControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: "hand.thumbsdown", scale: .medium) {
            MusicManager.shared.dislikeCurrentTrack()
        }
        .disabled(!musicManager.canDislikeTrack)
        .opacity(musicManager.canDislikeTrack ? 1 : 0.35)
    }
}
