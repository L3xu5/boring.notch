import AppKit
import BoringCore
import Combine
import Defaults
import SwiftUI

/// Owns one window, model, input monitor and observation lifetime per display.
@MainActor
final class NotchWindowCoordinator {
    @MainActor private final class Record {
        let window: BoringNotchSkyLightWindow
        let model: BoringViewModel
        var detector: DragDetector?
        var dragRegion: CGRect?
        var observations: [NotificationObservation] = []
        var subscriptions = Set<AnyCancellable>()

        init(window: BoringNotchSkyLightWindow, model: BoringViewModel) {
            self.window = window
            self.model = model
        }
    }

    private let coordinator: BoringViewCoordinator
    private var records: [String: Record] = [:]
    private var observations: [NotificationObservation] = []
    private var lastViewByDisplay: [String: NotchViews] = [:]
    private var reconcileTask: Task<Void, Never>?
    private var started = false
    private var screenLocked = false
    private var sleeping = false

    init(coordinator: BoringViewCoordinator? = nil) {
        self.coordinator = coordinator ?? .shared
    }

    func start() {
        guard !started else { return }
        started = true
        let names: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            .selectedScreenChanged, .notchHeightChanged, .showOnAllDisplaysChanged,
            .automaticallySwitchDisplayChanged, .expandedDragDetectionChanged,
        ]
        for name in names {
            observations.append(NotificationObservation(name: name, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReconcile() }
            })
        }
        observations.append(NotificationObservation(
            center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.didActivateApplicationNotification, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleApplicationActivation() }
        })
        reconcile()
    }

    func stop() {
        started = false
        reconcileTask?.cancel()
        reconcileTask = nil
        observations.forEach { $0.cancel() }
        observations.removeAll()
        for id in Array(records.keys) { removeRecord(id) }
        lastViewByDisplay.removeAll()
    }

    func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        if locked { stopCameraPreviews() }
        reconcile()
    }

    func setSleeping(_ value: Bool) {
        sleeping = value
        if value { stopCameraPreviews() }
        reconcile()
    }

    func open(_ view: NotchViews = .home, keyboard: Bool = true) {
        reconcile()
        guard let record = targetRecord() else { return }
        record.model.currentView = view
        record.model.keyboardInteractionActive = keyboard
        record.model.open()
        if keyboard {
            record.window.acceptsKeyboardFocus = true
            record.window.makeKeyAndOrderFront(nil)
        } else {
            record.window.orderFrontRegardless()
        }
    }

    func toggleFromKeyboard() {
        reconcile()
        guard let record = targetRecord() else { return }
        if record.model.notchState == .open {
            record.model.close()
            return
        }
        open(record.model.currentView)
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch { return }
            self?.reconcile()
        }
    }

    private func reconcile() {
        guard started else { return }
        let displays = NSScreen.screens.compactMap { screen -> (String, NSScreen)? in
            screen.displayUUID.map { ($0, screen) }
        }
        let byID = Dictionary(displays, uniquingKeysWith: { first, _ in first })
        let ids = sleeping || (screenLocked && !Defaults[.showOnLockScreen]) ? [] : DisplayRoutingPolicy.desiredDisplayIDs(
            availableIDs: displays.map(\.0),
            preferredID: coordinator.preferredScreenUUID,
            activeID: NSScreen.main?.displayUUID,
            showOnAllDisplays: Defaults[.showOnAllDisplays],
            automaticallySwitchDisplay: Defaults[.automaticallySwitchDisplay]
        )
        let desired = Set(ids)
        for id in Array(records.keys) where !desired.contains(id) { removeRecord(id) }
        if !Defaults[.showOnAllDisplays], let id = ids.first { coordinator.selectedScreenUUID = id }

        for id in ids {
            guard let screen = byID[id] else { continue }
            let record = records[id] ?? makeRecord(id: id)
            records[id] = record
            let frame = CGRect(
                x: screen.frame.midX - windowSize.width / 2,
                y: screen.frame.maxY - windowSize.height,
                width: windowSize.width, height: windowSize.height
            )
            if record.window.frame != frame { record.window.setFrame(frame, display: true) }
            record.model.screenUUID = id
            record.model.closedNotchSize = getClosedNotchSize(screenUUID: id)
            if record.model.notchState == .closed { record.model.notchSize = record.model.closedNotchSize }
            if screenLocked { record.window.enableSkyLight() }
            else { record.window.disableSkyLight() }
            record.window.orderFrontRegardless()
            configureDragDetection(record, screen: screen)
        }
    }

    private func makeRecord(id: String) -> Record {
        let model = BoringViewModel(screenUUID: id)
        if coordinator.openLastTabByDefault, let view = lastViewByDisplay[id] { model.currentView = view }
        let window = BoringNotchSkyLightWindow(
            contentRect: CGRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered, defer: false
        )
        window.contentView = NotchHostingView(rootView: ContentView().environmentObject(model))
        let record = Record(window: window, model: model)
        NotchSpaceManager.shared.notchSpace.windows.insert(window)
        record.observations.append(NotificationObservation(name: NSWindow.didResignKeyNotification,
                                                            object: window, queue: .main) { [weak record] _ in
            MainActor.assumeIsolated {
                guard let record, !record.model.isBatteryPopoverActive else { return }
                record.window.acceptsKeyboardFocus = false
                record.model.keyboardInteractionActive = false
                if !record.model.isMouseHovering() && !record.model.anyDropZoneTargeting { record.model.close() }
            }
        })
        model.$notchState.receive(on: RunLoop.main).sink { [weak record] state in
            // A queued initial/previous close can arrive after a keyboard open in this loop.
            guard let record, state == .closed, record.model.notchState == .closed else { return }
            record.window.acceptsKeyboardFocus = false
            if record.model.keyboardInteractionActive { record.model.keyboardInteractionActive = false }
            if record.window.isKeyWindow { record.window.resignKey() }
        }.store(in: &record.subscriptions)
        return record
    }

    private func removeRecord(_ id: String) {
        guard let record = records.removeValue(forKey: id) else { return }
        lastViewByDisplay[id] = record.model.currentView
        record.detector?.stopMonitoring()
        record.detector = nil
        record.observations.forEach { $0.cancel() }
        record.observations.removeAll()
        record.subscriptions.removeAll()
        record.model.isCameraExpanded = false
        record.model.isBatteryPopoverActive = false
        record.model.keyboardInteractionActive = false
        record.model.destroy()
        record.window.acceptsKeyboardFocus = false
        record.window.disableSkyLight()
        NotchSpaceManager.shared.notchSpace.windows.remove(record.window)
        record.window.contentView = nil
        record.window.close()
    }

    private func configureDragDetection(_ record: Record, screen: NSScreen) {
        guard Defaults[.expandedDragDetection], Defaults[.boringShelf] else {
            record.detector?.stopMonitoring()
            record.detector = nil
            record.dragRegion = nil
            return
        }
        let region = CGRect(x: screen.frame.midX - openNotchSize.width / 2,
                            y: screen.frame.maxY - openNotchSize.height,
                            width: openNotchSize.width, height: openNotchSize.height)
        guard record.dragRegion != region || record.detector == nil else { return }
        record.detector?.stopMonitoring()
        let detector = DragDetector(notchRegion: region)
        detector.onDragEntersNotchRegion = { [weak record] in
            Task { @MainActor in
                guard let record else { return }
                record.model.currentView = .shelf
                record.model.open()
            }
        }
        record.detector = detector
        record.dragRegion = region
        detector.startMonitoring()
    }

    private func targetRecord() -> Record? {
        if let screen = NSScreen.screenWithMouse, let id = screen.displayUUID, let record = records[id] { return record }
        return records[coordinator.selectedScreenUUID] ?? records.sorted(by: { $0.key < $1.key }).first?.value
    }

    private func handleApplicationActivation() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        for record in records.values where record.model.keyboardInteractionActive {
            record.model.isBatteryPopoverActive = false
            record.model.keyboardInteractionActive = false
            record.window.acceptsKeyboardFocus = false
            if !record.model.isMouseHovering() && !record.model.anyDropZoneTargeting { record.model.close() }
        }
    }

    private func stopCameraPreviews() {
        for record in records.values { record.model.isCameraExpanded = false }
        WebcamManager.shared.stopSession()
    }
}
