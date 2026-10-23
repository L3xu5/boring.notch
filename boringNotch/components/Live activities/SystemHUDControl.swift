import SwiftUI

@MainActor
enum SystemHUDControl {
    static func title(for type: SneakContentType) -> String {
        switch type {
        case .volume: "System volume"
        case .brightness: "Display brightness"
        case .backlight: "Keyboard brightness"
        case .mic: "Microphone"
        default: "System control"
        }
    }

    static func setValue(_ value: CGFloat, for type: SneakContentType) {
        guard value.isFinite else { return }
        let normalized = Float(min(max(value, 0), 1))
        switch type {
        case .volume: VolumeManager.shared.setAbsolute(normalized)
        case .brightness: BrightnessManager.shared.setAbsolute(value: normalized)
        case .backlight: KeyboardBacklightManager.shared.setAbsolute(value: normalized)
        default: break
        }
    }
}
