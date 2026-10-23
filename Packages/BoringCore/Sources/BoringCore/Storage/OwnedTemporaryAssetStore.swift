import Foundation

public struct OwnedTemporaryAsset: Sendable, Equatable {
    public let id: UUID
    public let url: URL
}

public struct TemporaryAssetLease: Sendable, Hashable {
    public let id: UUID
    public let assetID: UUID
    public let url: URL
}

public enum TemporaryAssetError: Error, Equatable {
    case invalidName
    case unsafeRoot
    case notOwned
    case noInputs
    case missingInput
}

/// Owns its private directory and records each asset independently. Borrowed files and
/// arbitrary URLs in the system temporary directory are never eligible for deletion.
public actor OwnedTemporaryAssetStore {
    public let rootURL: URL
    private let fileManager = FileManager.default
    private var leases: [UUID: TemporaryAssetLease] = [:]
    private var pendingRemoval = Set<UUID>()
    private let archiveCopier = ArchiveInputCopier()

    private struct Manifest: Codable {
        let id: UUID
        let filename: String
        var exported: Bool
        init(id: UUID, filename: String, exported: Bool = false) { self.id = id; self.filename = filename; self.exported = exported }
        private enum CodingKeys: String, CodingKey { case id, filename, exported }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            filename = try values.decode(String.self, forKey: .filename)
            exported = try values.decodeIfPresent(Bool.self, forKey: .exported) ?? false
        }
    }
    private let manifestName = ".boring-asset.json"

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw TemporaryAssetError.unsafeRoot }
        let parent = rootURL.deletingLastPathComponent().resolvingSymlinksInPath()
        self.rootURL = parent.appendingPathComponent(rootURL.lastPathComponent, isDirectory: true).standardizedFileURL
        if FileManager.default.fileExists(atPath: self.rootURL.path) {
            let values = try self.rootURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw TemporaryAssetError.unsafeRoot }
        } else {
            try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.rootURL.path)
    }

    public static func validatedFilename(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", name != ".boring-asset.json",
              !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else { throw TemporaryAssetError.invalidName }
        return name
    }

    public func create(data: Data, suggestedName: String) throws -> OwnedTemporaryAsset {
        let name = try Self.validatedFilename(suggestedName)
        let (id, directory) = try allocateDirectory()
        do {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try writeManifest(id: id, filename: name, directory: directory)
            return OwnedTemporaryAsset(id: id, url: url)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    public func createWebloc(for url: URL) throws -> OwnedTemporaryAsset {
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString],
                                                       format: .xml, options: 0)
        return try create(data: data, suggestedName: "Link.webloc")
    }

    /// Copying is transactional: a failure in any input rolls back this operation, and the
    /// archive is not visible to a caller until all inputs and the compressor have succeeded.
    public func createArchive(from sources: [URL], suggestedName: String = "Archive.zip") async throws -> OwnedTemporaryAsset {
        guard !sources.isEmpty else { throw TemporaryAssetError.noInputs }
        let name = try Self.validatedFilename(suggestedName.hasSuffix(".zip") ? suggestedName : suggestedName + ".zip")
        let (id, directory) = try allocateDirectory()
        let inputs = directory.appendingPathComponent(".inputs", isDirectory: true)
        var succeeded = false
        defer { if !succeeded { try? fileManager.removeItem(at: directory) } }
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: false)
        try await archiveCopier.copy(sources, into: inputs)
        try Task.checkCancellation()
        let archive = directory.appendingPathComponent(name)
        // -y preserves symlinks rather than following them outside the selected directory.
        try await ProcessCommandRunner.run(executable: URL(fileURLWithPath: "/usr/bin/zip"),
                                           arguments: ["-r", "-y", "-q", archive.path, "--", "."],
                                           directory: inputs)
        try Task.checkCancellation()
        try fileManager.removeItem(at: inputs)
        try writeManifest(id: id, filename: name, directory: directory)
        succeeded = true
        return OwnedTemporaryAsset(id: id, url: archive)
    }

    public func isOwned(_ url: URL) -> Bool { (try? ownedManifest(for: url)) != nil }

    public func acquireLease(for url: URL) throws -> TemporaryAssetLease {
        let manifest = try ownedManifest(for: url)
        let lease = TemporaryAssetLease(id: UUID(), assetID: manifest.id, url: url.standardizedFileURL)
        leases[lease.id] = lease
        return lease
    }

    public func release(_ lease: TemporaryAssetLease) throws {
        guard let actual = leases.removeValue(forKey: lease.id), actual == lease else { return }
        if pendingRemoval.contains(actual.assetID), !leases.values.contains(where: { $0.assetID == actual.assetID }) {
            _ = try remove(at: actual.url)
        }
    }

    /// Returns false when removal is deferred until active sharing/preview consumers finish.
    @discardableResult
    public func remove(at url: URL) throws -> Bool {
        let manifest = try ownedManifest(for: url, allowMissingFile: true)
        // URL drop recipients may retain/open the path after a successful drag. Once exported,
        // this is durable user data, not an evictable scratch file or a timed reservation.
        guard !manifest.exported else { return false }
        if leases.values.contains(where: { $0.assetID == manifest.id }) {
            pendingRemoval.insert(manifest.id)
            return false
        }
        let directory = url.standardizedFileURL.deletingLastPathComponent()
        do { try fileManager.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        try fileManager.removeItem(at: directory.appendingPathComponent(manifestName))
        pendingRemoval.remove(manifest.id)
        // Never recursively remove anything subsequently placed beside the owned file.
        if try fileManager.contentsOfDirectory(atPath: directory.path).isEmpty {
            try fileManager.removeItem(at: directory)
        }
        return true
    }

    /// A completed external URL export has no receiver-completion API. Keep its stable path
    /// across source-row removal and app restarts until an explicit export disposal request.
    public func preserveForExternalConsumer(at url: URL) throws {
        let manifest = try ownedManifest(for: url)
        try writeManifest(id: manifest.id, filename: manifest.filename,
                          directory: url.standardizedFileURL.deletingLastPathComponent(), exported: true)
        pendingRemoval.remove(manifest.id)
    }

    public func isDurableExport(_ url: URL) -> Bool { (try? ownedManifest(for: url).exported) == true }

    /// Explicit maintenance/user disposal only. Active consumers must finish before an export
    /// can be erased; ordinary shelf removal never opts into this destructive operation.
    @discardableResult
    public func discardExport(at url: URL) throws -> Bool {
        let manifest = try ownedManifest(for: url, allowMissingFile: true)
        guard !leases.values.contains(where: { $0.assetID == manifest.id }) else { return false }
        try writeManifest(id: manifest.id, filename: manifest.filename,
                          directory: url.standardizedFileURL.deletingLastPathComponent(), exported: false)
        return try remove(at: url)
    }

    private func allocateDirectory() throws -> (UUID, URL) {
        try validateRoot()
        let id = UUID()
        let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        return (id, directory)
    }

    private func validateRoot() throws {
        let values = try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              rootURL.resolvingSymlinksInPath().standardizedFileURL.path == rootURL.path else {
            throw TemporaryAssetError.unsafeRoot
        }
    }

    private func writeManifest(id: UUID, filename: String, directory: URL, exported: Bool = false) throws {
        try JSONEncoder().encode(Manifest(id: id, filename: filename, exported: exported))
            .write(to: directory.appendingPathComponent(manifestName), options: .atomic)
    }

    private func ownedManifest(for url: URL, allowMissingFile: Bool = false) throws -> Manifest {
        try validateRoot()
        guard url.isFileURL else { throw TemporaryAssetError.notOwned }
        let url = url.standardizedFileURL
        let directory = url.deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == rootURL,
              let id = UUID(uuidString: directory.lastPathComponent) else { throw TemporaryAssetError.notOwned }
        let parentValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let fileValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        let manifestURL = directory.appendingPathComponent(manifestName)
        let manifestValues = try manifestURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true,
              fileValues?.isSymbolicLink != true,
              (fileValues?.isRegularFile == true || (allowMissingFile && !fileManager.fileExists(atPath: url.path))),
              manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true else {
            throw TemporaryAssetError.notOwned
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.id == id, manifest.filename == url.lastPathComponent else { throw TemporaryAssetError.notOwned }
        return manifest
    }
}

/// Copying large inputs must not block the asset actor from granting leases to independent
/// previews/shares. Cancellation is checked at each filesystem transaction boundary.
private actor ArchiveInputCopier {
    func copy(_ sources: [URL], into inputs: URL) throws {
        let fileManager = FileManager.default
        for source in sources {
            try Task.checkCancellation()
            guard source.isFileURL, fileManager.fileExists(atPath: source.path) else { throw TemporaryAssetError.missingInput }
            let originalName = try OwnedTemporaryAssetStore.validatedFilename(source.lastPathComponent)
            var destination = inputs.appendingPathComponent(originalName)
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                let stem = source.deletingPathExtension().lastPathComponent
                let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
                destination = inputs.appendingPathComponent("\(stem) (\(suffix))\(ext)")
                suffix += 1
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }
}
