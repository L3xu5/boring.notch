import Foundation
import AppKit
import ApplicationServices
import Defaults
import AVFoundation
import Combine
import BoringCore

@MainActor
final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()
    private var context: HUDKeyTapContext?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var generation: UInt64 = 0
    private var audioPlayer: AVAudioPlayer?
    private init() {}

    func requestAccessibilityAuthorization() { XPCHelperClient.shared.requestAccessibilityAuthorization() }
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }
    func start(promptIfNeeded: Bool = false) async {
        guard Defaults[.hudReplacement] else { stop(); return }
        if promptIfNeeded && !AXIsProcessTrusted() { requestAccessibilityAuthorization() }
        if !started {
            started = true; generation &+= 1
            let epoch = generation
            context = HUDKeyTapContext { [weak self] action in
                Task { @MainActor in
                    guard let self, self.started, self.generation == epoch,
                          Defaults[.hudReplacement], AXIsProcessTrusted() else { return }
                    self.perform(action)
                }
            }
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshConfiguration() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            Defaults.publisher(.optionKeyAction).sink { [weak self] _ in Task { @MainActor in self?.refreshConfiguration() } }.store(in: &subscriptions)
            for publisher in [VolumeManager.shared.$isAvailable.eraseToAnyPublisher(),
                              BrightnessManager.shared.$isAvailable.eraseToAnyPublisher(),
                              KeyboardBacklightManager.shared.$isAvailable.eraseToAnyPublisher()] {
                publisher.sink { [weak self] _ in Task { @MainActor in self?.refreshConfiguration() } }.store(in: &subscriptions)
            }
        }
        refreshConfiguration()
    }
    func stop() {
        started = false; generation &+= 1
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        context?.shutdown(); context = nil
    }
    private func refreshConfiguration() {
        guard started else { return }
        let action: HUDOptionKeyAction
        switch Defaults[.optionKeyAction] {
        case .openSettings: action = .openSettings
        case .showHUD: action = .showHUD
        case .none: action = .ignore
        }
        context?.configure(enabled: Defaults[.hudReplacement] && AXIsProcessTrusted(),
            capabilities: HUDKeyCapabilities(volume: VolumeManager.shared.isAvailable,
                screen: BrightnessManager.shared.isAvailable, keyboard: KeyboardBacklightManager.shared.isAvailable),
            optionAction: action)
        context?.maintainTap()
    }
    private func perform(_ action: HUDKeyAction) {
        switch action {
        case .adjustVolume(let delta):
            playFeedbackSound()
            VolumeManager.shared.adjustRelative(delta: delta)
            BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(VolumeManager.shared.rawVolume))
        case .toggleMute: VolumeManager.shared.toggleMuteAction()
        case .adjustBrightness(let delta, let keyboard):
            if keyboard { KeyboardBacklightManager.shared.setRelative(delta: delta) }
            else { BrightnessManager.shared.setRelative(delta: delta) }
        case .showHUD(let device):
            switch device {
            case .volume: BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(VolumeManager.shared.rawVolume))
            case .screen: BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(BrightnessManager.shared.rawBrightness))
            case .keyboard: BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(KeyboardBacklightManager.shared.rawBrightness))
            }
        case .openSettings(let device):
            let section: String
            switch device { case .volume: section = "sound"; case .screen: section = "displays"; case .keyboard: section = "keyboard" }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference." + section) { NSWorkspace.shared.open(url) }
        }
    }
    private func playFeedbackSound() {
        guard UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["com.apple.sound.beep.feedback"] as? Int == 1 else { return }
        if audioPlayer == nil {
            let url = URL(fileURLWithPath: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff")
            audioPlayer = try? AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
        }
        audioPlayer?.stop(); audioPlayer?.currentTime = 0; audioPlayer?.play()
    }
    deinit { timer?.invalidate(); context?.shutdown() }
}

/// The callback does not wait for the UI actor, XPC, AX or disk IO. The worker retains the
/// context through its run loop; no unretained pointer to a destructible UI owner is used.
private final class HUDKeyTapContext: @unchecked Sendable {
    private let lock = NSLock()
    private let dispatchAction: @Sendable (HUDKeyAction) -> Void
    private var enabled = false
    private var capabilities = HUDKeyCapabilities(volume: false, screen: false, keyboard: false)
    private var optionAction = HUDOptionKeyAction.ignore
    private var stopped = false
    private var workerActive = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    init(dispatchAction: @escaping @Sendable (HUDKeyAction) -> Void) { self.dispatchAction = dispatchAction }
    func configure(enabled: Bool, capabilities: HUDKeyCapabilities, optionAction: HUDOptionKeyAction) {
        lock.withLock { self.enabled = enabled && !stopped; self.capabilities = capabilities; self.optionAction = optionAction }
    }
    func maintainTap() {
        let needsWorker = lock.withLock {
            guard enabled, !stopped, !workerActive else { return false }
            workerActive = true; return true
        }
        if needsWorker {
            let worker = Thread { [self] in run() }
            worker.name = "Boring Notch HUD keys"; worker.qualityOfService = .userInteractive; worker.start()
        } else { reenableTap() }
    }
    func shutdown() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in stopped = true; enabled = false; return (tap, runLoop) }
        if let tap = state.0 { CFMachPortInvalidate(tap) }
        if let loop = state.1 {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
            CFRunLoopWakeUp(loop)
        }
    }
    private func reenableTap() {
        let current = lock.withLock { enabled && !stopped ? tap : nil }
        if let current, CFMachPortIsValid(current), !CGEvent.tapIsEnabled(tap: current) { CGEvent.tapEnable(tap: current, enable: true) }
    }
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap(); return Unmanaged.passUnretained(event)
        }
        guard type == CGEventType(rawValue: 14), let key = NSEvent(cgEvent: event), key.subtype.rawValue == 8 else { return Unmanaged.passUnretained(event) }
        let settings = lock.withLock { (enabled && !stopped, capabilities, optionAction) }
        let flags = key.modifierFlags
        let decision = HUDKeyPolicy.decide(code: (key.data1 >> 16) & 0xFFFF, state: (key.data1 >> 8) & 0xFF,
            isRepeat: key.data1 & 1 == 1, option: flags.contains(.option), shift: flags.contains(.shift), command: flags.contains(.command),
            control: flags.contains(.control), enabled: settings.0, capabilities: settings.1, optionAction: settings.2)
        switch decision {
        case .passThrough: return Unmanaged.passUnretained(event)
        case .consume(let action): if let action { dispatchAction(action) }; return nil
        }
    }
    private func run() {
        defer { lock.withLock { tap = nil; runLoop = nil; workerActive = false } }
        guard !lock.withLock({ stopped }) else { return }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << 14, callback: { _, type, event, pointer in
                guard let pointer else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HUDKeyTapContext>.fromOpaque(pointer).takeUnretainedValue().handle(type: type, event: event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let mayRun = lock.withLock { () -> Bool in
            guard !stopped else { return false }; self.tap = tap; runLoop = loop; return true
        }
        guard mayRun else { CFMachPortInvalidate(tap); return }
        CFRunLoopAddSource(loop, source, .commonModes)
        reenableTap()
        withExtendedLifetime(self) { CFRunLoopRun() }
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(tap)
    }
}
