import AppKit
import Combine
import Defaults
import Foundation
import SwiftUI

// Interface fakes only. The runner compiles the complete, unmodified production
// BoringViewModel.swift. UI and hardware boundaries cannot touch real devices,
// permissions, windows, or the installed app's preferences, even on regression.
enum NotchState { case open, closed }
enum NotchViews { case home, shelf, lyrics }
enum ContentType { case normal, menu, settings }
enum HideNotchOption { case never, always, nowPlayingOnly }

extension Defaults.Keys {
    static let showMirror = Defaults.Key<Bool>("showMirror", default: true)
    static let boringShelf = Defaults.Key<Bool>("boringShelf", default: false)
    static let openShelfByDefault = Defaults.Key<Bool>("openShelfByDefault", default: false)
    static let hideTitleBar = Defaults.Key<Bool>("hideTitleBar", default: true)
    static let hideNotchOption = Defaults.Key<HideNotchOption>("hideNotchOption", default: .never)
}

@MainActor final class BoringViewCoordinator: ObservableObject {
    static let shared = BoringViewCoordinator()
    @Published var openLastTabByDefault = false
    @Published var helloAnimationRunning = false
}
@MainActor final class FullscreenMediaDetector: ObservableObject {
    static let shared = FullscreenMediaDetector()
    @Published var fullscreenStatus: [String: Bool] = [:]
}
final class BoringAnimations { var animation: Animation { .linear(duration: 0) } }
@MainActor final class MusicManager {
    static let shared = MusicManager()
    var updates = 0
    func forceUpdate() { updates += 1 }
}
final class SharingStateManager {
    static let shared = SharingStateManager()
    var preventNotchClose = false
}
final class ShelfStateViewModel {
    static let shared = ShelfStateViewModel()
    var isEmpty = true
}

struct FixtureScreen {
    var safeAreaInsets = NSEdgeInsets(top: 32, left: 0, bottom: 0, right: 0)
    var frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    var visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 868)
}
enum NSScreen { static func screen(withUUID: String) -> FixtureScreen? { FixtureScreen() } }
enum NSEvent { static var mouseLocation = NSPoint(x: 720, y: 900) }
let openNotchSize = CGSize(width: 640, height: 190)
func getClosedNotchSize(screenUUID: String? = nil) -> CGSize { CGSize(width: 185, height: 32) }
func getScreenFrame(_ uuid: String?) -> CGRect? { FixtureScreen().frame }

@MainActor enum PlatformEffects {
    static var alerts = 0
    static var activations = 0
    static var externalURLs = 0
}
final class FixtureWindow {}
@MainActor enum ApplicationActivationPolicy { static func restore(excluding: FixtureWindow? = nil) {} }
@MainActor enum NSApp {
    @discardableResult static func setActivationPolicy(_ value: NSApplication.ActivationPolicy) -> Bool {
        PlatformEffects.activations += 1
        return true
    }
    static func activate(ignoringOtherApps: Bool) { PlatformEffects.activations += 1 }
}
@MainActor final class NSAlert {
    var messageText = ""
    var informativeText = ""
    let window = FixtureWindow()
    func addButton(withTitle: String) {}
    func runModal() -> NSApplication.ModalResponse {
        PlatformEffects.alerts += 1
        return .alertSecondButtonReturn
    }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    @discardableResult func open(_ url: URL) -> Bool { PlatformEffects.externalURLs += 1; return false }
}
// Future direct SDK calls must fail compilation rather than bypass the fixture camera.
enum AVCaptureDevice {}
enum AVCaptureSession {}
enum FixtureAuthorizationStatus { case authorized, denied, restricted, notDetermined, future }

@MainActor final class WebcamManager: ObservableObject {
    static var shared = WebcamManager()
    @Published var authorizationStatus = FixtureAuthorizationStatus.authorized
    var isSessionRunning = true // Another display already owns a visible preview.
    var cameraAvailable = true
    var startRequests = 0
    var stopRequests = 0
    var authorizationRequests = 0
    func startSession() { startRequests += 1; isSessionRunning = true }
    func stopSession() { stopRequests += 1; isSessionRunning = false }
    func checkAndRequestVideoAuthorization() { authorizationRequests += 1 }
}

