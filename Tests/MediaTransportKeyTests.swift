import AppKit
import Foundation

@main
struct MediaTransportKeyTests {
    static func event(
        key: Int = 16, state: Int = 0xA, repeatKey: Bool = false,
        flags: NSEvent.ModifierFlags = [], subtype: Int16 = 8
    ) -> CGEvent {
        NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, subtype: subtype,
            data1: (key << 16) | (state << 8) | (repeatKey ? 1 : 0), data2: -1
        )!.cgEvent!
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func main() {
        var actions: [MediaTransportKeyMonitor.Action] = []
        var reenables = 0
        func handle(_ event: CGEvent, enabled: Bool = true, type: CGEventType? = nil) -> Unmanaged<CGEvent>? {
            MediaTransportKeyEventHandler.handle(
                type: type ?? event.type, event: event, routingEnabled: enabled,
                dispatchAction: { actions.append($0) }, reenableTap: { reenables += 1 }
            )
        }
        func passes(_ event: CGEvent, enabled: Bool = true, type: CGEventType? = nil) -> Bool {
            handle(event, enabled: enabled, type: type)?.toOpaque() == Unmanaged.passUnretained(event).toOpaque()
        }

        require(passes(event()), "initial play/pause down preserves native handling")
        require(actions == [.playPause], "initial play/pause down dispatches once")
        require(passes(event(state: 0xB)), "play/pause up preserves native handling")
        require(passes(event(repeatKey: true)), "play/pause autorepeat preserves native handling")
        require(passes(event(state: 0xB, repeatKey: true)), "repeated up preserves native handling")
        require(actions == [.playPause], "up and autorepeat cannot toggle playback")

        for (key, action) in [(17, MediaTransportKeyMonitor.Action.next), (19, .next), (18, .previous), (20, .previous)] {
            require(passes(event(key: key)), "transport down preserves native handling")
            require(actions.last == action, "transport key maps to the intended action")
            let count = actions.count
            require(passes(event(key: key, state: 0xB)), "transport up preserves native handling")
            require(passes(event(key: key, repeatKey: true)), "transport repeat preserves native handling")
            require(actions.count == count, "transport up/repeat do not dispatch")
        }
        let routedCount = actions.count
        require(passes(event(), enabled: false), "other source or missing AX permission passes through")
        for flag: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            require(passes(event(flags: flag)), "modified transport key passes through")
        }
        require(passes(event(key: 0)), "volume key is left for the HUD")
        require(passes(event(key: 7)), "mute key is left for the HUD")
        require(passes(event(key: 2)), "brightness key is left for the HUD")
        require(passes(event(state: 0xC)), "unknown key state passes through")
        require(passes(event(subtype: 9)), "unrelated system-defined subtype passes through")
        let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        require(passes(keyboard), "ordinary keyboard event passes through")
        require(actions.count == routedCount, "pass-through events dispatch no action")
        require(passes(event(flags: .function)), "physical media keys may carry the function flag")
        require(actions.count == routedCount + 1, "function flag does not suppress the media action")

        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            require(passes(event(), type: type), "disabled notification returns the same unretained event")
        }
        require(reenables == 2, "timeout and user-input disable notifications request re-enabling")
        require(actions.count == routedCount + 1, "disabled notifications do not dispatch media actions")

        // Start with fake authorization denied: this exercises the real delivery
        // guard without installing a tap or querying/changing real permissions.
        var routeAllowed = true
        var authorized = false
        var delivered: [MediaTransportKeyMonitor.Action] = []
        let monitor = MediaTransportKeyMonitor(
            shouldRoute: { routeAllowed }, onAction: { delivered.append($0) },
            authorization: { authorized }
        )
        monitor.start()
        monitor.deliverIfCurrent(.playPause, generation: monitor.generation)
        require(delivered.isEmpty, "permission denied at delivery cancels a pending action")
        authorized = true
        routeAllowed = false
        monitor.deliverIfCurrent(.playPause, generation: monitor.generation)
        require(delivered.isEmpty, "a changed ownership policy cancels a pending action")
        routeAllowed = true
        monitor.deliverIfCurrent(.playPause, generation: monitor.generation)
        require(delivered == [.playPause], "current routing policy and authorization allow delivery")
        let oldGeneration = monitor.generation
        monitor.stop()
        monitor.deliverIfCurrent(.next, generation: oldGeneration)
        require(delivered == [.playPause], "shutdown cancels queued delivery")
        authorized = false
        monitor.start()
        authorized = true
        monitor.deliverIfCurrent(.next, generation: oldGeneration)
        require(delivered == [.playPause], "restart cannot revive delivery queued before shutdown")
        monitor.stop()
        print("Media transport key tests passed (in-memory events; no event tap or permission changes)")
    }
}
