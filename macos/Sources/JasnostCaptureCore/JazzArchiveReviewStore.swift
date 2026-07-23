import Foundation

public enum JazzArchiveReviewStoreError: Error, Equatable, CustomStringConvertible {
    case archiveAlreadyFinalized(String)
    case reviewSealed(String)
    case assertionConflict(String)
    case supersedesConflict(String)
    case corruptAssertion(String)

    public var description: String {
        switch self {
        case let .archiveAlreadyFinalized(id): return "Archive review is finalized: \(id)"
        case let .reviewSealed(id): return "Archive review is sealed: \(id)"
        case let .assertionConflict(id): return "Assertion identity conflicts: \(id)"
        case let .supersedesConflict(id): return "Assertion does not supersede review head: \(id)"
        case let .corruptAssertion(id): return "Assertion is corrupt: \(id)"
        }
    }
}

/// Append-only local review overlay. Assertions remain mutable working state beside the draft and
/// are copied into `assertions/` and inventoried by the deterministic finalizer. Raw evidence is
/// never rewritten as a consequence of confirm, correction, or rejection.
public actor JazzArchiveReviewStore {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private let draftStore: JazzArchiveDraftStore
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        self.draftStore = JazzArchiveDraftStore(root: root, fileManager: fileManager)
    }

    @discardableResult
    public func append(
        archiveId: String,
        assertion: JazzArchiveAssertion
    ) async throws -> Bool {
        guard !fileManager.fileExists(atPath: finalizedDirectory(archiveId).path) else {
            throw JazzArchiveReviewStoreError.archiveAlreadyFinalized(archiveId)
        }
        guard !fileManager.fileExists(atPath: sealURL(archiveId).path) else {
            throw JazzArchiveReviewStoreError.reviewSealed(archiveId)
        }
        let manifest = try await draftStore.manifest(archiveId: archiveId)
        try assertion.validate(manifest: manifest)
        let data = try JazzArchiveCanonicalJSON.encode(assertion)
        let destination = assertionURL(archiveId, assertion.assertionId)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == data else {
                throw JazzArchiveReviewStoreError.assertionConflict(assertion.assertionId)
            }
            return false
        }
        let existing = try assertions(archiveId: archiveId, manifest: manifest)
        if let supersedes = assertion.supersedes,
            !existing.contains(where: { $0.assertionId == supersedes })
        {
            throw JazzArchiveReviewStoreError.supersedesConflict(assertion.assertionId)
        }
        if assertion.target.kind == .archive, assertion.target.id == archiveId,
            assertion.scope == .archive
        {
            let head = try Self.archiveHead(in: existing, archiveId: archiveId)
            guard assertion.supersedes == head?.assertionId else {
                throw JazzArchiveReviewStoreError.supersedesConflict(assertion.assertionId)
            }
        }

        try fileManager.createDirectory(
            at: assertionsDirectory(archiveId), withIntermediateDirectories: true)
        if try !writeOnce(data, to: destination) {
            guard try Data(contentsOf: destination) == data else {
                throw JazzArchiveReviewStoreError.assertionConflict(assertion.assertionId)
            }
            return false
        }
        return true
    }

    public func assertions(archiveId: String) async throws -> [JazzArchiveAssertion] {
        let manifest = try await draftStore.manifest(archiveId: archiveId)
        return try assertions(archiveId: archiveId, manifest: manifest)
    }

    public func latestArchiveAssertion(archiveId: String) async throws -> JazzArchiveAssertion? {
        try Self.archiveHead(
            in: try await assertions(archiveId: archiveId), archiveId: archiveId)
    }

    /// Freeze the append-only review head before finalization snapshots it. A crash after this
    /// point is safely retried against the same assertion set.
    public func seal(archiveId: String) async throws -> [JazzArchiveAssertion] {
        let manifest = try await draftStore.manifest(archiveId: archiveId)
        try fileManager.createDirectory(
            at: assertionsDirectory(archiveId), withIntermediateDirectories: true)
        _ = try writeOnce(Data(), to: sealURL(archiveId))
        return try assertions(archiveId: archiveId, manifest: manifest)
    }

    private func assertions(
        archiveId: String,
        manifest: JazzArchiveManifest
    ) throws -> [JazzArchiveAssertion] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: assertionsDirectory(archiveId),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }
        let values = try urls.filter { $0.pathExtension == "json" }.map { url in
            do {
                let assertion = try Self.decoder.decode(
                    JazzArchiveAssertion.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == assertion.assertionId else {
                    throw JazzArchiveReviewStoreError.corruptAssertion(url.lastPathComponent)
                }
                try assertion.validate(manifest: manifest)
                return assertion
            } catch let error as JazzArchiveReviewStoreError {
                throw error
            } catch {
                throw JazzArchiveReviewStoreError.corruptAssertion(url.lastPathComponent)
            }
        }.sorted { ($0.authoredAt, $0.assertionId) < ($1.authoredAt, $1.assertionId) }
        _ = try Self.archiveHead(in: values, archiveId: archiveId)
        return values
    }

    /// Resolve the append-only review chain structurally, never by wall clock. Exactly one head is
    /// allowed; branches, cycles, and references outside the archive chain fail closed.
    public static func archiveHead(
        in assertions: [JazzArchiveAssertion],
        archiveId: String
    ) throws -> JazzArchiveAssertion? {
        let scoped = assertions.filter {
            $0.target.kind == .archive && $0.target.id == archiveId && $0.scope == .archive
        }
        guard !scoped.isEmpty else { return nil }
        let byId = Dictionary(uniqueKeysWithValues: scoped.map { ($0.assertionId, $0) })
        var superseded = Set<String>()
        for assertion in scoped {
            if let prior = assertion.supersedes {
                guard byId[prior] != nil, superseded.insert(prior).inserted else {
                    throw JazzArchiveReviewStoreError.corruptAssertion(archiveId)
                }
            }
        }
        let heads = scoped.filter { !superseded.contains($0.assertionId) }
        guard heads.count == 1 else {
            throw JazzArchiveReviewStoreError.corruptAssertion(archiveId)
        }
        var visited = Set<String>()
        var cursor: JazzArchiveAssertion? = heads[0]
        while let current = cursor {
            guard visited.insert(current.assertionId).inserted else {
                throw JazzArchiveReviewStoreError.corruptAssertion(archiveId)
            }
            cursor = current.supersedes.flatMap { byId[$0] }
        }
        guard visited.count == scoped.count else {
            throw JazzArchiveReviewStoreError.corruptAssertion(archiveId)
        }
        return heads[0]
    }

    private func writeOnce(_ data: Data, to destination: URL) throws -> Bool {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.linkItem(at: temporary, to: destination)
            return true
        } catch where fileManager.fileExists(atPath: destination.path) {
            return false
        }
    }

    private func assertionsDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent(".review", isDirectory: true)
            .appendingPathComponent(archiveId, isDirectory: true)
            .appendingPathComponent("assertions", isDirectory: true)
    }

    private func assertionURL(_ archiveId: String, _ assertionId: String) -> URL {
        assertionsDirectory(archiveId).appendingPathComponent("\(assertionId).json")
    }

    private func sealURL(_ archiveId: String) -> URL {
        assertionsDirectory(archiveId).deletingLastPathComponent()
            .appendingPathComponent("sealed")
    }

    private func finalizedDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent("\(archiveId).jazz-archive.finalized", isDirectory: true)
    }
}
