import AppKit
import Foundation

private struct ShelfPreviewFailure: Error { let message: String }
@main private struct ShelfPreviewIsolationTests {
    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--load-error-mode") {
            try await checkUnreadStorageWriteFence()
            return
        }
        guard ShelfStorageEnvironment.isIsolatedPreview,
              let flag = CommandLine.arguments.firstIndex(of: "--fixture-root"), CommandLine.arguments.indices.contains(flag + 1) else {
            throw ShelfPreviewFailure(message: "The runner must supply an exact isolated preview bundle, flag and fixture root")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        let inaccessible = root.appendingPathComponent("inaccessible-shelf.json")
        let bytes = Data("fixture bytes that must not be loaded, migrated or replaced".utf8)
        try bytes.write(to: inaccessible)
        let rawBookmark = try inaccessible.bookmarkData(options: [])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inaccessible.path)
        let before = try FileManager.default.attributesOfItem(atPath: inaccessible.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inaccessible.path) }

        let defaultFactory = ShelfPersistenceService(liveURL: { fatalError("Preview evaluated the production path factory") })
        let defaultItems = try await defaultFactory.load()
        precondition(defaultItems.isEmpty)
        let injected = ShelfPersistenceService(fileURL: inaccessible, liveURL: { fatalError("Preview evaluated a live factory") })
        let initialItems = try await injected.load()
        precondition(initialItems.isEmpty)
        let malformedFile = ShelfItem(kind: .file(bookmark: rawBookmark), isTemporary: true)
        try await injected.save([malformedFile], revision: 1)
        let savedItems = try await injected.load()
        precondition(savedItems == [malformedFile])
        let state = ShelfStateViewModel(persistence: injected)
        try await Task.sleep(for: .milliseconds(25))
        state.cleanupInvalidItems()
        state.remove(malformedFile)
        precondition(Bookmark(data: rawBookmark).resolveURL() == nil)
        do { _ = try Bookmark(url: inaccessible); throw ShelfPreviewFailure(message: "Preview created a live bookmark") }
        catch is CocoaError { }
        let details = await ShelfMetadataService.shared.details(for: malformedFile)
        precondition(details.fileURL == nil && details.displayName == "Preview file")
        let thumbnail = await ThumbnailService.shared.thumbnail(for: inaccessible, size: .init(width: 32, height: 32))
        precondition(thumbnail == nil)

        let forbiddenOwnedRoot = root.appendingPathComponent("must-not-create-owned-store", isDirectory: true)
        let temporary = TemporaryFileStorageService(rootURL: forbiddenOwnedRoot, liveRoot: { fatalError("Preview requested live owned storage") })
        guard let created = await temporary.createTempFile(for: .text("preview fixture")) else {
            throw ShelfPreviewFailure(message: "Isolated owned store could not create its own fixture")
        }
        precondition(created.standardizedFileURL.path.hasPrefix(ShelfStorageEnvironment.previewOwnedRoot.standardizedFileURL.path + "/"))
        precondition(!FileManager.default.fileExists(atPath: forbiddenOwnedRoot.path))
        temporary.removeTemporaryFileIfNeeded(at: inaccessible)
        try await Task.sleep(for: .milliseconds(25))
        let after = try FileManager.default.attributesOfItem(atPath: inaccessible.path)
        precondition(before[.modificationDate] as? Date == after[.modificationDate] as? Date)
        precondition(before[.size] as? NSNumber == after[.size] as? NSNumber)
        precondition(!FileManager.default.fileExists(atPath: inaccessible.appendingPathExtension("corrupt").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inaccessible.path)
        let preserved = try Data(contentsOf: inaccessible)
        precondition(preserved == bytes)
        temporary.removeTemporaryFileIfNeeded(at: created)
        let calendars = CalendarService(storeFactory: { fatalError("Preview constructed a live EventKit store") })
        let lists = await calendars.calendars()
        let events = await calendars.events(from: Date(), to: Date().addingTimeInterval(60), calendars: ["inaccessible-private-calendar"])
        let permission = try await calendars.requestAccess(to: .event)
        await calendars.setReminderCompleted(reminderID: "must-not-write", completed: true)
        precondition(lists.isEmpty && events.isEmpty && !permission)
        print("PASS preview persistence is memory-only, live factories/bookmarks/cleanup are blocked, owned storage is isolated")
    }
    @MainActor private static func checkUnreadStorageWriteFence() async throws {
        guard !ShelfStorageEnvironment.isIsolatedPreview,
              let flag = CommandLine.arguments.firstIndex(of: "--fixture-root"), CommandLine.arguments.indices.contains(flag + 1) else {
            throw ShelfPreviewFailure(message: "The live-path fixture requires an injected temporary root")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
        let candidate = root.appendingPathComponent("unread-storage.json")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        let storage = ShelfPersistenceService(fileURL: candidate, liveURL: { fatalError("Test attempted production storage") })
        var loadFailed = false
        do { _ = try await storage.load() } catch { loadFailed = true }
        precondition(loadFailed)
        try FileManager.default.removeItem(at: candidate)
        let original = [ShelfItem(kind: .text(string: "Original fixture"))]
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: candidate)
        var saveBlocked = false
        do { try await storage.save([.init(kind: .text(string: "Must not replace unread data"))], revision: 2) }
        catch { saveBlocked = true }
        let retained = try Data(contentsOf: candidate)
        precondition(saveBlocked && retained == bytes)
        let loaded = try await storage.load()
        precondition(loaded == original)
        try await storage.save([.init(kind: .text(string: "Now authorized after successful load"))], revision: 3)
        let changed = try Data(contentsOf: candidate)
        precondition(changed != bytes)
        print("PASS unread storage blocks writes until a successful load; original bytes preserved")
    }

}
