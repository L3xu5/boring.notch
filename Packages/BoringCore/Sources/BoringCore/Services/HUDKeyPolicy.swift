public enum HUDKeyDevice: Sendable, Equatable { case volume, screen, keyboard }
public enum HUDOptionKeyAction: Sendable { case openSettings, showHUD, ignore }
public struct HUDKeyCapabilities: Sendable {
    public var volume: Bool
    public var screen: Bool
    public var keyboard: Bool
    public init(volume: Bool, screen: Bool, keyboard: Bool) { self.volume = volume; self.screen = screen; self.keyboard = keyboard }
    public func supports(_ device: HUDKeyDevice) -> Bool {
        switch device { case .volume: volume; case .screen: screen; case .keyboard: keyboard }
    }
}
public enum HUDKeyAction: Sendable, Equatable {
    case adjustVolume(Float)
    case toggleMute
    case adjustBrightness(Float, keyboard: Bool)
    case openSettings(HUDKeyDevice)
    case showHUD(HUDKeyDevice)
}
public enum HUDKeyDecision: Sendable, Equatable { case passThrough, consume(HUDKeyAction?) }
public enum HUDKeyPolicy {
    public static func decide(code: Int, state: Int, isRepeat: Bool, option: Bool, shift: Bool, command: Bool,
                              control: Bool = false, enabled: Bool, capabilities: HUDKeyCapabilities, optionAction: HUDOptionKeyAction) -> HUDKeyDecision {
        guard enabled, !control, state == 0xA || state == 0xB else { return .passThrough }
        let device: HUDKeyDevice
        switch code {
        case 0, 1, 7: device = .volume
        case 2, 3: device = command ? .keyboard : .screen
        case 21, 22: device = .keyboard
        default: return .passThrough
        }
        guard capabilities.supports(device) else { return .passThrough }
        guard state == 0xA else { return .consume(nil) }
        if option && !shift {
            switch optionAction {
            case .openSettings: return .consume(.openSettings(device))
            case .showHUD: return .consume(.showHUD(device))
            case .ignore: return .consume(nil)
            }
        }
        let step: Float = option && shift ? 1 / 64 : 1 / 16
        switch code {
        case 0: return .consume(.adjustVolume(step))
        case 1: return .consume(.adjustVolume(-step))
        case 7: return .consume(isRepeat ? nil : .toggleMute)
        case 2, 21: return .consume(.adjustBrightness(step, keyboard: device == .keyboard))
        case 3, 22: return .consume(.adjustBrightness(-step, keyboard: device == .keyboard))
        default: return .passThrough
        }
    }
}
