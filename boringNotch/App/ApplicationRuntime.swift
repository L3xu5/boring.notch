import AppKit
import BoringCore
import Combine
import Defaults
import KeyboardShortcuts

/// Application-level ownership: services and subscriptions start once and stop together.
@MainActor
final class ApplicationRuntime {
    let windows = NotchWindowCoordinator()
    private var observations: [NotificationObservation] = []
    private var started = false
    private var onboarding: OnboardingWindowController?
    private let welcomePlayer = AudioPlayer()
    private lazy var mediaKeys = MediaTransportKeyMonitor(
        shouldRoute: { Defaults[.mediaController] == .yandexMusic },
        onAction: { action in
            if action == .playPause { MusicManager.shared.recoverUnresponsiveSystemPlayPause() }
        }
    )

    func start() {
        guard !started else { return }
        started = true
        FullscreenMediaDetector.shared.start()
        windows.start()
        mediaKeys.start()
        observe(.mediaControllerChanged) { [weak self] in self?.mediaKeys.refreshConfiguration() }
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), center: distributed) { [weak self] in
            self?.windows.setScreenLocked(true)
        }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { [weak self] in
            self?.windows.setScreenLocked(false)
        }
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.windows.setSleeping(true)
            FullscreenMediaDetector.shared.setSuspended(true)
        }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            FullscreenMediaDetector.shared.setSuspended(false)
            self?.windows.setSleeping(false)
            MusicManager.shared.forceUpdate()
            self?.mediaKeys.refreshConfiguration()
        }
        registerShortcuts()
        if BoringViewCoordinator.shared.firstLaunch {
            resumeOnboarding()
            welcomePlayer.play(fileName: "boring", fileExtension: "m4a")
        }
    }

    func resumeOnboarding() {
        if let onboarding { onboarding.present(); return }
        let controller = OnboardingWindowController { [weak self] in self?.onboarding = nil }
        onboarding = controller
        controller.present()
    }

    func open(_ view: NotchViews) {
        if BoringViewCoordinator.shared.firstLaunch { resumeOnboarding() }
        else { windows.open(view) }
    }

    func stop() {
        guard started else { return }
        started = false
        mediaKeys.stop()
        observations.forEach { $0.cancel() }
        observations.removeAll()
        KeyboardShortcuts.removeAllHandlers()
        onboarding?.close()
        onboarding = nil
        welcomePlayer.stop()
        windows.stop()
        FullscreenMediaDetector.shared.stop()
        WebcamManager.shared.stopSession()
        MusicManager.shared.destroy()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()
        NotchSpaceManager.shared.shutdown()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         action: @escaping @MainActor @Sendable () -> Void) {
        observations.append(NotificationObservation(center: center, name: name, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private func registerShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleSneakPeek) {
            let coordinator = BoringViewCoordinator.shared
            if Defaults[.sneakPeekStyles] == .inline {
                coordinator.toggleExpandingView(status: !coordinator.expandingView.show, type: .music)
            } else {
                coordinator.toggleSneakPeek(status: !coordinator.sneakPeek.show, type: .music, duration: 3)
            }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleNotchOpen) { [weak self] in
            guard let self else { return }
            if BoringViewCoordinator.shared.firstLaunch { self.resumeOnboarding() }
            else { self.windows.toggleFromKeyboard() }
        }
        KeyboardShortcuts.onKeyDown(for: .mediaPlayPause) { MusicManager.shared.togglePlay() }
        KeyboardShortcuts.onKeyDown(for: .mediaNextTrack) { MusicManager.shared.nextTrack() }
        KeyboardShortcuts.onKeyDown(for: .mediaPreviousTrack) { MusicManager.shared.previousTrack() }
        KeyboardShortcuts.onKeyDown(for: .mediaLike) { MusicManager.shared.toggleFavoriteTrack() }
        KeyboardShortcuts.onKeyDown(for: .mediaDislike) { MusicManager.shared.dislikeCurrentTrack() }
    }
}
