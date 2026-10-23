import AppKit
import BoringCore
import Combine
import Foundation

private enum ImageFailure: Error { case failed }
private actor SpotifyImageFixture {
    private var pending: [CheckedContinuation<Data, Error>?] = []
    var requestCount: Int { pending.count }
    func fetch(_ url: URL) async throws -> Data {
        // Cancellation intentionally does not resume the native/network fixture: controller
        // identity/revision guards must remain correct even when an old backend completes late.
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func complete(_ index: Int, data: Data?) {
        let continuation = pending[index]; pending[index] = nil
        if let data { continuation?.resume(returning: data) }
        else { continuation?.resume(throwing: ImageFailure.failed) }
    }
}

@MainActor
private final class SpotifyMetadataFixture {
    var title = "A"
    func descriptor() -> NSAppleEventDescriptor {
        let result = NSAppleEventDescriptor.list()
        let values = [NSAppleEventDescriptor(boolean: true), NSAppleEventDescriptor(string: title),
            NSAppleEventDescriptor(string: "Artist"), NSAppleEventDescriptor(string: "Album"),
            NSAppleEventDescriptor(double: 10), NSAppleEventDescriptor(double: 200_000),
            NSAppleEventDescriptor(boolean: false), NSAppleEventDescriptor(boolean: false),
            NSAppleEventDescriptor(int32: 50), NSAppleEventDescriptor(string: "https://fixture.invalid/shared-cover")]
        for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
        return result
    }
}

private struct SpotifyFailure: Error { let message: String }
@main
private struct SpotifyLifecycleTests {
    @MainActor static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw SpotifyFailure(message: message)
    }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw SpotifyFailure(message: message) }
    }
    @MainActor static func main() async throws {
        for oldSucceeds in [true, false] {
            let metadata = SpotifyMetadataFixture(), images = SpotifyImageFixture()
            let controller = SpotifyController(playbackInfo: { metadata.descriptor() },
                image: { try await images.fetch($0) }, isRunning: { true }, observeChanges: false)
            var latest = PlaybackState(bundleIdentifier: "")
            let observation = controller.playbackStatePublisher.sink { latest = $0 }
            await controller.updatePlaybackInfo()
            try await eventually("A cover did not start") { await images.requestCount == 1 }
            metadata.title = "B"
            await controller.updatePlaybackInfo()
            try await eventually("B was blocked behind A's same-URL task slot") { await images.requestCount == 2 }
            await images.complete(0, data: oldSucceeds ? Data("old artwork".utf8) : nil)
            try await Task.sleep(for: .milliseconds(30))
            try expect(latest.title == "B" && latest.artwork == nil, "A's late completion overwrote B")
            await controller.updatePlaybackInfo()
            let count = await images.requestCount
            try expect(count == 2, "A's old completion cleared B's live request and started a duplicate")
            await images.complete(1, data: Data("B artwork".utf8))
            try await eventually("B never received its same-URL cover") { latest.artwork == Data("B artwork".utf8) }
            try expect(latest.title == "B", "Artwork completion restored A metadata")
            controller.stop(); observation.cancel()
        }
        do {
            let metadata = SpotifyMetadataFixture(), images = SpotifyImageFixture()
            let controller = SpotifyController(playbackInfo: { metadata.descriptor() },
                image: { try await images.fetch($0) }, isRunning: { true }, observeChanges: false)
            var latest = PlaybackState(bundleIdentifier: "")
            let observation = controller.playbackStatePublisher.sink { latest = $0 }
            await controller.updatePlaybackInfo()
            try await eventually("stop fixture did not enter image backend") { await images.requestCount == 1 }
            controller.stop()
            await images.complete(0, data: Data("late stopped artwork".utf8))
            try await Task.sleep(for: .milliseconds(30))
            await controller.updatePlaybackInfo()
            let count = await images.requestCount
            try expect(latest.artwork == nil && count == 1, "Stopped Spotify accepted late artwork or restarted work")
            observation.cancel()
        }
        print("Spotify lifecycle: same-URL A-to-B pending success/error, request-slot ownership and stop checks passed (whole production controller; no AppleEvents/player/network)")
    }
}
