import Foundation

// Links the real coordinator and Core policy. Fixtures supply only player observations,
// selected-source state and command effects; recovery logic is never copied into this file.
enum FixtureMediaController { case yandexMusic, spotify }

enum Defaults {
    enum Key { case mediaController }
    static var selected = FixtureMediaController.yandexMusic
    static subscript(_ key: Key) -> FixtureMediaController {
        get { selected }
        set { selected = newValue }
    }
}

struct FixtureApplication { var bundleIdentifier: String }

final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: FixtureApplication? = .init(bundleIdentifier: "com.apple.TextEdit")
}

@MainActor
final class YandexMusicController {
    var systemMediaOwnerBundleIdentifier: String? = "com.apple.Safari"
    var systemMediaIsPlaying: Bool? = false
    var lastForeignMediaActivity: Date? = Date().addingTimeInterval(-30)
    var accessibilityIsPlaying: Bool? = true
    var accessibilityMetadataLastReadAt: Date? = Date()
    var refreshProvidesNewRead = true
    var afterRefresh: (() -> Void)?
    var refreshCount = 0
    var toggleCount = 0
    var acceptToggle = true

    func refreshAccessibilityMetadata() async {
        refreshCount += 1
        if refreshProvidesNewRead { accessibilityMetadataLastReadAt = Date() }
        afterRefresh?()
    }

    func togglePlayWithReceipt() async -> Bool {
        toggleCount += 1
        guard acceptToggle else { return false }
        accessibilityIsPlaying = accessibilityIsPlaying.map { !$0 }
        accessibilityMetadataLastReadAt = Date()
        return true
    }
}

@MainActor
final class MusicManager {
    var activeController: AnyObject?
    private var coordinator: MediaKeyRecoveryCoordinator!
    init(controller: YandexMusicController) {
        activeController = controller
        coordinator = MediaKeyRecoveryCoordinator(snapshot: { [weak controller] in
            .init(systemOwner: controller?.systemMediaOwnerBundleIdentifier,
                  systemIsPlaying: controller?.systemMediaIsPlaying, foreignActivity: controller?.lastForeignMediaActivity,
                  yandexIsPlaying: controller?.accessibilityIsPlaying,
                  accessibilityObservedAt: controller?.accessibilityMetadataLastReadAt,
                  foregroundApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, capturedAt: Date())
        }, refresh: { [weak controller] in await controller?.refreshAccessibilityMetadata() },
           toggle: { [weak controller] in await controller?.togglePlayWithReceipt() ?? false }, isActive: { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.activeController === controller && Defaults[.mediaController] == .yandexMusic
        })
    }
    func cancelForTest() { coordinator.stop() }
    func recoverUnresponsiveSystemPlayPause() { coordinator.handlePlayPause() }
}

@main
@MainActor
struct MediaKeyRecoveryCoordinatorTests {
    static var checks = 0

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func wait(_ milliseconds: Int = 1650) async {
        try! await Task.sleep(for: .milliseconds(milliseconds))
    }

    static func resetEnvironment() {
        Defaults[.mediaController] = .yandexMusic
        NSWorkspace.shared.frontmostApplication = .init(bundleIdentifier: "com.apple.TextEdit")
    }

    static func fixture() -> (MusicManager, YandexMusicController) {
        resetEnvironment()
        let controller = YandexMusicController()
        return (MusicManager(controller: controller), controller)
    }

