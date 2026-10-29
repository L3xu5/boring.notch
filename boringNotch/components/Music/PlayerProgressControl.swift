import Defaults
import BoringCore
import SwiftUI

struct MusicSliderView: View {
    @Binding var sliderValue: Double
    @Binding var duration: Double
    @Binding var lastDragged: Date
    var color: NSColor
    @Binding var dragging: Bool
    let currentDate: Date
    let timestampDate: Date
    let elapsedTime: Double
    let playbackRate: Double
    let isPlaying: Bool
    var canSeek = true
    var onValueChange: (Double) -> Void


    var body: some View {
        VStack {
            CustomSlider(
                value: $sliderValue,
                range: 0...max(0, duration.isFinite ? duration : 0),
                color: Defaults[.sliderColor] == SliderColorEnum.albumArt
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.8)
                    : Defaults[.sliderColor] == SliderColorEnum.accent ? .effectiveAccent : .white,
                dragging: $dragging,
                lastDragged: $lastDragged,
                onValueChange: onValueChange,
                label: "Playback position",
                valueDescription: { "\(timeString(from: $0)) of \(timeString(from: duration))" }
            )
            .frame(height: 10, alignment: .center)
            .disabled(!canSeek)
            .help(canSeek ? "Seek in the current track" : "Seeking is unavailable for the current media session")

            HStack {
                Text(timeString(from: sliderValue))
                Spacer()
                Text(timeString(from: duration))
            }
            .fontWeight(.medium)
            .foregroundColor(
                Defaults[.playerColorTinting]
                    ? Color(nsColor: color).ensureMinimumBrightness(factor: 0.6) : .gray
            )
            .font(.caption)
        }
        .onChange(of: currentDate) {
            updatePosition()
        }
        .task(id: synchronization) {
            guard !dragging else { return }
            // A paused TimelineView has no next tick. Reconcile once the seek preview
            // expires even if the player rejects the seek or pauses during that grace.
            let delay = max(0, 1 - Date().timeIntervalSince(lastDragged))
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            updatePosition()
        }
    }

    private struct Synchronization: Equatable {
        let position: Double
        let duration: Double
        let timestamp: Date
        let rate: Double
        let playing: Bool
        let lastDragged: Date
        let dragging: Bool
    }

    private var synchronization: Synchronization {
        .init(position: elapsedTime, duration: duration, timestamp: timestampDate,
              rate: playbackRate, playing: isPlaying, lastDragged: lastDragged, dragging: dragging)
    }

    private func updatePosition() {
        guard !dragging, Date().timeIntervalSince(lastDragged) >= 1 else { return }
        sliderValue = MediaTimeline(position: elapsedTime, duration: duration, observedAt: timestampDate,
                                    rate: playbackRate, isPlaying: isPlaying).position(at: Date())
    }

    func timeString(from seconds: Double) -> String {
        let safeSeconds = seconds.isFinite ? min(max(seconds, 0), Double(Int.max / 2)) : 0
        let totalMinutes = Int(safeSeconds) / 60
        let remainingSeconds = Int(safeSeconds) % 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        } else {
            return String(format: "%d:%02d", minutes, remainingSeconds)
        }
    }
}

struct CustomSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var color: Color = .white
    @Binding var dragging: Bool
    @Binding var lastDragged: Date
    var onValueChange: ((Double) -> Void)?
    var onDragChange: ((Double) -> Void)?
    var label = "Value"
    var valueDescription: ((Double) -> String)?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = CGFloat(dragging ? 9 : 5)
            let rangeSpan = range.upperBound - range.lowerBound

            let finiteValue = value.isFinite ? value : range.lowerBound
            let progress = rangeSpan == .zero || !rangeSpan.isFinite ? 0 : (finiteValue - range.lowerBound) / rangeSpan
            let filledTrackWidth = min(max(progress, 0), 1) * width

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.gray.opacity(0.3))
                    .frame(height: height)

                Rectangle()
                    .fill(color)
                    .frame(width: filledTrackWidth, height: height)
            }
            .cornerRadius(height / 2)
            .frame(height: 10)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        withAnimation {
                            dragging = true
                        }
                        guard width > 0, rangeSpan.isFinite else { return }
                        let newValue = range.lowerBound + Double(gesture.location.x / width) * rangeSpan
                        value = min(max(newValue, range.lowerBound), range.upperBound)
                        onDragChange?(value)
                    }
                    .onEnded { _ in
                        onValueChange?(value)
                        dragging = false
                        lastDragged = Date()
                    }
            )
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.7), value: dragging)
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 4).stroke(Color.effectiveAccent, lineWidth: 2).padding(-3) }
            }
        }
        .focusable(isEnabled)
        .focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueDescription?(value) ?? percentageDescription)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
        .onKeyPress(.rightArrow) { adjust(1); return .handled }
        .onKeyPress(.leftArrow) { adjust(-1); return .handled }
        .onKeyPress(.upArrow) { adjust(1); return .handled }
        .onKeyPress(.downArrow) { adjust(-1); return .handled }
        .disabled(range.upperBound <= range.lowerBound)
    }

    private var percentageDescription: String {
        let span = range.upperBound - range.lowerBound
        let progress = span > 0 && span.isFinite && value.isFinite ? (value - range.lowerBound) / span : 0
        return "\(Int(min(max(progress, 0), 1) * 100)) percent"
    }

    private func adjust(_ direction: Double) {
        guard isEnabled else { return }
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0 else { return }
        let current = value.isFinite ? value : range.lowerBound
        value = min(max(current + direction * span / 100, range.lowerBound), range.upperBound)
        lastDragged = Date()
        onValueChange?(value)
    }
}
