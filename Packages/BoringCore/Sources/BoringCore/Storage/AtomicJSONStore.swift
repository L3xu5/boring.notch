import Foundation

/// Serialized encoding and atomic disk writes stay off the UI actor. Revisions prevent an
/// older asynchronously scheduled snapshot from overwriting a newer successful save.
public actor AtomicJSONStore<Value: Codable & Sendable> {
    public let fileURL: URL
    private var latestRevision: UInt64 = 0
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
    }

    @discardableResult
    public func save(_ value: Value, revision: UInt64) throws -> Bool {
        guard revision >= latestRevision else { return false }
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
        latestRevision = revision
        return true
    }

    /// Preserve unreadable data for recovery instead of replacing it silently with an empty list.
    public func quarantineCorruptFile() throws -> URL? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let backup = fileURL.appendingPathExtension("corrupt-" + UUID().uuidString)
        try FileManager.default.moveItem(at: fileURL, to: backup)
        return backup
    }
}

public enum CollectionValidation {
    /// A suspended validation may remove only records that are still identical to its snapshot.
    /// Concurrent imports, removals and bookmark refreshes are preserved.
    public static func removingInvalidItems<Item: Identifiable & Equatable & Sendable>(
        from current: [Item], validated snapshot: [Item], invalidIDs: Set<Item.ID>
    ) -> [Item] where Item.ID: Sendable {
        current.filter { item in
            !invalidIDs.contains(item.id) || !snapshot.contains(where: { $0.id == item.id && $0 == item })
        }
    }
}
