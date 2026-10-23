import Foundation

public struct ProcessCommandError: Error, Sendable {
    public let status: Int32
}

/// A process lifetime is serialized independently from the actor awaiting it. Cancellation
/// before launch, during execution and concurrent termination all resume exactly once.
public enum ProcessCommandRunner {
    public static func run(executable: URL, arguments: [String], directory: URL) async throws {
        let execution = Execution(executable: executable, arguments: arguments, directory: directory)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in execution.start(continuation) }
        } onCancel: {
            execution.cancel()
        }
    }

    private final class Execution: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var cancelled = false
        init(executable: URL, arguments: [String], directory: URL) {
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        func start(_ continuation: CheckedContinuation<Void, any Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            process.terminationHandler = { [self] process in finish(status: process.terminationStatus) }
            do {
                try process.run()
                lock.unlock()
            } catch {
                self.continuation = nil
                process.terminationHandler = nil
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            if process.isRunning { process.terminate() }
            lock.unlock()
        }
        private func finish(status: Int32) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let cancelled = self.cancelled
            process.terminationHandler = nil
            lock.unlock()
            if cancelled { continuation?.resume(throwing: CancellationError()) }
            else if status != 0 { continuation?.resume(throwing: ProcessCommandError(status: status)) }
            else { continuation?.resume() }
        }
    }
}
