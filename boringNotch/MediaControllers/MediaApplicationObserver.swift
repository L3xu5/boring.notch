import AppKit
import Foundation

/// Launch and termination observation survives a player's exit, until the selected source stops.
final class MediaApplicationObserver {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    @MainActor init(bundleIdentifier: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == bundleIdentifier else { return }
                Task { @MainActor in onChange() }
            })
        }
    }
    func stop() { tokens.forEach(center.removeObserver); tokens.removeAll() }
    deinit { stop() }
}
