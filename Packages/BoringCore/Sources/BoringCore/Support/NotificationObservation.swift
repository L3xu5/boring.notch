import Foundation

/// A cancellable registration. Cancellation is idempotent and suppresses queued callbacks.
public final class NotificationObservation: @unchecked Sendable {
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        var isActive: Bool { lock.withLock { active } }
        func cancel() { lock.withLock { active = false } }
    }

    private let center: NotificationCenter
    private let lifetime = Lifetime()
    private let lock = NSLock()
    private var token: (any NSObjectProtocol)?

    public init(
        center: NotificationCenter = .default,
        name: Notification.Name,
        object: AnyObject? = nil,
        queue: OperationQueue? = nil,
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        let lifetime = self.lifetime
        token = center.addObserver(forName: name, object: object, queue: queue) { notification in
            guard lifetime.isActive else { return }
            handler(notification)
        }
    }

    public func cancel() {
        let registration = lock.withLock { () -> (any NSObjectProtocol)? in
            lifetime.cancel()
            defer { token = nil }
            return token
        }
        if let registration { center.removeObserver(registration) }
    }

    deinit { cancel() }
}
