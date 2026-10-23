import AppKit
import ApplicationServices
import Foundation

/// Observes physical transport keys while preserving native macOS media handling.
@MainActor
final class MediaTransportKeyMonitor {
    enum Action: Equatable, Sendable {
        case playPause
        case next
        case previous
    }

    private let shouldRoute: @MainActor () -> Bool
    private let onAction: @MainActor (Action) -> Void
    private let authorization: () -> Bool
    private var context: MediaTransportKeyTapContext?
    private var retryTimer: Timer?
    private var started = false
    private(set) var generation: UInt64 = 0

    init(
        shouldRoute: @escaping @MainActor () -> Bool,
        onAction: @escaping @MainActor (Action) -> Void,
        authorization: @escaping () -> Bool = { AXIsProcessTrusted() }
    ) {
        self.shouldRoute = shouldRoute
        self.onAction = onAction
        self.authorization = authorization
    }

    func start() {
        guard !started else {
            refreshConfiguration()
            return
        }
        generation &+= 1
        started = true
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshConfiguration() }
        }
        retryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshConfiguration()
    }

    func refreshConfiguration() {
        guard started else { return }
        let enabled = shouldRoute() && authorization()
        if enabled && context == nil {
            let generation = self.generation
            context = MediaTransportKeyTapContext { [weak self] action in
                // AX control can stall the main thread. The tap returns immediately,
                // while execution and a final source/permission check happen here.
                Task { @MainActor [weak self] in
                    self?.deliverIfCurrent(action, generation: generation)
                }
            }
        }
        context?.setRoutingEnabled(enabled)
        if enabled { context?.maintainTap() }
    }

    func deliverIfCurrent(_ action: Action, generation: UInt64) {
        guard started, generation == self.generation, shouldRoute(), authorization() else { return }
        onAction(action)
    }

    func stop() {
        generation &+= 1
        started = false
        retryTimer?.invalidate()
        retryTimer = nil
        context?.shutdown()
        context = nil
    }

    deinit {
        retryTimer?.invalidate()
        context?.shutdown()
    }
}

/// Shared by the tap callback and in-memory event tests; never reads app state or AX.
enum MediaTransportKeyEventHandler {
    static let systemDefinedType = CGEventType(rawValue: 14)!

    static func handle(
        type: CGEventType,
        event: CGEvent,
        routingEnabled: Bool,
        dispatchAction: (MediaTransportKeyMonitor.Action) -> Void,
        reenableTap: () -> Void
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap()
            return Unmanaged.passUnretained(event)
        }
        guard routingEnabled, type == systemDefinedType,
              let key = NSEvent(cgEvent: event), key.type == .systemDefined,
              key.subtype.rawValue == 8,
              key.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        let action: MediaTransportKeyMonitor.Action
        switch (key.data1 >> 16) & 0xFFFF {
        case 16: action = .playPause
        case 17, 19: action = .next
        case 18, 20: action = .previous
        default: return Unmanaged.passUnretained(event)
        }
        let state = (key.data1 >> 8) & 0xFF
        guard state == 0xA || state == 0xB else {
            return Unmanaged.passUnretained(event)
        }
        // Native handling always runs first. The recipient may check its result
        // asynchronously; autorepeat and key-up must not schedule extra recovery.
        if state == 0xA && key.data1 & 1 == 0 { dispatchAction(action) }
        return Unmanaged.passUnretained(event)
    }
}

/// The worker retains this context for the entire run loop. The C callback never
/// holds an unretained reference to the monitor or waits for the main thread.
private final class MediaTransportKeyTapContext: @unchecked Sendable {
    private let lock = NSLock()
    private let dispatchAction: @Sendable (MediaTransportKeyMonitor.Action) -> Void
    private var routingEnabled = false
    private var stopped = false
    private var workerActive = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(dispatchAction: @escaping @Sendable (MediaTransportKeyMonitor.Action) -> Void) {
        self.dispatchAction = dispatchAction
    }

    func setRoutingEnabled(_ enabled: Bool) {
        lock.withLock { routingEnabled = enabled && !stopped }
    }

    func maintainTap() {
        let needsWorker = lock.withLock {
            guard !stopped, routingEnabled, !workerActive else { return false }
            workerActive = true
            return true
        }
        if needsWorker {
            let worker = Thread { [self] in run() }
            worker.name = "Boring Notch media transport keys"
            worker.qualityOfService = .userInteractive
            worker.start()
        } else {
            reenableTap()
        }
    }

    func shutdown() {
        let state = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            stopped = true
            routingEnabled = false
            return (tap, runLoop)
        }
        if let tap = state.0 { CFMachPortInvalidate(tap) }
        if let loop = state.1 {
            // Schedule the stop as well as waking the loop: shutdown can race with
            // the worker just before its first CFRunLoopRun invocation.
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
                CFRunLoopStop(loop)
            }
            CFRunLoopWakeUp(loop)
        }
    }

    private func reenableTap() {
        let currentTap = lock.withLock { stopped ? nil : tap }
        if let currentTap, CFMachPortIsValid(currentTap), !CGEvent.tapIsEnabled(tap: currentTap) {
            CGEvent.tapEnable(tap: currentTap, enable: true)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let enabled = lock.withLock { routingEnabled && !stopped }
        return MediaTransportKeyEventHandler.handle(
            type: type, event: event, routingEnabled: enabled,
            dispatchAction: dispatchAction, reenableTap: { self.reenableTap() }
        )
    }

    private func run() {
        defer {
            lock.withLock {
                tap = nil
                runLoop = nil
                workerActive = false
            }
        }
        guard !lock.withLock({ stopped }) else { return }
        let mask = CGEventMask(1) << MediaTransportKeyEventHandler.systemDefinedType.rawValue
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let context = Unmanaged<MediaTransportKeyTapContext>.fromOpaque(userInfo).takeUnretainedValue()
                return context.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            return
        }
        let loop = CFRunLoopGetCurrent()!
        let mayRun = lock.withLock {
            guard !stopped else { return false }
            tap = newTap
            runLoop = loop
            return true
        }
        guard mayRun else {
            CFMachPortInvalidate(newTap)
            return
        }
        CFRunLoopAddSource(loop, source, .commonModes)
        reenableTap()
        withExtendedLifetime(self) { CFRunLoopRun() }
        CFRunLoopRemoveSource(loop, source, .commonModes)
        CFMachPortInvalidate(newTap)
    }
}
