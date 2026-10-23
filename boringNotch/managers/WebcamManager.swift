import AVFoundation
import AppKit
import SwiftUI
import BoringCore

/// AVCaptureSession remains on the backend actor. Passing its reference to a preview layer is
/// the framework's supported view boundary; views never start/configure the session directly.
final class CameraSessionReference: @unchecked Sendable {
    let session: AVCaptureSession
    init(_ session: AVCaptureSession) { self.session = session }
}

private actor AVCameraCaptureBackend: CameraCaptureBackend {
    private var session: AVCaptureSession?
    func configure() async throws {
        await stop()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw WebcamManager.WebcamError.accessDenied
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.deviceType == .external }) ?? devices.first else {
            throw WebcamManager.WebcamError.deviceUnavailable
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw WebcamManager.WebcamError.configurationFailed }
        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(input)
        session.commitConfiguration()
        self.session = session
    }
    func start() async throws {
        guard let session, AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw WebcamManager.WebcamError.accessDenied
        }
        session.startRunning()
    }
    func stop() async {
        guard let session else { return }
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        self.session = nil
    }
    func reference() -> CameraSessionReference? { session.map(CameraSessionReference.init) }
}

@MainActor
final class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    @Published private(set) var sessionReference: CameraSessionReference?
    @Published private(set) var isSessionRunning = false
    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var cameraAvailable = false
    @Published private(set) var isRequestingAuthorization = false
    private let backend = AVCameraCaptureBackend()
    private var usage = CameraUsageIntent()
    private var eventGate = CameraEventGate()
    private var observers: [NSObjectProtocol] = []
    private lazy var controller = CameraSessionController(backend: backend) { [weak self] event in
        Task { @MainActor in await self?.apply(event) }
    }
    // Compatibility for other consumers; each view gets its own layer.
    var previewLayer: AVCaptureVideoPreviewLayer? { sessionReference.map { AVCaptureVideoPreviewLayer(session: $0.session) } }

    enum WebcamError: Error { case deviceUnavailable, accessDenied, configurationFailed }

    private override init() {
        super.init()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshAvailability() }
            })
        }
        refreshAvailability()
    }
    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        let backend = backend
        Task { await backend.stop() }
    }
    func acquirePreviewConsumer() -> UUID {
        let id = usage.acquireConsumer(); submitIntent(); return id
    }
    func releasePreviewConsumer(_ id: UUID) { usage.releaseConsumer(id); submitIntent() }
    func checkCameraAvailability() { refreshAvailability() }
    func checkAndRequestVideoAuthorization() {
        refreshAvailability()
        guard authorizationStatus == .notDetermined, !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
            Task { @MainActor in self?.isRequestingAuthorization = false; self?.refreshAvailability() }
        }
    }
    func startSession() {
        usage.requestRunning(true)
        refreshAvailability()
        if authorizationStatus == .notDetermined { checkAndRequestVideoAuthorization() }
    }
    func stopSession() { usage.requestRunning(false); submitIntent() }
    private func refreshAvailability() {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAvailable = !AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                                            mediaType: .video, position: .unspecified).devices.isEmpty
        usage.setAuthorized(authorizationStatus == .authorized)
        usage.setAvailable(cameraAvailable)
        submitIntent()
    }
    private func submitIntent() {
        let intent = usage.snapshot
        if !intent.shouldRun { isSessionRunning = false; sessionReference = nil }
        Task { await controller.update(intent) }
    }
    private func apply(_ event: CameraSessionEvent) async {
        guard eventGate.accept(event, currentRevision: usage.revision) else { return }
        switch event.phase {
        case .running:
            let reference = await backend.reference()
            guard eventGate.isCurrent(event, currentRevision: usage.revision) else { return }
            sessionReference = reference
            isSessionRunning = reference != nil
        case .idle, .preparing, .failed:
            isSessionRunning = false
            sessionReference = nil
        }
    }
}
