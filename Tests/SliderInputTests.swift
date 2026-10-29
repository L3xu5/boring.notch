import AppKit
import Defaults
import SwiftUI

// Interface fakes only. The runner compiles the entire production progress
// control, hosting view and ancestor pan gestures. There is no app runtime,
// account store, media command, event tap, global input or persisted preference.
enum SliderColorEnum { case albumArt, accent, white }
extension Defaults.Keys {
    static let sliderColor = Defaults.Key<SliderColorEnum>("sliderColor", default: .white)
    static let playerColorTinting = Defaults.Key<Bool>("playerColorTinting", default: false)
}
extension Color {
    static var effectiveAccent: Color { .blue }
    func ensureMinimumBrightness(factor: CGFloat) -> Color { self }
}
@MainActor private final class SliderState: ObservableObject {
    @Published var value = 10.0
    @Published var dragging = false
    @Published var lastDragged = Date.distantPast
    @Published var enabled = true
    @Published var duration = 100.0
    var commits: [Double] = []
    var changes: [Double] = []
    var ancestorActions = 0
}

@MainActor private final class ProgressState: ObservableObject {
    @Published var value = 0.0
    @Published var duration = 180.0
    @Published var dragging = false
    @Published var lastDragged = Date.distantPast
    @Published var tick = Date()
    @Published var timestamp = Date()
    @Published var elapsed = 40.0
    @Published var rate = 1.0
    @Published var playing = true
    var commands = 0
}

private struct ProgressFixture: View {
    @ObservedObject var state: ProgressState
    var body: some View {
        MusicSliderView(sliderValue: $state.value, duration: $state.duration,
                        lastDragged: $state.lastDragged, color: .white, dragging: $state.dragging,
                        currentDate: state.tick, timestampDate: state.timestamp,
                        elapsedTime: state.elapsed, playbackRate: state.rate, isPlaying: state.playing) { _ in
            state.commands += 1
        }
        .frame(width: 200, height: 60)
    }
}

private struct SliderFixture: View {
    @ObservedObject var state: SliderState

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            CustomSlider(
                value: $state.value, range: 0...state.duration,
                dragging: $state.dragging, lastDragged: $state.lastDragged,
                onValueChange: { state.commits.append($0) },
                onDragChange: { state.changes.append($0) }
            )
            .frame(width: 200, height: 10)
            .disabled(!state.enabled)
            Spacer(minLength: 0)
        }
        .frame(width: 240, height: 60)
        .contentShape(Rectangle())
        .onTapGesture { state.ancestorActions += 1 }
        .panGesture(direction: .down) { _, _ in state.ancestorActions += 1 }
        .panGesture(direction: .up) { _, _ in state.ancestorActions += 1 }
    }
}

