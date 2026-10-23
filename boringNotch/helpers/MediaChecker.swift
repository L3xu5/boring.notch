import BoringCore
import Foundation

final class MediaChecker: Sendable {
    enum MediaCheckerError: Error { case missingResources, timeout }
    private let probe: @Sendable () async throws -> Bool
    private let timeout: Duration
    init(timeout: Duration = .seconds(10), probe: @escaping @Sendable () async throws -> Bool = { try await MediaChecker.runProbe() }) {
        self.timeout = timeout; self.probe = probe
    }
    func checkDeprecationStatus() async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { [probe, timeout] group in
            group.addTask { try await probe() }
            group.addTask { try await Task.sleep(for: timeout); throw MediaCheckerError.timeout }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MediaCheckerError.timeout }
            return result
        }
    }
    private static func runProbe() async throws -> Bool {
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let client = Bundle.main.url(forResource: "MediaRemoteAdapterTestClient", withExtension: nil),
              let frameworks = Bundle.main.privateFrameworksPath else { throw MediaCheckerError.missingResources }
        do {
            try await ProcessCommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [script.path, frameworks + "/MediaRemoteAdapter.framework", client.path, "test"],
                directory: script.deletingLastPathComponent())
            return false
        } catch let error as ProcessCommandError where error.status == 1 { return true }
    }
}
