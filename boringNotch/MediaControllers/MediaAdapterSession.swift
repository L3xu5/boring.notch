import BoringCore
import Foundation

/// Owns exactly one subprocess/read task. The worker holds only immutable configuration and
/// weakly reports resource changes, so a source switch can release the session while reading.
final class MediaAdapterSession<Update: Decodable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var process: Process?
    private var reader: JSONLinesPipeHandler?
    private var generation = UUID()

    var currentProcess: Process? { lock.withLock { process } }
    var currentTask: Task<Void, Never>? { lock.withLock { task } }

    func start(arguments: [String] = [], onUpdate: @escaping @Sendable (Update) async -> Void,
               onRestart: @escaping @Sendable () async -> Void = {}) {
        stop()
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath else { return }
        let arguments = [script.path, frameworks + "/MediaRemoteAdapter.framework", "stream"] + arguments
        let ticket = UUID()
        lock.withLock { generation = ticket }
        let worker = Task.detached(priority: .utility) { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let process = Process()
                let reader = JSONLinesPipeHandler()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                process.arguments = arguments
                process.standardOutput = await reader.getPipe()
                process.standardError = FileHandle.nullDevice
                guard !Task.isCancelled, self?.install(process, reader: reader, ticket: ticket) == true else {
                    await reader.close(); return
                }
                let startedAt = Date()
                do {
                    try Task.checkCancellation()
                    try process.run()
                    await reader.readJSONLines(as: Update.self) { update in
                        guard !Task.isCancelled else { return }
                        await onUpdate(update)
                    }
                } catch {
                    // The same bounded backoff handles launch failures and an unexpected EOF.
                }
                if process.isRunning { process.terminate() }
                await reader.close()
                self?.clearResources(ticket: ticket)
                guard !Task.isCancelled else { return }
                await onRestart()
                if Date().timeIntervalSince(startedAt) >= 30 { failures = 0 }
                failures = min(failures + 1, 5)
                do { try await Task.sleep(for: .seconds(min(pow(2, Double(failures)), 30))) }
                catch { return }
            }
        }
        lock.withLock {
            if generation == ticket { task = worker }
            else { worker.cancel() }
        }
    }

    private func install(_ process: Process, reader: JSONLinesPipeHandler, ticket: UUID) -> Bool {
        lock.withLock {
            guard generation == ticket, !Task.isCancelled else { return false }
            self.process = process; self.reader = reader
            return true
        }
    }
    private func clearResources(ticket: UUID) {
        lock.withLock {
            guard generation == ticket else { return }
            process = nil; reader = nil
        }
    }
    func stop() {
        let resources = lock.withLock { () -> (Task<Void, Never>?, Process?, JSONLinesPipeHandler?) in
            generation = UUID()
            defer { task = nil; process = nil; reader = nil }
            return (task, process, reader)
        }
        resources.0?.cancel()
        if let process = resources.1, process.isRunning { process.terminate() }
        if let reader = resources.2 { Task.detached { await reader.close() } }
    }
    deinit { stop() }
}

/// Synchronizes the FileHandle callback with cancellation/close and resumes its waiter once.
private final class PipeByteReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var waiter: CheckedContinuation<Data, Error>?
    private var closed = false
    init(_ handle: FileHandle) { self.handle = handle }

    func read() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if closed || Task.isCancelled {
                    lock.unlock(); continuation.resume(throwing: CancellationError()); return
                }
                precondition(waiter == nil, "A byte stream has one reader")
                waiter = continuation
                handle.readabilityHandler = { [weak self] handle in self?.received(handle) }
                lock.unlock()
            }
        } onCancel: { self.close() }
    }
    private func received(_ handle: FileHandle) {
        lock.lock()
        guard !closed, let waiter else { lock.unlock(); return }
        self.waiter = nil
        handle.readabilityHandler = nil
        let data = handle.availableData
        lock.unlock()
        waiter.resume(returning: data)
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        handle.readabilityHandler = nil
        try? handle.close()
        waiter?.resume(throwing: CancellationError())
    }
}

actor JSONLinesPipeHandler {
    private let pipe = Pipe()
    private let bytes: PipeByteReader
    private var framer = JSONLinesFramer()
    var bufferedByteCount: Int { framer.bufferedByteCount }
    init() { bytes = PipeByteReader(pipe.fileHandleForReading) }
    func getPipe() -> Pipe { pipe }
    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            while !Task.isCancelled {
                let data = try await bytes.read()
                if data.isEmpty { break }
                for line in try framer.append(data) {
                    guard !Task.isCancelled else { return }
                    if let value = try? JSONDecoder().decode(T.self, from: line) { await onLine(value) }
                }
            }
            if !Task.isCancelled, let line = framer.finish(), let value = try? JSONDecoder().decode(T.self, from: line) {
                await onLine(value)
            }
        } catch { /* close/cancellation ends the stream; its owner supervises unexpected EOF */ }
    }
    func close() {
        bytes.close()
        try? pipe.fileHandleForWriting.close()
    }
}
