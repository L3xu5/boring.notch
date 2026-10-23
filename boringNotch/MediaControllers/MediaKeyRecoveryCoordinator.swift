import BoringCore
import Foundation

/// Platform observation and commands are dependencies, not global state. The native-first
/// policy stays pure; task ownership, grace and recent-proof lifetime belong to this object.
@MainActor
final class MediaKeyRecoveryCoordinator {
    private let snapshot: @MainActor () -> MediaKeyRecoverySnapshot
    private let refresh: @MainActor () async -> Void
    private let toggle: @MainActor () async -> Bool
    private let isActive: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var lastPress: Date?
    private var recovered: (owner: String, activity: Date, at: Date)?

    init(snapshot: @escaping @MainActor () -> MediaKeyRecoverySnapshot,
         refresh: @escaping @MainActor () async -> Void,
         toggle: @escaping @MainActor () async -> Bool,
         isActive: @escaping @MainActor () -> Bool,
         now: @escaping @MainActor () -> Date = Date.init,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.snapshot = snapshot; self.refresh = refresh; self.toggle = toggle
        self.isActive = isActive; self.now = now; self.sleep = sleep
    }
    deinit { task?.cancel() }
    func stop() {
        task?.cancel(); task = nil; requestID = UUID(); lastPress = nil; recovered = nil
    }
    func handlePlayPause() {
        task?.cancel(); task = nil; requestID = UUID()
        let ticket = requestID
        let date = now(), previous = lastPress
        lastPress = date
        guard previous.map({ date.timeIntervalSince($0) >= 1.2 }) ?? true, isActive() else { return }
        let before = snapshot()
        let recent = recovered.map {
            $0.owner == before.systemOwner && $0.activity == before.foreignActivity
                && date.timeIntervalSince($0.at) >= 0 && date.timeIntervalSince($0.at) <= 120
        } ?? false
        guard MediaKeyRecoveryPolicy.isCandidate(before, at: before.capturedAt, recentlyRecoveredYandex: recent) else { return }
        task = Task { @MainActor [weak self, sleep] in
            do { try await sleep(.milliseconds(1200)) } catch { return }
            guard let self, !Task.isCancelled, self.requestID == ticket, self.isActive() else { return }
            await self.refresh()
            guard !Task.isCancelled, self.requestID == ticket, self.isActive() else { return }
            let after = self.snapshot()
            guard MediaKeyRecoveryPolicy.shouldRecover(before: before, after: after, at: self.now(), recentlyRecoveredYandex: recent) else { return }
            let accepted = await self.toggle()
            guard accepted, !Task.isCancelled, self.requestID == ticket, self.isActive() else { return }
            if let owner = after.systemOwner, let activity = after.foreignActivity {
                self.recovered = (owner, activity, self.now())
            }
        }
    }
}
