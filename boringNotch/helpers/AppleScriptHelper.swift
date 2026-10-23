import Foundation

/// AppleScript stays on its documented executor and is serialized even while an Apple event
/// services a nested run loop. Cancellation prevents queued work and discards late replies.
@MainActor
enum AppleScriptHelper {
    private static var busy = false
    private static var waiters: [CheckedContinuation<Void, Never>] = []
    private static func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }
    private static func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().resume() }
    }
    @discardableResult
    static func execute(_ source: String) async throws -> NSAppleEventDescriptor? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let bounded = "with timeout of 5 seconds\n" + source + "\nend timeout"
        guard let script = NSAppleScript(source: bounded) else { throw CocoaError(.coderInvalidValue) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        try Task.checkCancellation()
        if let error { throw NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]) }
        return result
    }
    static func executeVoid(_ source: String) async throws { _ = try await execute(source) }
}
