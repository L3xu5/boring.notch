import Defaults
import SwiftUI

/// Unknown selection does not disable a player's available toggle action.
struct FavoriteControlPresentation {
    var stateKnown: Bool
    var isFavorite: Bool

    var isLiked: Bool { stateKnown && isFavorite }
    var iconName: String { isLiked ? "heart.fill" : "heart" }
    var actionLabel: String { stateKnown ? (isLiked ? "Unlike track" : "Like track") : "Toggle like" }
    var accessibilityValue: String { stateKnown ? (isLiked ? "Liked" : "Not liked") : "Like status unavailable" }
}

struct FavoriteControlButton: View {
    @ObservedObject var musicManager = MusicManager.shared

    var body: some View {
        HoverButton(icon: presentation.iconName, iconColor: presentation.isLiked ? .red : .primary, scale: .medium, label: presentation.actionLabel) {
            MusicManager.shared.toggleFavoriteTrack()
        }
        .disabled(!musicManager.canFavoriteTrack)
        .opacity(musicManager.canFavoriteTrack ? 1 : 0.35)
        .accessibilityLabel(Text(LocalizedStringKey(presentation.actionLabel)))
        .accessibilityValue(Text(LocalizedStringKey(presentation.accessibilityValue)))
        .help(Text(LocalizedStringKey(presentation.actionLabel)))
    }

    private var presentation: FavoriteControlPresentation {
        .init(stateKnown: musicManager.isFavoriteStateKnown, isFavorite: musicManager.isFavoriteTrack)
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