private final class SliderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var occlusionState: NSWindow.OcclusionState { .visible }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@main @MainActor
struct SliderInputTests {
    private static var checks = 0
    private static var eventNumber = 0

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }

    private static func drain(_ seconds: Double = 0.03) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func send(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat = 30,
                             window: NSWindow) {
        eventNumber += 1
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        )!
        require(event.window === window, "every mouse event targets only the fixture's own window")
        NSApplication.shared.sendEvent(event)
        drain()
    }

    private static func click(_ x: CGFloat, window: NSWindow) {
        send(.leftMouseDown, x: x, window: window)
        send(.leftMouseUp, x: x, window: window)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let screens = NSScreen.screens
        require(!screens.isEmpty, "a real WindowServer display is required for input delivery")
        let minimumX = screens.map { $0.frame.minX }.min()!
        let minimumY = screens.map { $0.frame.minY }.min()!
        let panel = SliderPanel(
            contentRect: NSRect(x: minimumX - 12000, y: minimumY - 12000, width: 240, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        let state = SliderState()
        let host = NotchHostingView(rootView: SliderFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        panel.contentView = host
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil); panel.contentView = nil }
        drain(0.15)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        require(panel.windowNumber > 0, "a real WindowServer connection is required; no event-delivery fake PASS")
        require(panel.frame.maxX < minimumX - 10000 && panel.frame.maxY < minimumY - 10000
                && screens.allSatisfy { !panel.frame.intersects($0.frame) },
                "AppKit keeps the owned panel far outside every display")
        require(!panel.isKeyWindow && !app.isActive, "hover-style fixture starts without activation or keyboard focus")

        click(170, window: panel)
        require(state.commits == [75], "first quick click seeks once at the clicked position")
        require(state.value == 75 && !state.dragging && state.lastDragged > .distantPast,
                "first click updates the value and completes its drag lifetime")
        click(120, window: panel)
        require(state.commits == [75, 50], "second quick click also seeks exactly once")

        send(.leftMouseDown, x: 70, window: panel)
        require(state.dragging && state.value == 25, "mouse-down previews the initial position")
        send(.leftMouseDragged, x: 180, window: panel)
        require(state.value == 80 && state.commits.count == 2, "drag previews without a premature commit")
        send(.leftMouseUp, x: 180, window: panel)
        require(state.commits == [75, 50, 80] && !state.dragging, "drag commits once on mouse-up")
        require(state.ancestorActions == 0, "ancestor tap and notch pan gestures do not steal slider input")

        send(.leftMouseDown, x: 100, window: panel)
        send(.leftMouseDragged, x: 360, window: panel)
        send(.leftMouseUp, x: 360, window: panel)
        require(state.value == 100 && state.commits.last == 100, "drag outside the track clamps to its upper bound")
        send(.leftMouseDown, x: 100, window: panel)
        send(.leftMouseDragged, x: -100, window: panel)
        send(.leftMouseUp, x: -100, window: panel)
        require(state.value == 0 && state.commits.last == 0, "drag outside the track clamps to its lower bound")

        let previousCommits = state.commits.count
        let previousChanges = state.changes.count
        state.enabled = false
        drain()
        click(170, window: panel)
        require(state.commits.count == previousCommits && state.changes.count == previousChanges && state.value == 0,
                "an unavailable seek capability never calls the player callback")
        state.enabled = true
        state.duration = 0
        drain()
        click(170, window: panel)
        require(state.commits.count == previousCommits && state.changes.count == previousChanges,
                "unknown or zero duration cannot dispatch a seek")
        require(!panel.isKeyWindow && !app.isActive, "pointer seeking never activates the app or makes the hover panel key")

        progressSynchronization(window: panel)

        print("Slider input: \(checks) checks passed (whole production sources, own-window events only)")
    }

    private static func progressSynchronization(window: NSWindow) {
        let state = ProgressState()
        state.timestamp = Date().addingTimeInterval(-2)
        let host = NotchHostingView(rootView: ProgressFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        window.contentView = host
        drain(0.15)
        require(state.value >= 42 && state.value < 43, "progress estimates the supplied playing timeline")

        state.elapsed = 42
        state.timestamp = Date()
        state.playing = false
        state.rate = 0
        drain()
        require(state.value == 42, "pause commits the final position without another timeline tick")
        state.tick = Date().addingTimeInterval(100)
        drain(0.3)
        require(state.value == 42, "paused progress remains stationary even when the view refreshes")

        state.timestamp = Date().addingTimeInterval(-2)
        state.rate = 0.5
        state.playing = true
        drain()
        require(state.value >= 43 && state.value < 44, "resume preserves the source playback rate")
        state.rate = 2
        drain()
        require(state.value >= 46 && state.value < 47, "a rate-only change refreshes progress without a new tick")

        state.value = 90
        state.lastDragged = Date()
        state.elapsed = 45
        state.timestamp = Date()
        state.playing = false
        state.rate = 0
        drain(0.15)
        require(state.value == 90, "a pending paused seek keeps its short local preview")
        state.elapsed = 46
        drain(0.95)
        require(state.value == 46, "a paused seek reconciles the newest source position after grace with no tick")

        state.dragging = true
        state.value = 75
        state.elapsed = 47
        drain()
        require(state.value == 75, "source updates do not overwrite a drag in progress")
        state.lastDragged = Date()
        state.dragging = false
        drain(1.05)
        require(state.value == 47, "a completed paused drag eventually reconciles without a timeline tick")
        require(state.commands == 0, "passive progress synchronization never sends a media command")
    }
}
