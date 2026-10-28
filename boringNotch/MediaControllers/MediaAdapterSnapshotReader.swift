import BoringCore
import Darwin
import Foundation

/// One read-only adapter `get`. The value holds configuration only, so awaiting a snapshot
/// never retains the controller that owns this reader. Each call supervises its own process.
struct MediaAdapterSnapshotReader: Sendable {
    struct Resources: Sendable {
        let script: URL
        let framework: URL
    }

    private let resources: @Sendable () -> Resources?
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    init(resources: @escaping @Sendable () -> Resources? = { @Sendable in MediaAdapterSnapshotReader.bundledResources() },
         timeout: TimeInterval = 3, maximumOutputBytes: Int = 16 * 1024 * 1024) {
        self.resources = resources
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 3) : 3
        self.maximumOutputBytes = min(max(1, maximumOutputBytes), 16 * 1024 * 1024)
    }

    func read() async -> MediaWireUpdate? {
        guard !Task.isCancelled, let resources = resources(), Self.available(resources) else { return nil }
        let capture = SnapshotProcessCapture(resources: resources, timeout: timeout, maximumBytes: maximumOutputBytes)
        let data = await withTaskCancellationHandler {
            await withCheckedContinuation { capture.start($0) }
        } onCancel: { capture.cancel() }
        guard !Task.isCancelled, let data,
              let payload = try? JSONDecoder().decode([String: MediaWireValue].self, from: data),
              let bundle = payload.string("bundleIdentifier"), !bundle.isEmpty,
              payload.string("title") != nil, payload.boolean("playing") != nil else { return nil }
        guard !Task.isCancelled else { return nil }
        return MediaWireUpdate(payload: payload, diff: false)
    }

    private static func bundledResources() -> Resources? {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksPath else { return nil }
        return Resources(script: script, framework: URL(fileURLWithPath: frameworks)
            .appendingPathComponent("MediaRemoteAdapter.framework", isDirectory: true))
    }

    private static func available(_ resources: Resources) -> Bool {
        var directory: ObjCBool = false
        guard resources.script.isFileURL, resources.framework.isFileURL,
              FileManager.default.fileExists(atPath: resources.script.path, isDirectory: &directory), !directory.boolValue,
              FileManager.default.isReadableFile(atPath: resources.script.path),
              resources.framework.pathExtension == "framework" else { return false }
        let binary = resources.framework.appendingPathComponent(resources.framework.deletingPathExtension().lastPathComponent)
        return FileManager.default.fileExists(atPath: binary.path, isDirectory: &directory) && !directory.boolValue
            && FileManager.default.isReadableFile(atPath: binary.path)
    }
}

/// State is serialized with the descriptor's nonblocking reads and closure. A timeout or
/// cancellation can therefore resume the waiter even when the child never writes or exits.
private final class SnapshotProcessCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "boringNotch.media-snapshot")
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var continuation: CheckedContinuation<Data?, Never>?
    private var buffer = Data()
    private var exitStatus: Int32?
    private var reachedEOF = false
    private var finished = false

    init(resources: MediaAdapterSnapshotReader.Resources, timeout: TimeInterval, maximumBytes: Int) {
        self.timeout = timeout; self.maximumBytes = maximumBytes
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.script.path, resources.framework.path, "get"]
        process.currentDirectoryURL = resources.script.deletingLastPathComponent()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<Data?, Never>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            lock.unlock(); finish(nil, stopProcess: true); return
        }
        process.terminationHandler = { [weak self] process in self?.terminated(process.terminationStatus) }
        do { try process.run() }
        catch { lock.unlock(); finish(nil, stopProcess: true); return }
        // Only the child keeps the write end. EOF must not depend on this owner's Pipe lifetime.
        try? pipe.fileHandleForWriting.close()
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        self.source = source
        source.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.cancel() }
        self.timer = timer
        timer.resume()
        lock.unlock()
    }

    func cancel() { finish(nil, stopProcess: true) }

    private func readAvailable() {
        lock.lock()
        guard !finished, !reachedEOF else { lock.unlock(); return }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var failed = false
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                guard count <= maximumBytes - buffer.count else { failed = true; break }
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                reachedEOF = true
                source?.cancel(); source = nil
                break
            } else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { break }
            else { failed = true; break }
        }
        let completed = reachedEOF && exitStatus == 0
        let data = completed ? buffer : nil
        lock.unlock()
        if failed { finish(nil, stopProcess: true) }
        else if completed { finish(data, stopProcess: false) }
    }

    private func terminated(_ status: Int32) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        exitStatus = status
        let completed = reachedEOF && status == 0
        let data = completed ? buffer : nil
        lock.unlock()
        if status != 0 { finish(nil, stopProcess: false) }
        else if completed { finish(data, stopProcess: false) }
        else { readAvailable() }
    }

    private func finish(_ data: Data?, stopProcess: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation; self.continuation = nil
        process.terminationHandler = nil
        source?.cancel(); source = nil
        timer?.cancel(); timer = nil
        // `get` is an owned, disposable read-only subprocess. SIGKILL also bounds shutdown of
        // a hung native adapter that ignores SIGTERM; no application/player process is signaled.
        if stopProcess, process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        continuation?.resume(returning: data)
    }

    deinit { cancel() }
}
