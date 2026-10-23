import Foundation

public enum AssetDragOutcome: Sendable { case cancelled, copied, moved, deleted }

/// The producer acquires its leases before beginning the drag. An in-process drop claims
/// this same ownership synchronously, before returning acceptance and parsing providers.
/// Source row removal is authorized only after the actual receiver finishes successfully.
public final class AssetExportHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private let store: OwnedTemporaryAssetStore?
    private let leases: [TemporaryAssetLease]
    private let onDisposition: @Sendable (Bool) -> Void
    private var sourceOutcome: AssetDragOutcome?
    private var receiverClaimed = false
    private var receiverResult: Bool?
    private var finalized = false

    public init(store: OwnedTemporaryAssetStore?, leases: [TemporaryAssetLease],
                onDisposition: @escaping @Sendable (Bool) -> Void = { _ in }) {
        self.store = store; self.leases = leases; self.onDisposition = onDisposition
    }
    /// No await here: the drop handler owns a reference to already-acquired leases before it
    /// returns true to AppKit. A late claim after source completion is intentionally refused.
    public func claimReceiver() -> AssetExportReceiver? {
        lock.withLock {
            guard !finalized, !receiverClaimed, sourceOutcome == nil else { return nil }
            receiverClaimed = true
            return AssetExportReceiver(owner: self)
        }
    }
    public func sourceEnded(_ outcome: AssetDragOutcome) async {
        let decision = lock.withLock { () -> Decision? in
            guard sourceOutcome == nil else { return nil }
            sourceOutcome = outcome
            return decide()
        }
        if let decision { await finalize(decision) }
    }
    fileprivate func receiverFinished(_ success: Bool) async {
        let decision = lock.withLock { () -> Decision? in
            guard receiverClaimed, receiverResult == nil else { return nil }
            receiverResult = success
            return decide()
        }
        if let decision { await finalize(decision) }
    }
    private enum Decision { case internalReceiver(Bool), externalReceiver(AssetDragOutcome) }
    /// Called only while locked.
    private func decide() -> Decision? {
        guard !finalized, let outcome = sourceOutcome else { return nil }
        if receiverClaimed {
            guard let success = receiverResult else { return nil }
            finalized = true
            return .internalReceiver(success && outcome != .cancelled)
        }
        finalized = true
        return .externalReceiver(outcome)
    }
    private func finalize(_ decision: Decision) async {
        var mayRemoveSourceRow = false
        switch decision {
        case .internalReceiver(let success): mayRemoveSourceRow = success
        case .externalReceiver(let outcome):
            switch outcome {
            case .cancelled: break
            case .deleted: mayRemoveSourceRow = true
            case .copied, .moved:
                mayRemoveSourceRow = true
                if let store {
                    for lease in leases {
                        // A completed move can already have transferred the physical file.
                        if outcome == .moved, !FileManager.default.fileExists(atPath: lease.url.path) { continue }
                        do { try await store.preserveForExternalConsumer(at: lease.url) }
                        catch { mayRemoveSourceRow = false }
                    }
                }
            }
        }
        onDisposition(mayRemoveSourceRow)
        if let store { for lease in leases { try? await store.release(lease) } }
    }
    deinit {
        guard !lock.withLock({ finalized }), let store else { return }
        let leases = leases
        Task { for lease in leases { try? await store.release(lease) } }
    }
}

/// Dropping a cancelled parsing/share operation releases its producer safely instead of
/// leaving a permanent lease or pretending that data was successfully exported.
public final class AssetExportReceiver: @unchecked Sendable {
    private let owner: AssetExportHandoff
    private let lock = NSLock()
    private var completed = false
    fileprivate init(owner: AssetExportHandoff) { self.owner = owner }
    public func finish(success: Bool) async {
        let shouldFinish = lock.withLock { if completed { return false }; completed = true; return true }
        if shouldFinish { await owner.receiverFinished(success) }
    }
    deinit {
        guard !lock.withLock({ completed }) else { return }
        let owner = owner
        Task { await owner.receiverFinished(false) }
    }
}
