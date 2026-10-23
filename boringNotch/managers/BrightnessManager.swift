import AppKit
import BoringCore

private struct ScreenBrightnessBackend: ScalarHardwareBackend {
    func read() async -> Float? { await XPCHelperClient.shared.currentScreenBrightness() }
    func write(_ value: Float) async -> Bool { await XPCHelperClient.shared.setScreenBrightness(value) }
}
private struct KeyboardBrightnessBackend: ScalarHardwareBackend {
    func read() async -> Float? { await XPCHelperClient.shared.currentKeyboardBrightness() }
    func write(_ value: Float) async -> Bool { await XPCHelperClient.shared.setKeyboardBrightness(value) }
}

@MainActor
final class BrightnessManager: ObservableObject {
    static let shared = BrightnessManager()
    @Published private(set) var rawBrightness: Float = 0
    @Published private(set) var animatedBrightness: Float = 0
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var isAvailable = false
    private lazy var controller = ScalarHardwareController(backend: ScreenBrightnessBackend()) { [weak self] update in
        Task { @MainActor in self?.publish(update) }
    }
    private init() { refresh() }
    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < 1.2 }
    func refresh() { Task { await controller.submit(.refresh) } }
    func setRelative(delta: Float) { Task { await controller.submit(.relative(delta)) } }
    func setAbsolute(value: Float) { Task { await controller.submit(.absolute(value)) } }
    private func publish(_ update: ScalarHardwareUpdate) {
        isAvailable = update.value != nil
        guard let value = update.value else { return }
        rawBrightness = value; animatedBrightness = value
        if update.changedByUser {
            lastChangeAt = Date()
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(value))
        }
    }
}

@MainActor
final class KeyboardBacklightManager: ObservableObject {
    static let shared = KeyboardBacklightManager()
    @Published private(set) var rawBrightness: Float = 0
    @Published private(set) var lastChangeAt: Date = .distantPast
    @Published private(set) var isAvailable = false
    private lazy var controller = ScalarHardwareController(backend: KeyboardBrightnessBackend()) { [weak self] update in
        Task { @MainActor in self?.publish(update) }
    }
    private init() { refresh() }
    var shouldShowOverlay: Bool { Date().timeIntervalSince(lastChangeAt) < 1.2 }
    func refresh() { Task { await controller.submit(.refresh) } }
    func setRelative(delta: Float) { Task { await controller.submit(.relative(delta)) } }
    func setAbsolute(value: Float) { Task { await controller.submit(.absolute(value)) } }
    private func publish(_ update: ScalarHardwareUpdate) {
        isAvailable = update.value != nil
        guard let value = update.value else { return }
        rawBrightness = value
        if update.changedByUser {
            lastChangeAt = Date()
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(value))
        }
    }
}
