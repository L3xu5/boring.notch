import Foundation

/// Positive results only, bounded by age, count and encoded bytes. All encoding and atomic
/// persistence runs on actors; monotonic revisions reject late writes of older snapshots.
public actor LyricsCache {
    private struct Entry: Codable, Sendable {
        var document: LyricsDocument
        var storedAt: Date
        var accessedAt: Date
    }
    private struct Envelope: Codable, Sendable { var version = 1; var entries: [String: Entry] }
    private let fileURL: URL
    private let legacyURLs: [URL]
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let timeToLive: TimeInterval
    private let disk: AtomicJSONStore<Envelope>
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private var revision: UInt64 = 0

    public init(fileURL: URL, legacyURLs: [URL] = [], maximumEntries: Int = 400,
                maximumBytes: Int = 8 * 1024 * 1024, timeToLive: TimeInterval = 30 * 86400) {
        self.fileURL = fileURL; self.legacyURLs = legacyURLs
        self.maximumEntries = max(1, maximumEntries); self.maximumBytes = max(1024, maximumBytes)
        self.timeToLive = max(1, timeToLive)
        disk = AtomicJSONStore(fileURL: fileURL)
    }

    private func load(now: Date) {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL), let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 {
            entries = envelope.entries.filter { !$0.value.document.isEmpty && now.timeIntervalSince($0.value.storedAt) < timeToLive }
        } else {
            // The old v4 shape is compatible with LyricsDocument. Never remove the old copy:
            // an interrupted migration or a rollback to the previous app can still use it.
            for url in legacyURLs {
                if let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode([String: LyricsDocument].self, from: data) {
                    for (key, document) in old where !document.isEmpty {
                        entries[key] = .init(document: document, storedAt: now, accessedAt: now)
                    }
                    break
                }
            }
        }
        trim()
    }
    public func value(for key: String, now: Date = Date()) -> LyricsDocument? {
        load(now: now)
        guard var entry = entries[key], now.timeIntervalSince(entry.storedAt) < timeToLive else {
            entries[key] = nil; return nil
        }
        entry.accessedAt = now; entries[key] = entry
        return entry.document
    }
    public func remove(_ key: String) async {
        load(now: Date()); entries[key] = nil
        await persist()
    }
    public func insert(_ document: LyricsDocument, for key: String, now: Date = Date()) async {
        load(now: now)
        guard !document.isEmpty, (try? JSONEncoder().encode(document).count).map({ $0 <= maximumBytes }) == true else { return }
        entries[key] = .init(document: document, storedAt: now, accessedAt: now)
        trim()
        await persist()
    }
    public var count: Int { entries.count }
    private func trim() {
        let ordered = entries.sorted { $0.value.accessedAt < $1.value.accessedAt }.map(\.key)
        var index = 0
        while entries.count > maximumEntries || ((try? JSONEncoder().encode(Envelope(entries: entries)).count) ?? 0) > maximumBytes {
            guard index < ordered.count else { break }
            entries[ordered[index]] = nil; index += 1
        }
    }
    private func persist() async {
        revision &+= 1
        let snapshot = Envelope(entries: entries)
        _ = try? await disk.save(snapshot, revision: revision)
    }
}
