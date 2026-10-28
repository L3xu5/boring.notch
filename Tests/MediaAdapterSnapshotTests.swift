import BoringCore
import Darwin
import Foundation

private struct SnapshotFixture: Sendable {
    let directory: URL
    let resources: MediaAdapterSnapshotReader.Resources
    var marker: URL { resources.framework.appendingPathComponent("started") }

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-fixture-" + UUID().uuidString)
        let framework = directory.appendingPathComponent("Fixture Framework.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        try Data("fixture only, never loaded".utf8).write(to: framework.appendingPathComponent("Fixture Framework"))
        let script = directory.appendingPathComponent("fixture script.pl")
        let prefix = """
        use strict;
        use warnings;
        $| = 1;
        die 'expected get only' unless @ARGV == 2 && $ARGV[1] eq 'get';
        open(my $marker, '>', "$ARGV[0]/started") or die $!;
        print $marker "$$\\n";
        close($marker);
        """
        try Data((prefix + "\n" + body).utf8).write(to: script)
        resources = .init(script: script, framework: framework)
    }

    func reader(timeout: TimeInterval = 3, maximumBytes: Int = 16 * 1024 * 1024) -> MediaAdapterSnapshotReader {
        MediaAdapterSnapshotReader(resources: { resources }, timeout: timeout, maximumOutputBytes: maximumBytes)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor private final class SnapshotSource {
    let reader: MediaAdapterSnapshotReader
    init(_ reader: MediaAdapterSnapshotReader) { self.reader = reader }
}

@main @MainActor private enum MediaAdapterSnapshotTests {
    private static var checks = 0
    private static let valid = #"{"bundleIdentifier":"fixture.player","title":"Fixture","playing":true,"artist":"Artist","duration":180,"artworkData":"YXJ0","extra":{"nested":1}}"#

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
    }

    private static func wait(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else { fatalError(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func dead(_ fixture: SnapshotFixture) async throws {
        guard let value = try? String(contentsOf: fixture.marker, encoding: .utf8),
              let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            fatalError("Fixture process did not record its owned PID")
        }
        try await wait("Owned get subprocess remained alive after cancellation/timeout") {
            errno = 0
            return Darwin.kill(pid, 0) == -1 && errno == ESRCH
        }
        expect(true, "Owned process has exited")
    }

    static func main() async throws {
        try await validSnapshot()
        try await malformedSnapshots()
        try await missingResources()
        try await timeoutAndCancellation()
        try await boundedOutput()
        try await concurrentOwnership()
        try await sourceLifetime()
        print("Media adapter snapshots: \(checks) checks passed (owned fixture get only; no real adapter/TestClient/player)")
    }

    private static func validSnapshot() async throws {
        let fixture = try SnapshotFixture("print q~" + valid + "~;")
        defer { fixture.cleanup() }
        let update = await fixture.reader().read()
        expect(update?.diff == false && update?.payload.string("title") == "Fixture", "A get snapshot was not normalized into a full update")
        expect(update?.payload.string("bundleIdentifier") == "fixture.player" && update?.payload.boolean("playing") == true,
               "Mandatory get schema fields were lost")
        expect(update?.payload.string("artworkData") == "YXJ0" && update?.payload["extra"] == .unsupported,
               "Artwork or forward-compatible unknown fields were lost")
        let utf8 = try SnapshotFixture(#"for my $byte (split //, '{"bundleIdentifier":"fixture.player","title":"Трек 🎵","playing":false}') { print $byte; select(undef,undef,undef,0.001); }"#)
        defer { utf8.cleanup() }
        let unicode = await utf8.reader().read()
        expect(unicode?.payload.string("title") == "Трек 🎵" && unicode?.payload.boolean("playing") == false,
               "Pipe reads split a UTF-8 title or dropped a final object without LF")
    }

    private static func malformedSnapshots() async throws {
        for text in ["null", "[]", "{}", "{\"bundleIdentifier\":\"fixture\",\"title\":\"Fixture\"}",
                     "{\"bundleIdentifier\":\"fixture\",\"title\":\"Fixture\",\"playing\":1}",
                     "{\"bundleIdentifier\":\"\",\"title\":\"Fixture\",\"playing\":false}",
                     "{\"payload\":{}}", "not json", valid + valid] {
            let fixture = try SnapshotFixture("print q~" + text + "~;")
            let result = await fixture.reader().read()
            expect(result == nil, "Malformed/non-get output was accepted: " + text.prefix(30))
            fixture.cleanup()
        }
        let failure = try SnapshotFixture("print q~" + valid + "~; exit 7;")
        defer { failure.cleanup() }
        let rejected = await failure.reader().read()
        expect(rejected == nil, "A failed get exit status supplied successful metadata")
    }

    private static func missingResources() async throws {
        let absent = await MediaAdapterSnapshotReader(resources: { nil }).read()
        expect(absent == nil, "Missing bundle resources were treated as a snapshot")
        let fixture = try SnapshotFixture("print q~" + valid + "~;")
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.resources.framework.appendingPathComponent("Fixture Framework"))
        let result = await fixture.reader().read()
        expect(result == nil && !FileManager.default.fileExists(atPath: fixture.marker.path),
               "The adapter process launched without its framework binary")
        let missingScript = MediaAdapterSnapshotReader(resources: {
            .init(script: fixture.directory.appendingPathComponent("missing.pl"), framework: fixture.resources.framework)
        })
        let noScript = await missingScript.read()
        expect(noScript == nil, "Missing script did not fail closed before launch")
    }

    private static func timeoutAndCancellation() async throws {
        let timeout = try SnapshotFixture("$SIG{TERM} = sub {}; sleep 60;")
        defer { timeout.cleanup() }
        let started = Date()
        let expired = await timeout.reader(timeout: 0.15).read()
        expect(expired == nil && Date().timeIntervalSince(started) < 1, "A silent get ignored its timeout")
        try await dead(timeout)

        let cancelled = try SnapshotFixture("$SIG{TERM} = sub {}; sleep 60;")
        defer { cancelled.cleanup() }
        let task = Task { await cancelled.reader().read() }
        try await wait("Cancellation fixture did not start") { FileManager.default.fileExists(atPath: cancelled.marker.path) }
        task.cancel()
        let result = await task.value
        expect(result == nil, "Cancelled get returned metadata")
        try await dead(cancelled)

        let beforeStart = try SnapshotFixture("print q~" + valid + "~;")
        defer { beforeStart.cleanup() }
        let early = Task { await beforeStart.reader().read() }
        early.cancel()
        let earlyResult = await early.value
        expect(earlyResult == nil && !FileManager.default.fileExists(atPath: beforeStart.marker.path), "Pre-cancelled get still launched its subprocess")

        let openAfterJSON = try SnapshotFixture("print q~" + valid + "~; close(STDOUT); sleep 60;")
        defer { openAfterJSON.cleanup() }
        let incomplete = await openAfterJSON.reader(timeout: 0.15).read()
        expect(incomplete == nil, "EOF before a successful process exit bypassed the timeout")
        try await dead(openAfterJSON)
    }

    private static func boundedOutput() async throws {
        let fixture = try SnapshotFixture("print 'x' x (17 * 1024 * 1024); sleep 60;")
        defer { fixture.cleanup() }
        let result = await fixture.reader().read()
        expect(result == nil, "Output larger than 16 MB was accepted")
        try await dead(fixture)
        let nearLimit = try SnapshotFixture(#"print '{"bundleIdentifier":"fixture.player","title":"Large","playing":false,"artworkData":"'; print 'Y' x (1024 * 1024); print '"}';"#)
        defer { nearLimit.cleanup() }
        let accepted = await nearLimit.reader().read()
        expect(accepted?.payload.string("artworkData")?.count == 1024 * 1024, "Bounded capture corrupted a large artwork field")
    }

    private static func sourceLifetime() async throws {
        let fixture = try SnapshotFixture("sleep 60;")
        defer { fixture.cleanup() }
        var owner: SnapshotSource? = SnapshotSource(fixture.reader())
        weak var weakOwner = owner
        defer { weakOwner = nil }
        let reader = owner!.reader
        let operation = Task { await reader.read() }
        try await wait("Source-lifetime fixture did not start") { FileManager.default.fileExists(atPath: fixture.marker.path) }
        owner = nil
        expect(weakOwner == nil, "Awaiting snapshot data retained the reader's source owner")
        operation.cancel()
        _ = await operation.value
        try await dead(fixture)
    }

    private static func concurrentOwnership() async throws {
        let cancelled = try SnapshotFixture("sleep 60;")
        let surviving = try SnapshotFixture("select(undef,undef,undef,0.2); print q~" + valid + "~;")
        defer { cancelled.cleanup(); surviving.cleanup() }
        let first = Task { await cancelled.reader().read() }
        let second = Task { await surviving.reader().read() }
        try await wait("Concurrent fixture get processes did not start") {
            FileManager.default.fileExists(atPath: cancelled.marker.path)
                && FileManager.default.fileExists(atPath: surviving.marker.path)
        }
        first.cancel()
        let firstResult = await first.value
        let secondResult = await second.value
        expect(firstResult == nil && secondResult?.payload.string("title") == "Fixture",
               "Cancelling one snapshot terminated or corrupted an independent snapshot")
        try await dead(cancelled)
    }
}
