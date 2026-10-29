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
    @Published var canSeek = true
    var commands = 0
    var commits: [Double] = []
    var timelineFrames = 0
    var ancestorActions = 0
}

private struct LiveProgressFixture: View {
    @ObservedObject var state: ProgressState
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.02, paused: !state.playing)) { timeline in
            MusicSliderView(sliderValue: $state.value, duration: $state.duration,
                            lastDragged: $state.lastDragged, color: .white, dragging: $state.dragging,
                            currentDate: timeline.date, timestampDate: state.timestamp,
                            elapsedTime: state.elapsed, playbackRate: state.rate, isPlaying: state.playing,
                            canSeek: state.canSeek) {
                state.commits.append($0)
            }
            .frame(width: 200, height: 60)
            .onChange(of: timeline.date) { _, _ in state.timelineFrames += 1 }
        }
        .frame(width: 240, height: 60)
        .contentShape(Rectangle())
        .onTapGesture { state.ancestorActions += 1 }
        .panGesture(direction: .down) { _, _ in state.ancestorActions += 1 }
        .panGesture(direction: .up) { _, _ in state.ancestorActions += 1 }
    }
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

    private static func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { drain(0.02) }
        return condition()
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
        continuousProgressDrag(window: panel)

        print("Slider input: \(checks) checks passed (whole production sources, own-window events only)")
    }

    private static func continuousProgressDrag(window: NSWindow) {
        let state = ProgressState()
        let host = NotchHostingView(rootView: LiveProgressFixture(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        window.contentView = host
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        drain(0.15)
        var endpoints: [Double] = []
        for direction in [-1.0, 1.0] {
            let before = state.commits.count
            let frames = state.timelineFrames
            let started = Date()
            send(.leftMouseDown, x: 60, y: 41, window: window)
            require(state.dragging, "the playing progress control accepts the initial pointer press")
            for step in 1...12 {
                let x = 60.0 + 100.0 * Double(step) / 12
                let y = 41.0 + direction * 8 * Double(step) / 12
                send(.leftMouseDragged, x: x, y: y, window: window)
                if step == 5 || step == 10 {
                    state.elapsed += 0.5
                    state.timestamp = Date()
                }
                drain(0.065)
                require(state.dragging && state.commits.count == before,
                        "a long diagonal drag remains active without sending intermediate seeks")
                require(abs(state.value - (x - 20) * 180 / 200) < 0.01,
                        "live timeline and source heartbeats do not overwrite the drag preview")
            }
            require(Date().timeIntervalSince(started) > 1,
                    "the continuous drag outlasts the seek synchronization grace")
            require(state.timelineFrames - frames >= 5,
                    "the production animation TimelineView actually refreshes during the drag")
            // An externally writable binding is not the user's final pointer location.
            state.value = 3
            drain()
            // Mouse-up can carry the final movement without a preceding dragged event.
            send(.leftMouseUp, x: 190, y: 41 + direction * 8, window: window)
            require(state.commits.count == before + 1 && !state.dragging,
                    "the long diagonal drag commits exactly once and ends its interaction")
            endpoints.append(state.commits.last!)
            require(state.ancestorActions == 0,
                    "ancestor notch gestures never intercept the long diagonal slider drag")
        }
        require(endpoints.allSatisfy { abs($0 - 153) < 0.01 },
                "each seek uses the final pointer-release position, not an earlier preview: \(endpoints)")

        let beforeDisabled = state.commits.count
        send(.leftMouseDown, x: 80, y: 41, window: window)
        require(state.dragging, "a seek begins while the source capability is available")
        send(.leftMouseDragged, x: 160, y: 45, window: window)
        state.canSeek = false
        drain()
        send(.leftMouseUp, x: 190, y: 45, window: window)
        require(state.commits.count == beforeDisabled,
                "losing seek capability during a held drag suppresses the final media command")
        require(!state.dragging, "a disabled held drag releases its interaction state")

        state.canSeek = true
        drain()
        send(.leftMouseDown, x: 80, y: 41, window: window)
        require(state.dragging, "a duration-backed progress control starts a drag")
        state.duration = 0
        drain()
        send(.leftMouseUp, x: 190, y: 45, window: window)
        require(state.commits.count == beforeDisabled && !state.dragging,
                "losing track duration cancels a held drag without leaving the panel held open")
        state.duration = 180
        drain()
        send(.leftMouseDown, x: 80, y: 41, window: window)
        require(state.dragging, "an enabled progress control can start another interaction after cancellation")
        window.contentView = NSView(frame: host.frame)
        require(waitFor { !state.dragging }, "removing a held slider releases its interaction state")
        send(.leftMouseUp, x: 190, y: 45, window: window)
        require(state.commits.count == beforeDisabled,
                "removing a held slider never dispatches a delayed seek")
        require(!window.isKeyWindow && !NSApplication.shared.isActive,
                "continuous seeking keeps the hover panel nonactivating")
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
        require(waitFor { state.value == 46 }, "a paused seek reconciles the newest source position after grace with no tick")

        state.dragging = true
        state.value = 75
        state.elapsed = 47
        drain()
        require(state.value == 75, "source updates do not overwrite a drag in progress")
        state.lastDragged = Date()
        state.dragging = false
        require(waitFor { state.value == 47 }, "a completed paused drag eventually reconciles without a timeline tick")
        require(state.commands == 0, "passive progress synchronization never sends a media command")
    }
}
