import Foundation
import Testing
@testable import BoringCore

private func storageSandbox() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoringStorageTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct StorageTests {
    @Test func onlyOwnedFilesCanBeRemoved() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Owned")
        let store = try OwnedTemporaryAssetStore(rootURL: root)
        let foreign = sandbox.appendingPathComponent("foreign.txt")
        try Data("keep".utf8).write(to: foreign)
        let asset = try await store.create(data: Data("owned".utf8), suggestedName: "owned.txt")
        #expect(await store.isOwned(asset.url))
        do { try await store.remove(at: foreign); Issue.record("Foreign file accepted") } catch {}
        #expect(FileManager.default.fileExists(atPath: foreign.path))
        #expect(try await store.remove(at: asset.url))
        #expect(!FileManager.default.fileExists(atPath: asset.url.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func rejectsTraversalAndSymlinkSubstitution() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = try OwnedTemporaryAssetStore(rootURL: sandbox.appendingPathComponent("Owned"))
        for name in ["../outside", "/absolute", "folder/file", "folder\\file", ".", "..", "\u{0}", ".boring-asset.json"] {
            #expect(throws: TemporaryAssetError.self) { try OwnedTemporaryAssetStore.validatedFilename(name) }
        }
        let foreign = sandbox.appendingPathComponent("foreign")
        try Data("keep".utf8).write(to: foreign)
        let asset = try await store.create(data: Data("owned".utf8), suggestedName: "data")
        try FileManager.default.removeItem(at: asset.url)
        try FileManager.default.createSymbolicLink(at: asset.url, withDestinationURL: foreign)
        do { try await store.remove(at: asset.url); Issue.record("Symlink accepted") } catch {}
        #expect(try Data(contentsOf: foreign) == Data("keep".utf8))
    }

    @Test func leasesDeferDeletionUntilEveryConsumerFinishes() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = try OwnedTemporaryAssetStore(rootURL: sandbox.appendingPathComponent("Owned"))
        let asset = try await store.create(data: Data("payload".utf8), suggestedName: "share.txt")
        let first = try await store.acquireLease(for: asset.url)
        let second = try await store.acquireLease(for: asset.url)
        #expect(try await !store.remove(at: asset.url))
        try await store.release(first)
        #expect(FileManager.default.fileExists(atPath: asset.url.path))
        try await store.release(second)
        #expect(!FileManager.default.fileExists(atPath: asset.url.path))
        try await store.release(second)
    }

    @Test func survivesReopeningAndDoesNotRemoveUnexpectedNeighbors() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Owned")
        let first = try OwnedTemporaryAssetStore(rootURL: root)
        let asset = try await first.create(data: Data([1]), suggestedName: "asset")
        let neighbor = asset.url.deletingLastPathComponent().appendingPathComponent("not-created-by-store")
        try Data([2]).write(to: neighbor)
        let reopened = try OwnedTemporaryAssetStore(rootURL: root)
        #expect(try await reopened.remove(at: asset.url))
        #expect(try Data(contentsOf: neighbor) == Data([2]))
    }

    @Test func weblocEscapesURLAndArchiveIsTransactional() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = try OwnedTemporaryAssetStore(rootURL: sandbox.appendingPathComponent("Owned"))
        let url = URL(string: "https://example.com/?one=1&two=2")!
        let link = try await store.createWebloc(for: url)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: link.url), format: nil) as! [String: String]
        #expect(plist["URL"] == url.absoluteString)
        let file = sandbox.appendingPathComponent("-leading-dash.txt")
        try Data("content".utf8).write(to: file)
        let archive = try await store.createArchive(from: [file])
        #expect(await store.isOwned(archive.url))
        #expect((try Data(contentsOf: archive.url)).count > 0)
        let before = try FileManager.default.contentsOfDirectory(atPath: await store.rootURL.path).count
        do {
            _ = try await store.createArchive(from: [file, sandbox.appendingPathComponent("missing")])
            Issue.record("Incomplete archive accepted")
        } catch {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: await store.rootURL.path).count == before)
        #expect(try Data(contentsOf: file) == Data("content".utf8))
    }

    @Test func cancelledWorkDoesNotPublishAnArchive() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("Owned")
        let store = try OwnedTemporaryAssetStore(rootURL: root)
        let file = sandbox.appendingPathComponent("input")
        try Data([1]).write(to: file)
        let task = Task {
            try Task.checkCancellation()
            return try await store.createArchive(from: [file])
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled archive succeeded") } catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func atomicStoreRejectsStaleSnapshotsAndPreservesCorruptData() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let file = sandbox.appendingPathComponent("items.json")
        let store = AtomicJSONStore<[String]>(fileURL: file)
        #expect(try await store.save(["new"], revision: 2))
        #expect(try await !store.save(["old"], revision: 1))
        #expect(try await store.load() == ["new"])
        try Data("corrupt".utf8).write(to: file)
        let backup = try #require(await store.quarantineCorruptFile())
        #expect(try Data(contentsOf: backup) == Data("corrupt".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func validationPreservesConcurrentImportsRemovalsAndEdits() {
        struct Item: Identifiable, Equatable, Sendable { let id: Int; let bookmark: String }
        let snapshot = [Item(id: 1, bookmark: "old"), Item(id: 2, bookmark: "unchanged"), Item(id: 3, bookmark: "removed")]
        let current = [Item(id: 1, bookmark: "refreshed"), Item(id: 2, bookmark: "unchanged"), Item(id: 4, bookmark: "imported")]
        let retained = CollectionValidation.removingInvalidItems(from: current, validated: snapshot, invalidIDs: [1, 2, 3])
        #expect(retained == [Item(id: 1, bookmark: "refreshed"), Item(id: 4, bookmark: "imported")])
    }
}

struct StorageMissingAssetTests {
    @Test func aMissingOwnedFileCanReleaseItsOwnManifestWithoutTouchingNeighbors() async throws {
        let sandbox = try storageSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = try OwnedTemporaryAssetStore(rootURL: sandbox.appendingPathComponent("Owned"))
        let asset = try await store.create(data: Data([1]), suggestedName: "generated")
        try FileManager.default.removeItem(at: asset.url)
        #expect(try await store.remove(at: asset.url))
        #expect(!FileManager.default.fileExists(atPath: asset.url.deletingLastPathComponent().path))
    }
}