    static func main() async {
        let started = Date()

        // This must arm the real coordinator. In particular it catches checking
        // a snapshot against a Date captured just before snapshot.capturedAt.
        do {
            let (manager, controller) = fixture()
            let firstPress = Date()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            require(controller.toggleCount == 0, "macOS receives a native response window before fallback")
            await wait(1450)
            require(controller.refreshCount == 1, "fallback obtains one new AX observation after the key")
            require(controller.toggleCount == 1, "a proven stale paused Safari session gets exactly one Yandex fallback")
            require(controller.accessibilityIsPlaying == false, "first fallback pauses Yandex")
            require(controller.systemMediaOwnerBundleIdentifier == "com.apple.Safari" && controller.systemMediaIsPlaying == false,
                    "fallback never changes the foreign native session")
            require(Date().timeIntervalSince(firstPress) >= 1.2, "the production 1.2-second grace is preserved")
            await wait(1500)
            manager.recoverUnresponsiveSystemPlayPause()
            await wait()
            require(controller.toggleCount == 2, "the next key resumes recovered paused Yandex using the recorded proof")
            require(controller.accessibilityIsPlaying == true, "the follow-up recovery resumes Yandex")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            controller.systemMediaIsPlaying = true
            controller.lastForeignMediaActivity = Date()
            await wait(1450)
            require(controller.toggleCount == 0, "Safari's native playback response leaves Yandex untouched")
            require(controller.systemMediaIsPlaying == true, "the coordinator does not undo Safari's response")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            NSWorkspace.shared.frontmostApplication = .init(bundleIdentifier: "com.apple.Safari")
            manager.recoverUnresponsiveSystemPlayPause()
            await wait()
            require(controller.toggleCount == 0 && controller.refreshCount == 0,
                    "focused Safari never arms a recovery")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            NSWorkspace.shared.frontmostApplication = .init(bundleIdentifier: "com.apple.Safari")
            await wait(1450)
            require(controller.toggleCount == 0, "focusing Safari during the native response cancels recovery")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            Defaults[.mediaController] = .spotify
            await wait(1450)
            require(controller.toggleCount == 0 && controller.refreshCount == 0,
                    "a source change cancels pending recovery before AX refresh")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            let replacement = YandexMusicController()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            manager.activeController = replacement
            await wait(1450)
            require(controller.toggleCount == 0 && replacement.toggleCount == 0,
                    "replacing the controller cancels pending recovery")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(200)
            manager.recoverUnresponsiveSystemPlayPause()
            await wait(1450)
            require(controller.toggleCount == 0 && controller.refreshCount == 0,
                    "rapid double presses cancel the first fallback and do not arm another")
            manager.cancelForTest()
        }

        do {
            let (manager, controller) = fixture()
            controller.acceptToggle = false
            manager.recoverUnresponsiveSystemPlayPause()
            await wait()
            require(controller.toggleCount == 1, "the first proven candidate reaches the controller")
            controller.accessibilityIsPlaying = false
            controller.accessibilityMetadataLastReadAt = Date()
            await wait(1500)
            controller.acceptToggle = true
            manager.recoverUnresponsiveSystemPlayPause()
            await wait()
            require(controller.toggleCount == 1, "a dropped AX command must not fabricate recent-recovery proof for paused background Yandex")
            manager.cancelForTest()
        }

        // These independent coordinators share a stable fake environment, so
        // their negative response windows can run concurrently.
        do {
            resetEnvironment()
            let unknown = YandexMusicController()
            unknown.accessibilityIsPlaying = nil
            let missingRead = YandexMusicController()
            missingRead.refreshProvidesNewRead = false
            let disappearedState = YandexMusicController()
            disappearedState.afterRefresh = { [weak disappearedState] in disappearedState?.accessibilityIsPlaying = nil }
            let canceled = YandexMusicController()
            let managers = [unknown, missingRead, disappearedState, canceled].map { MusicManager(controller: $0) }
            managers.forEach { $0.recoverUnresponsiveSystemPlayPause() }
            await wait(200)
            managers[3].cancelForTest()
            await wait(1450)
            require(unknown.toggleCount == 0 && unknown.refreshCount == 0,
                    "unknown initial AX state cannot arm recovery")
            require(missingRead.toggleCount == 0 && missingRead.refreshCount == 1,
                    "a cached AX result cannot stand in for a new post-key read")
            require(disappearedState.toggleCount == 0 && disappearedState.refreshCount == 1,
                    "unknown state after refresh cannot trigger recovery")
            require(canceled.toggleCount == 0 && canceled.refreshCount == 0,
                    "explicit cancellation prevents later playback control")
            managers.forEach { $0.cancelForTest() }
        }

        print("Media-key coordinator: \(checks) checks passed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s (production grace; no real AX, player or key events)")
    }
}
