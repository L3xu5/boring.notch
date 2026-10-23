import Foundation

/// Bridges callback APIs that can complete after cancellation. Installation, cancellation and
/// a racing callback have one terminal result and resume their continuation exactly once.
public final class CallbackResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?
    private var completed = false
    private var cancelled = false
    private var cancellationHandler: (@Sendable () -> Void)?
    public init() {}
    public func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if completed {
            let value = result!
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
    public func resume(returning value: Value) { complete(value, cancel: false) }
    public func cancel(returning value: Value) { complete(value, cancel: true) }
    public func onCancel(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldCancel = cancelled
        if !completed { cancellationHandler = handler }
        lock.unlock()
        if shouldCancel { handler() }
    }
    private func complete(_ value: Value, cancel: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true; cancelled = cancel; result = value
        let continuation = self.continuation
        self.continuation = nil
        let handler = cancel ? cancellationHandler : nil
        cancellationHandler = nil
        lock.unlock()
        handler?()
        continuation?.resume(returning: value)
    }
}
