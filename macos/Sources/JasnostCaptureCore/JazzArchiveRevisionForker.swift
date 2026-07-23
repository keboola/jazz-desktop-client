import Foundation

public enum JazzArchiveRevisionForkError: Error, Equatable, CustomStringConvertible {
    case sourceNotFinalized(String)
    case destinationExists(String)
    case invalidSource(String)
    case correctionRequired

    public var description: String {
        switch self {
        case let .sourceNotFinalized(id): "Archive revision is not finalized: \(id)"
        case let .destinationExists(id): "Archive revision destination already exists: \(id)"
        case let .invalidSource(id): "Archive revision source is invalid: \(id)"
        case .correctionRequired: "A correction is required to create a new archive revision"
        }
    }
}

public struct JazzArchiveRevisionForkResult: Equatable, Sendable {
    public let archiveId: String
    public let revision: Int
    public let supersedesArchiveId: String
    public let captureIds: [String]

    public init(
        archiveId: String,
        revision: Int,
        supersedesArchiveId: String,
        captureIds: [String]
    ) {
        self.archiveId = archiveId
        self.revision = revision
        self.supersedesArchiveId = supersedesArchiveId
        self.captureIds = captureIds
    }
}

/// Creates a new reviewable revision from immutable local evidence. Observation, artifact, label,
/// and media identities/bytes are copied exactly. Only the archive envelope, session archive links,
/// CaptureCommit revision links, and review overlay are new. The source finalized directory and its
/// queued/uploaded package are never changed.
public actor JazzArchiveRevisionForker {
    private let root: URL
    private let fileManager: FileManager
    private let draftStore: JazzArchiveDraftStore
    private let finalizer: JazzArchiveFinalizer
    private let reviewStore: JazzArchiveReviewStore

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
        draftStore = JazzArchiveDraftStore(root: root, fileManager: fileManager)
        finalizer = JazzArchiveFinalizer(root: root, fileManager: fileManager)
        reviewStore = JazzArchiveReviewStore(root: root, fileManager: fileManager)
    }

    @discardableResult
    public func forkCorrection(
        sourceArchiveId: String,
        correction: String,
        authoredAt: String = Timestamps.iso8601(),
        newArchiveId: String = Identifiers.newArchiveId(),
        assertionId: String = Identifiers.newAssertionId()
    ) async throws -> JazzArchiveRevisionForkResult {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JazzArchiveRevisionForkError.correctionRequired }
        guard sourceArchiveId != newArchiveId else {
            throw JazzArchiveRevisionForkError.destinationExists(newArchiveId)
        }

        let finalized: JazzArchiveFinalizedPackage
        do {
            finalized = try await finalizer.finalize(
                archiveId: sourceArchiveId,
                requireArchiveConfirmation: true)
        } catch let error as JazzArchiveFinalizationError {
            switch error {
            case .captureNotCommitted, .archiveNotConfirmed:
                throw JazzArchiveRevisionForkError.sourceNotFinalized(sourceArchiveId)
            default:
                throw error
            }
        }
        guard finalized.manifest.state == .finalized else {
            throw JazzArchiveRevisionForkError.sourceNotFinalized(sourceArchiveId)
        }

        let sourceManifest = try await draftStore.manifest(archiveId: sourceArchiveId)
        let sourceInventory = try await draftStore.inventory(archiveId: sourceArchiveId)
        guard sourceManifest.revision == finalized.manifest.revision,
            sourceManifest.archiveId == finalized.manifest.archiveId,
            sourceManifest.sessions == finalized.manifest.sessions
        else { throw JazzArchiveRevisionForkError.invalidSource(sourceArchiveId) }

        let destination = draftDirectory(newArchiveId)
        if fileManager.fileExists(atPath: destination.path) {
            return try await verifyExistingFork(
                sourceArchiveId: sourceArchiveId,
                correction: text,
                newArchiveId: newArchiveId,
                assertionId: assertionId)
        }

        let staging = root.appendingPathComponent(
            ".\(newArchiveId).forking-\(Identifiers.newUUIDv7().uuidString.lowercased())",
            isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var published = false
        defer {
            if !published { try? fileManager.removeItem(at: staging) }
        }

        let sourceDirectory = draftDirectory(sourceArchiveId)
        let sessionPaths = Set(sourceManifest.sessions.map(\.path))
        let commitPaths = Set((sourceManifest.captureCommits ?? []).map(\.path))
        var inventoryEntries: [JazzArchiveInventoryEntry] = []
        for entry in sourceInventory.entries.sorted(by: { $0.path < $1.path }) {
            guard !sessionPaths.contains(entry.path), !commitPaths.contains(entry.path) else {
                continue
            }
            let source = try safeURL(root: sourceDirectory, relativePath: entry.path)
            let target = try safeURL(root: staging, relativePath: entry.path)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try JazzArchiveFileIO.copyAtomically(
                source,
                to: target,
                expected: JazzArchiveFileFingerprint(
                    sha256: entry.sha256, byteLength: entry.byteLength),
                fileManager: fileManager)
            inventoryEntries.append(entry)
        }

        let revision = sourceManifest.revision + 1
        var commitRefs: [JazzArchiveCaptureCommitRef] = []
        var sessions: [JazzArchiveSession] = []
        for reference in sourceManifest.sessions {
            var session = try await draftStore.session(
                archiveId: sourceArchiveId, captureId: reference.captureId)
            let oldCommit = try await draftStore.captureCommit(
                archiveId: sourceArchiveId, captureId: reference.captureId)
            var newCommit = oldCommit
            newCommit.commitId = Identifiers.newCaptureCommitId()
            newCommit.revision = revision
            newCommit.supersedesCommitId = oldCommit.commitId
            newCommit.supersedesArchiveId = sourceArchiveId
            try newCommit.validate()

            let commitPath = pathBesideSession(reference, child: "commit.json")
            let commitData = try JazzArchiveCanonicalJSON.encode(newCommit)
            let commitRef = JazzArchiveCaptureCommitRef(
                commitId: newCommit.commitId,
                captureId: session.captureId,
                path: commitPath,
                digest: JazzArchiveDigest.sha256Hex(commitData))
            let commitURL = try safeURL(root: staging, relativePath: commitPath)
            try fileManager.createDirectory(
                at: commitURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try commitData.write(to: commitURL, options: .atomic)
            inventoryEntries.append(entry(path: commitPath, data: commitData))

            session.archiveId = newArchiveId
            session.captureCommit = commitRef
            try session.validate()
            let sessionData = try JazzArchiveCanonicalJSON.encode(session)
            let sessionURL = try safeURL(root: staging, relativePath: reference.path)
            try fileManager.createDirectory(
                at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sessionData.write(to: sessionURL, options: .atomic)
            inventoryEntries.append(entry(path: reference.path, data: sessionData))
            commitRefs.append(commitRef)
            sessions.append(session)
        }

        var manifest = sourceManifest
        manifest.archiveId = newArchiveId
        manifest.revision = revision
        manifest.supersedesArchiveId = sourceArchiveId
        manifest.state = .live
        manifest.createdAt = authoredAt
        manifest.snapshotAt = nil
        manifest.contentDigest = nil
        manifest.captureCommits = commitRefs

        let inventory = JazzArchiveInventory(
            entries: inventoryEntries.sorted { $0.path < $1.path })
        let inventoryData = try JazzArchiveCanonicalJSON.encode(inventory)
        manifest.inventory.digest = JazzArchiveDigest.sha256Hex(inventoryData)
        try manifest.validate()
        guard sessions.allSatisfy({ $0.archiveId == manifest.archiveId }) else {
            throw JazzArchiveRevisionForkError.invalidSource(sourceArchiveId)
        }
        try inventoryData.write(
            to: staging.appendingPathComponent(manifest.inventory.path), options: .atomic)
        try JazzArchiveCanonicalJSON.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        do {
            try fileManager.moveItem(at: staging, to: destination)
            published = true
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            return try await verifyExistingFork(
                sourceArchiveId: sourceArchiveId,
                correction: text,
                newArchiveId: newArchiveId,
                assertionId: assertionId)
        }

        do {
            _ = try await draftStore.manifest(archiveId: newArchiveId)
            _ = try await draftStore.inventory(archiveId: newArchiveId)
            for session in sessions {
                _ = try await draftStore.session(
                    archiveId: newArchiveId, captureId: session.captureId)
                _ = try await draftStore.captureCommit(
                    archiveId: newArchiveId, captureId: session.captureId)
            }
            let actorId = try recorderActorId(in: sessions)
            _ = try await reviewStore.append(
                archiveId: newArchiveId,
                assertion: correctionAssertion(
                    archiveId: newArchiveId,
                    revision: revision,
                    actorId: actorId,
                    text: text,
                    authoredAt: authoredAt,
                    assertionId: assertionId))
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        return JazzArchiveRevisionForkResult(
            archiveId: newArchiveId,
            revision: revision,
            supersedesArchiveId: sourceArchiveId,
            captureIds: sourceManifest.sessions.map(\.captureId))
    }

    private func verifyExistingFork(
        sourceArchiveId: String,
        correction: String,
        newArchiveId: String,
        assertionId: String
    ) async throws -> JazzArchiveRevisionForkResult {
        let manifest = try await draftStore.manifest(archiveId: newArchiveId)
        guard manifest.supersedesArchiveId == sourceArchiveId,
            manifest.state == .live,
            let assertion = try await reviewStore.latestArchiveAssertion(archiveId: newArchiveId),
            assertion.assertionId == assertionId,
            assertion.decision == .correct,
            assertion.value == .string(correction)
        else { throw JazzArchiveRevisionForkError.destinationExists(newArchiveId) }
        return JazzArchiveRevisionForkResult(
            archiveId: newArchiveId,
            revision: manifest.revision,
            supersedesArchiveId: sourceArchiveId,
            captureIds: manifest.sessions.map(\.captureId))
    }

    private func correctionAssertion(
        archiveId: String,
        revision: Int,
        actorId: String,
        text: String,
        authoredAt: String,
        assertionId: String
    ) -> JazzArchiveAssertion {
        JazzArchiveAssertion(
            assertionId: assertionId,
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: archiveId, path: "/review/correction"),
            decision: .correct,
            value: .string(text),
            reason: text,
            authoredByActorId: actorId,
            authoredAt: authoredAt,
            baseRevision: revision,
            scope: .archive,
            provenance: JazzArchiveProvenance(factClass: .corrected, sources: []))
    }

    private func recorderActorId(in sessions: [JazzArchiveSession]) throws -> String {
        guard let actorId = sessions.first?.recorderActorId else {
            throw JazzArchiveRevisionForkError.invalidSource("missing recorder")
        }
        return actorId
    }

    private func entry(path: String, data: Data) -> JazzArchiveInventoryEntry {
        JazzArchiveInventoryEntry(
            path: path,
            byteLength: Int64(data.count),
            sha256: JazzArchiveDigest.sha256Hex(data))
    }

    private func pathBesideSession(_ reference: JazzArchiveSessionRef, child: String) -> String {
        let parent = reference.path.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? child : "\(parent)/\(child)"
    }

    private func safeURL(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
            !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw JazzArchiveRevisionForkError.invalidSource(relativePath) }
        let canonicalRoot = root.standardizedFileURL.path
        let value = root.appendingPathComponent(relativePath).standardizedFileURL
        guard value.path.hasPrefix(canonicalRoot + "/") else {
            throw JazzArchiveRevisionForkError.invalidSource(relativePath)
        }
        return value
    }

    private func draftDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent("\(archiveId).jazz-archive.draft", isDirectory: true)
    }
}
