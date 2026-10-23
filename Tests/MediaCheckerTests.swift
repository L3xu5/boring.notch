import Foundation

actor ProbeState {
    var cancelled = false
    func markCancelled() { cancelled = true }
}
struct ProbeFailure: Error { let reason: String }
@main struct MediaCheckerTests {
    static func main() async throws {
        let working = try await MediaChecker(probe: { false }).checkDeprecationStatus()
        let deprecated = try await MediaChecker(probe: { true }).checkDeprecationStatus()
        guard !working && deprecated else { throw ProbeFailure(reason: "Probe result was not preserved") }
        let state = ProbeState()
        let checker = MediaChecker(timeout: .milliseconds(30), probe: {
            do { try await Task.sleep(for: .seconds(5)); return false }
            catch { await state.markCancelled(); throw error }
        })
        let start = Date()
        do { _ = try await checker.checkDeprecationStatus(); throw ProbeFailure(reason: "Timeout became successful deprecation check") }
        catch MediaChecker.MediaCheckerError.timeout { }
        guard await state.cancelled, Date().timeIntervalSince(start) < 1 else { throw ProbeFailure(reason: "Timeout did not cancel suspended probe") }
        let caller = Task { try await MediaChecker(probe: { try await Task.sleep(for: .seconds(5)); return false }).checkDeprecationStatus() }
        caller.cancel()
        do { _ = try await caller.value; throw ProbeFailure(reason: "Canceled caller completed successfully") }
        catch is CancellationError { }
        print("Media checker: supported/deprecated result, timeout classification and caller cancellation passed (no player/probe process launched)")
    }
}
