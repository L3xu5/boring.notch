import Foundation
import Cocoa
import ApplicationServices
import BoringCore

/// UI authorization belongs to this process. Only hardware calls cross the embedded XPC
/// boundary, with one connection epoch and an explicit deadline for every request.
@MainActor
final class XPCHelperClient: NSObject {
    static let shared = XPCHelperClient()
    private var connection: NSXPCConnection?
    private var epoch = ConnectionEpoch()
    private var lastKnownAuthorization: Bool?
    private var monitoringTask: Task<Void, Never>?
    private enum RequestError: Error, Sendable { case unavailable, timeout, cancelled }

    private func ensureConnection() -> (NSXPCConnection, UUID) {
        if let connection, let id = epoch.current { return (connection, id) }
        let id = epoch.begin()
        let connection = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.invalidate(id) } }
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.invalidate(id) } }
        connection.resume()
        self.connection = connection
        return (connection, id)
    }
    private func invalidate(_ id: UUID) {
        guard epoch.invalidate(id) else { return }
        let old = connection
        connection = nil
        old?.interruptionHandler = nil
        old?.invalidationHandler = nil
        old?.invalidate()
    }
    private func request<Value: Sendable>(
        _ invoke: (any BoringNotchXPCHelperProtocol, @escaping @Sendable (Value) -> Void) -> Void
    ) async throws -> Value {
        let (connection, id) = ensureConnection()
        let result = CallbackResult<Result<Value, RequestError>>()
        let deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            result.resume(returning: .failure(.timeout))
            self?.invalidate(id)
        }
        let response = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                result.install(continuation)
                guard !Task.isCancelled else { result.cancel(returning: .failure(.cancelled)); return }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    result.resume(returning: .failure(.unavailable))
                    Task { @MainActor in self?.invalidate(id) }
                }) as? any BoringNotchXPCHelperProtocol else {
                    result.resume(returning: .failure(.unavailable)); return
                }
                invoke(proxy) { result.resume(returning: .success($0)) }
            }
        } onCancel: { result.cancel(returning: .failure(.cancelled)) }
        deadline.cancel()
        return try response.get()
    }
    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        NotificationCenter.default.post(name: .accessibilityAuthorizationChanged, object: nil, userInfo: ["granted": granted])
    }
    func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        notifyAuthorizationChange(AXIsProcessTrustedWithOptions(options))
    }
    func isAccessibilityAuthorized() async -> Bool {
        let granted = AXIsProcessTrusted()
        notifyAuthorizationChange(granted)
        return granted
    }
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        if promptIfNeeded && !AXIsProcessTrusted() { requestAccessibilityAuthorization() }
        return await isAccessibilityAuthorized()
    }
    func startMonitoringAccessibilityAuthorization(every interval: TimeInterval = 3) {
        stopMonitoringAccessibilityAuthorization()
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.isAccessibilityAuthorized()
                do { try await Task.sleep(for: .seconds(max(0.5, interval))) } catch { return }
            }
        }
    }
    func stopMonitoringAccessibilityAuthorization() { monitoringTask?.cancel(); monitoringTask = nil }
    var isMonitoring: Bool { monitoringTask != nil }
    func isKeyboardBrightnessAvailable() async -> Bool { (try? await request { $0.isKeyboardBrightnessAvailable(with: $1) }) ?? false }
    func currentKeyboardBrightness() async -> Float? {
        try? await request { service, reply in service.currentKeyboardBrightness { reply($0?.floatValue) } }
    }
    func setKeyboardBrightness(_ value: Float) async -> Bool {
        guard value.isFinite else { return false }
        return (try? await request { $0.setKeyboardBrightness(min(1, max(0, value)), with: $1) }) ?? false
    }
    func isScreenBrightnessAvailable() async -> Bool { (try? await request { $0.isScreenBrightnessAvailable(with: $1) }) ?? false }
    func currentScreenBrightness() async -> Float? {
        try? await request { service, reply in service.currentScreenBrightness { reply($0?.floatValue) } }
    }
    func setScreenBrightness(_ value: Float) async -> Bool {
        guard value.isFinite else { return false }
        return (try? await request { $0.setScreenBrightness(min(1, max(0, value)), with: $1) }) ?? false
    }
    deinit { monitoringTask?.cancel(); connection?.invalidate() }
}

extension Notification.Name {
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")
}
