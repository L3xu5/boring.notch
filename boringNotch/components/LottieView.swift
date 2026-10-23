import Lottie
import SwiftUI

struct LottieView: NSViewRepresentable {
    let url: URL
    let speed: Double
    let loopMode: LottieLoopMode
    var isPlaying = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    final class Coordinator {
        var url: URL?
        var requestID = UUID()
        var speed: CGFloat = 1
        var loopMode: LottieLoopMode = .loop
        var shouldPlay = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView()
        view.backgroundBehavior = .pauseAndRestore
        return view
    }

    func updateNSView(_ view: LottieAnimationView, context: Context) {
        let state = context.coordinator
        state.speed = CGFloat(speed)
        state.loopMode = loopMode
        state.shouldPlay = isPlaying && !reduceMotion && speed > 0
        view.animationSpeed = state.speed
        view.loopMode = state.loopMode
        guard state.url != url else {
            applyPlayback(view, state: state)
            return
        }
        state.url = url
        state.requestID = UUID()
        let requestID = state.requestID
        view.stop()
        view.animation = nil
        LottieAnimation.loadedFrom(url: url) { [weak view, weak state] animation in
            DispatchQueue.main.async {
                guard let view, let state, state.requestID == requestID else { return }
                view.animation = animation
                view.animationSpeed = state.speed
                view.loopMode = state.loopMode
                if state.shouldPlay { view.play() } else { view.currentProgress = 0.5 }
            }
        }
    }

    private func applyPlayback(_ view: LottieAnimationView, state: Coordinator) {
        if state.shouldPlay {
            if !view.isAnimationPlaying { view.play() }
        } else {
            view.pause()
            if reduceMotion { view.currentProgress = 0.5 }
        }
    }

    static func dismantleNSView(_ view: LottieAnimationView, coordinator: Coordinator) {
        coordinator.requestID = UUID()
        coordinator.shouldPlay = false
        view.stop()
    }
}
