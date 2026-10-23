    //
    //  SystemEventIndicatorModifier.swift
    //  boringNotch
    //
    //  Created by Richard Kunkli on 12/08/2024.
    //

import SwiftUI
import Defaults

struct SystemEventIndicatorModifier: View {
    @Binding var eventType: SneakContentType
    @Binding var value: CGFloat
    @Binding var icon: String
    let showSlider: Bool = false
    var sendEventBack: (CGFloat) -> Void
    
    var body: some View {
        HStack(spacing: 14) {
            switch (eventType) {
                case .volume:
                    if icon.isEmpty {
                        Image(systemName: SpeakerSymbol(value))
                            .contentTransition(.interpolate)
                            .symbolVariant(value > 0 ? .none : .slash)
                            .frame(width: 20, height: 15, alignment: .leading)
                    } else {
                        Image(systemName: icon)
                            .contentTransition(.interpolate)
                            .opacity(value.isZero ? 0.6 : 1)
                            .scaleEffect(value.isZero ? 0.85 : 1)
                            .frame(width: 20, height: 15, alignment: .leading)
                    }
                case .brightness:
                    Image(systemName: "sun.max.fill")
                        .contentTransition(.symbolEffect)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .backlight:
                    Image(systemName: value > 0.5 ? "light.max" : "light.min")
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                case .mic:
                    Image(systemName: "mic")
                        .symbolVariant(value > 0 ? .none : .slash)
                        .contentTransition(.interpolate)
                        .frame(width: 20, height: 15)
                        .foregroundStyle(.white)
                default:
                    EmptyView()
            }
            if (eventType != .mic) {
                DraggableProgressBar(value: $value, onChange: sendEventBack, label: SystemHUDControl.title(for: eventType))
                if Defaults[.showClosedNotchHUDPercentage] {
                    Text("\(Int(value * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)
                }
            } else {
                Text("Mic \(value > 0 ? "unmuted" : "muted")")
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .allowsTightening(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .symbolVariant(.fill)
        .imageScale(.large)
    }
    
    func SpeakerSymbol(_ value: CGFloat) -> String {
        switch(value) {
            case 0:
                return "speaker.slash"
            case 0...0.3:
                return "speaker.wave.1"
            case 0.3...0.8:
                return "speaker.wave.2"
            case 0.8...1:
                return "speaker.wave.3"
            default:
                return "speaker.wave.2"
        }
    }
}

struct DraggableProgressBar: View {
    @Binding var value: CGFloat
    var onChange: ((CGFloat) -> Void)? = nil
    var label = "System value"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    
    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.tertiary)
                    Capsule()
                        .fill(
                            Defaults[.enableGradient] ?
                                AnyShapeStyle(LinearGradient(
                                    colors: Defaults[.systemEventIndicatorUseAccent] ?
                                        [Color.effectiveAccent, Color.effectiveAccent.ensureMinimumBrightness(factor: 0.2)] :
                                        [Color.white, Color.white.opacity(0.2)],
                                    startPoint: .trailing,
                                    endPoint: .leading
                                )) :
                                AnyShapeStyle(Defaults[.systemEventIndicatorUseAccent] ? Color.effectiveAccent : Color.white)
                        )
                        .frame(width: max(0, min(geo.size.width * value, geo.size.width)))
                        .shadow(color: Defaults[.systemEventIndicatorShadow] ?
                            (Defaults[.systemEventIndicatorUseAccent] ?
                                Color.effectiveAccent.ensureMinimumBrightness(factor: 0.7) :
                                Color.white) :
                            Color.clear,
                            radius: 8, x: 3)
                        .opacity(value.isZero ? 0 : 1)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                isDragging = true
                                updateValue(gesture: gesture, in: geo)
                            }
                        }
                        .onEnded { _ in
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
                                isDragging = false
                            }
                        }
                )
            }
            .frame(height: Defaults[.inlineHUD] ? isDragging ? 8 : 5 : isDragging ? 9 : 6)
            .overlay {
                if focused { RoundedRectangle(cornerRadius: 4).stroke(Color.effectiveAccent, lineWidth: 2).padding(-3) }
            }
        }
        .focusable().focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value.isFinite ? min(max(value, 0), 1) : 0) * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: setValue(value + 0.05)
            case .decrement: setValue(value - 0.05)
            @unknown default: break
            }
        }
        .onKeyPress(.rightArrow) { setValue(value + 0.05); return .handled }
        .onKeyPress(.leftArrow) { setValue(value - 0.05); return .handled }
        .onKeyPress(.upArrow) { setValue(value + 0.05); return .handled }
        .onKeyPress(.downArrow) { setValue(value - 0.05); return .handled }
    }
    
    private func updateValue(gesture: DragGesture.Value, in geometry: GeometryProxy) {
        guard geometry.size.width > 0 else { return }
        let dragPosition = gesture.location.x
        let newValue = dragPosition / geometry.size.width
        
        setValue(newValue)
    }

    private func setValue(_ newValue: CGFloat) {
        guard newValue.isFinite else { return }
        value = max(0, min(newValue, 1))
        onChange?(value)
    }
}