@main
@MainActor
struct CameraPresentationTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func drainCallbacks() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }

    static func main() {
        Defaults[.showMirror] = true
        let webcam = WebcamManager()
        WebcamManager.shared = webcam
        let first = BoringViewModel()
        let second = BoringViewModel()
        first.open(); second.open()
        require(!first.preventsAutomaticClose && !second.preventsAutomaticClose,
                "idle displays allow automatic closure")
        first.isScrubbingMusic = true
        require(first.preventsAutomaticClose && !second.preventsAutomaticClose,
                "music scrubbing prevents automatic closure only on its own display")
        first.keyboardInteractionActive = true
        first.isScrubbingMusic = false
        require(first.preventsAutomaticClose, "ending scrubbing retains an independent keyboard interaction")
        first.keyboardInteractionActive = false
        require(!first.preventsAutomaticClose, "ending the last interaction allows automatic closure again")
        first.isScrubbingMusic = true
        first.close()
        require(first.notchState == .closed && !first.isScrubbingMusic,
                "manual close remains available during scrubbing and clears its transient state")
        first.open()
        let destroyedInteraction = BoringViewModel()
        destroyedInteraction.isScrubbingMusic = true
        destroyedInteraction.destroy()
        require(!destroyedInteraction.isScrubbingMusic && !destroyedInteraction.preventsAutomaticClose,
                "destroying a display releases its scrubbing hold")
        first.toggleCameraPreview()
        require(first.isCameraExpanded, "opening a local preview works when another display is capturing")
        require(webcam.startRequests == 1 && webcam.stopRequests == 0, "expand requests running without toggling global state")
        second.toggleCameraPreview()
        require(first.isCameraPreviewVisible && second.isCameraPreviewVisible, "two open displays may each present their own consumer")
        first.toggleCameraPreview()
        require(!first.isCameraPreviewVisible && second.isCameraPreviewVisible, "hiding one preview leaves the other visible")
        require(webcam.stopRequests == 0, "hiding a preview does not globally stop capture")
        first.toggleCameraPreview()
        first.close()
        require(!first.isCameraExpanded && !first.isCameraPreviewVisible, "closing clears expansion and camera presentation")
        require(second.isCameraExpanded && webcam.stopRequests == 0, "closing one display does not stop another")
        second.destroy()
        require(!second.isCameraExpanded && !second.isCameraPreviewVisible, "destroying a display clears camera presentation")
        require(webcam.stopRequests == 0, "the consumer/backend decides when the last capture stops")

        let hidden = BoringViewModel()
        hidden.isCameraExpanded = true
        require(!hidden.isCameraPreviewVisible, "a stale expanded flag cannot present a closed camera")
        hidden.isCameraExpanded = false
        let previousStarts = webcam.startRequests
        hidden.toggleCameraPreview()
        require(!hidden.isCameraExpanded && webcam.startRequests == previousStarts, "closed UI cannot request expansion")

        let pendingWebcam = WebcamManager()
        pendingWebcam.authorizationStatus = .notDetermined
        WebcamManager.shared = pendingWebcam
        let pending = BoringViewModel()
        pending.open()
        pending.toggleCameraPreview(); pending.toggleCameraPreview()
        require(pending.isRequestingAuthorization && pendingWebcam.authorizationRequests == 1, "pending permission is not requested twice")
        pending.close()
        pendingWebcam.authorizationStatus = .authorized
        drainCallbacks()
        require(!pending.isCameraExpanded && pendingWebcam.startRequests == 0, "late permission cannot reopen closed UI")

        let grantedWebcam = WebcamManager()
        grantedWebcam.authorizationStatus = .notDetermined
        WebcamManager.shared = grantedWebcam
        let granted = BoringViewModel()
        granted.open(); granted.toggleCameraPreview()
        grantedWebcam.authorizationStatus = .authorized
        drainCallbacks()
        require(granted.isCameraExpanded && !granted.isRequestingAuthorization && grantedWebcam.startRequests == 1,
                "permission completes only the still-visible local request")
        Defaults[.showMirror] = false
        require(!granted.isCameraPreviewVisible, "disabling the feature removes presentation")
        granted.toggleCameraPreview()
        granted.toggleCameraPreview()
        require(!granted.isCameraExpanded && grantedWebcam.startRequests == 1, "a disabled feature cannot request expansion")
        Defaults[.showMirror] = true
        granted.toggleCameraPreview()
        grantedWebcam.cameraAvailable = false
        require(!granted.isCameraPreviewVisible, "an unavailable device removes presentation")
        granted.destroy(); hidden.destroy(); pending.destroy(); first.destroy()

        weak var released: BoringViewModel?
        autoreleasepool {
            let transient = BoringViewModel()
            released = transient
        }
        drainCallbacks()
        require(released == nil, "the actual VM deallocates without a Combine subscription retain cycle")
        require(!hidden.isMouseHovering(position: NSPoint(x: 720, y: 901)), "a vertically adjacent display cannot hover this notch")
        require(PlatformEffects.alerts == 0 && PlatformEffects.activations == 0 && PlatformEffects.externalURLs == 0,
                "no platform UI was requested by the production methods")
        print("Camera/VM presentation: \(checks) checks passed (whole production source; interface fakes only)")
    }
}
