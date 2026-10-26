import Combine
import SwiftUI

// Interface-only manager fake for compiling the complete production favorite
// controls and HoverButton. These tests create no windows or player commands.
@MainActor final class MusicManager: ObservableObject {
    static let shared = MusicManager()
    @Published var canFavoriteTrack = true
    @Published var canDislikeTrack = true
    @Published var isFavoriteTrack = false
    @Published var isFavoriteStateKnown = false
    func toggleFavoriteTrack() {}
    func dislikeCurrentTrack() {}
}

@main private enum FavoritePresentationTests {
    private static var checks = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError(message) }
    }

    static func main() {
        for oldFavorite in [false, true] {
            let unknown = FavoriteControlPresentation(stateKnown: false, isFavorite: oldFavorite)
            expect(!unknown.isLiked && unknown.iconName == "heart", "Unknown state must never retain a filled heart")
            expect(unknown.actionLabel == "Toggle like", "Unknown state must describe a toggle, not a guessed target")
            expect(unknown.accessibilityValue == "Like status unavailable", "VoiceOver must not announce unknown as liked or unliked")
        }
        let liked = FavoriteControlPresentation(stateKnown: true, isFavorite: true)
        expect(liked.isLiked && liked.iconName == "heart.fill", "A confirmed like keeps its filled heart")
        expect(liked.actionLabel == "Unlike track", "A confirmed like describes the inverse action")
        expect(liked.accessibilityValue == "Liked", "A confirmed like remains accessible")
        let unliked = FavoriteControlPresentation(stateKnown: true, isFavorite: false)
        expect(!unliked.isLiked && unliked.iconName == "heart", "A confirmed unlike uses the outline heart")
        expect(unliked.actionLabel == "Like track", "A confirmed unlike describes the inverse action")
        expect(unliked.accessibilityValue == "Not liked", "A confirmed unlike remains accessible")
        print("Favorite presentation: \(checks) checks passed (whole production controls, no UI/player/data)")
    }
}
