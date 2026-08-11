import Foundation

public enum JazzArchiveRevisionForkError: Error, Equatable, CustomStringConvertible {
    case sourceNotFinalized(String)
    case destinationExists(String)
    case invalidSource(String)
    case intentConflict(String)
    case correctionRequired

    public var description: String {
        switch self {
        case let .sourceNotFinalized(id): "Archive revision is not finalized: \(id)"
        case let .destinationExists(id): "Archive revision destination already exists: \(id)"
        case let .invalidSource(id): "Archive revision source is invalid: \(id)"
        case let .intentConflict(id): "Archive revision intent conflicts: \(id)"
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
    private struct ForkIntent: Codable, Equatable {
        let schemaVersion: Int
        let sourceArchiveId: String
        let correction: String
        let authoredAt: String
        let newArchiveId: String
        let assertionId: String
    }

    private let root: URL
    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability
    private let draftStore: JazzArchiveDraftStore
    private let finalizer: JazzArchiveFinalizer
    private let reviewStore: JazzArchiveReviewStore

    public init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        draftStore = JazzArchiveDraftStore(
            root: root, durability: durability, fileManager: fileManager)
        finalizer = JazzArchiveFinalizer(
            root: root, durability: durability, fileManager: fileManager)
        reviewStore = JazzArchiveReviewStore(
            root: root, durability: durability, fileManager: fileManager)
    }

    @discardableResult
    public func forkCorrection(
        sourceArchiveId: String,
        correction: String,
        authoredAt: String? = nil,
        newArchiveId: String? = nil,
        assertionId: String? = nil
    ) async throws -> JazzArchiveRevisionForkResult {
        let text = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw JazzArchiveRevisionForkError.correctionRequired }
        let intent = try resolveForkIntent(
            sourceArchiveId: sourceArchiveId,
            correction: text,
            authoredAt: authoredAt,
            newArchiveId: newArchiveId,
            assertionId: assertionId)
        let authoredAt = intent.authoredAt
        let newArchiveId = intent.newArchiveId
        let assertionId = intent.assertionId

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
            return try await completePublishedFork(
                sourceManifest: sourceManifest,
                sourceInventory: sourceInventory,
                sourceArchiveId: sourceArchiveId,
                correction: text,
                authoredAt: authoredAt,
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

        try durability.synchronizeTree(staging, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: staging, to: destination)
            published = true
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            return try await completePublishedFork(
                sourceManifest: sourceManifest,
                sourceInventory: sourceInventory,
                sourceArchiveId: sourceArchiveId,
                correction: text,
                authoredAt: authoredAt,
                newArchiveId: newArchiveId,
                assertionId: assertionId)
        }
        return try await completePublishedFork(
            sourceManifest: sourceManifest,
            sourceInventory: sourceInventory,
            sourceArchiveId: sourceArchiveId,
            correction: text,
            authoredAt: authoredAt,
            newArchiveId: newArchiveId,
            assertionId: assertionId)
    }

    /// Finish the exact same fork intent after any post-publication failure. Once the destination
    /// directory exists it is canonical evidence and is never deleted. A retry first proves that
    /// every copied byte and rewritten envelope belongs to this source/revision, then idempotently
    /// appends (or re-synchronizes) the exact correction assertion.
    private func completePublishedFork(
        sourceManifest: JazzArchiveManifest,
        sourceInventory: JazzArchiveInventory,
        sourceArchiveId: String,
        correction: String,
        authoredAt: String,
        newArchiveId: String,
        assertionId: String
    ) async throws -> JazzArchiveRevisionForkResult {
        try synchronizePublishedDraft(draftDirectory(newArchiveId))
        let manifest = try await draftStore.manifest(archiveId: newArchiveId)
        let inventory = try await draftStore.inventory(archiveId: newArchiveId)
        guard sourceManifest.archiveId == sourceArchiveId,
            manifest.archiveId == newArchiveId,
            manifest.revision == sourceManifest.revision + 1,
            manifest.supersedesArchiveId == sourceArchiveId,
            manifest.state == .live,
            manifest.createdAt == authoredAt,
            manifest.snapshotAt == nil,
            manifest.contentDigest == nil
        else { throw JazzArchiveRevisionForkError.destinationExists(newArchiveId) }

        var normalizedManifest = manifest
        normalizedManifest.archiveId = sourceManifest.archiveId
        normalizedManifest.revision = sourceManifest.revision
        normalizedManifest.supersedesArchiveId = sourceManifest.supersedesArchiveId
        normalizedManifest.state = sourceManifest.state
        normalizedManifest.createdAt = sourceManifest.createdAt
        normalizedManifest.snapshotAt = sourceManifest.snapshotAt
        normalizedManifest.contentDigest = sourceManifest.contentDigest
        normalizedManifest.inventory = sourceManifest.inventory
        normalizedManifest.captureCommits = sourceManifest.captureCommits
        guard normalizedManifest == sourceManifest else {
            throw JazzArchiveRevisionForkError.destinationExists(newArchiveId)
        }

        let rewrittenPaths = Set(
            sourceManifest.sessions.map(\.path)
                + (sourceManifest.captureCommits ?? []).map(\.path))
        guard sourceInventory.entries.filter({ !rewrittenPaths.contains($0.path) })
            == inventory.entries.filter({ !rewrittenPaths.contains($0.path) })
        else { throw JazzArchiveRevisionForkError.destinationExists(newArchiveId) }

        var sessions: [JazzArchiveSession] = []
        for reference in sourceManifest.sessions {
            let sourceSession = try await draftStore.session(
                archiveId: sourceArchiveId,
                captureId: reference.captureId)
            let sourceCommit = try await draftStore.captureCommit(
                archiveId: sourceArchiveId,
                captureId: reference.captureId)
            let destinationSession = try await draftStore.session(
                archiveId: newArchiveId,
                captureId: reference.captureId)
            let destinationCommit = try await draftStore.captureCommit(
                archiveId: newArchiveId,
                captureId: reference.captureId)
            guard let destinationCommitRef = destinationSession.captureCommit,
                manifest.captureCommits?.contains(destinationCommitRef) == true,
                destinationCommit.revision == manifest.revision,
                destinationCommit.supersedesCommitId == sourceCommit.commitId,
                destinationCommit.supersedesArchiveId == sourceArchiveId
            else { throw JazzArchiveRevisionForkError.destinationExists(newArchiveId) }

            var normalizedSession = destinationSession
            normalizedSession.archiveId = sourceSession.archiveId
            normalizedSession.captureCommit = sourceSession.captureCommit
            var normalizedCommit = destinationCommit
            normalizedCommit.commitId = sourceCommit.commitId
            normalizedCommit.revision = sourceCommit.revision
            normalizedCommit.supersedesCommitId = sourceCommit.supersedesCommitId
            normalizedCommit.supersedesArchiveId = sourceCommit.supersedesArchiveId
            guard normalizedSession == sourceSession,
                normalizedCommit == sourceCommit
            else { throw JazzArchiveRevisionForkError.destinationExists(newArchiveId) }
            sessions.append(destinationSession)
        }

        let expectedAssertion = correctionAssertion(
            archiveId: newArchiveId,
            revision: manifest.revision,
            actorId: try recorderActorId(in: sessions),
            text: correction,
            authoredAt: authoredAt,
            assertionId: assertionId)
        _ = try await reviewStore.append(
            archiveId: newArchiveId,
            assertion: expectedAssertion)
        guard try await reviewStore.assertions(archiveId: newArchiveId)
            .contains(expectedAssertion)
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

    private func synchronizePublishedDraft(_ directory: URL) throws {
        try durability.synchronizeTree(directory, fileManager: fileManager)
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    /// Persist caller-stable fork identity before creating a draft. The default UI path therefore
    /// recovers the same archive/assertion IDs after a barrier failure or app relaunch rather than
    /// abandoning a published orphan and minting another revision.
    private func resolveForkIntent(
        sourceArchiveId: String,
        correction: String,
        authoredAt: String?,
        newArchiveId: String?,
        assertionId: String?
    ) throws -> ForkIntent {
        let supplied = [authoredAt != nil, newArchiveId != nil, assertionId != nil]
        guard supplied.allSatisfy({ $0 }) || supplied.allSatisfy({ !$0 }) else {
            throw JazzArchiveRevisionForkError.intentConflict(
                "authoredAt, newArchiveId and assertionId must be supplied together")
        }
        let proposed = ForkIntent(
            schemaVersion: 1,
            sourceArchiveId: sourceArchiveId,
            correction: correction,
            authoredAt: authoredAt ?? Timestamps.iso8601(),
            newArchiveId: newArchiveId ?? Identifiers.newArchiveId(),
            assertionId: assertionId ?? Identifiers.newAssertionId())
        try validateForkIntent(proposed)
        let destination = forkIntentURL(sourceArchiveId: sourceArchiveId, correction: correction)
        let data = try JazzArchiveCanonicalJSON.encode(proposed)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try durability.synchronizeRegularFile(
            temporary, permissions: Int16(0o600))
        do {
            try fileManager.linkItem(at: temporary, to: destination)
        } catch where fileManager.fileExists(atPath: destination.path) {
            let existing = try loadForkIntent(destination)
            if supplied.contains(true), existing != proposed {
                throw JazzArchiveRevisionForkError.intentConflict(
                    destination.lastPathComponent)
            }
            try synchronizeForkIntent(destination)
            return existing
        }
        try synchronizeForkIntent(destination)
        return proposed
    }

    private func loadForkIntent(_ url: URL) throws -> ForkIntent {
        do {
            let intent = try JSONDecoder().decode(
                ForkIntent.self, from: Data(contentsOf: url))
            try validateForkIntent(intent)
            guard url == forkIntentURL(
                sourceArchiveId: intent.sourceArchiveId,
                correction: intent.correction)
            else {
                throw JazzArchiveRevisionForkError.intentConflict(
                    url.lastPathComponent)
            }
            return intent
        } catch let error as JazzArchiveRevisionForkError {
            throw error
        } catch {
            throw JazzArchiveRevisionForkError.intentConflict(
                url.lastPathComponent)
        }
    }

    private func validateForkIntent(_ intent: ForkIntent) throws {
        guard intent.schemaVersion == 1,
            isPrefixedUUIDv7(intent.sourceArchiveId, prefix: "ar"),
            isPrefixedUUIDv7(intent.newArchiveId, prefix: "ar"),
            isPrefixedUUIDv7(intent.assertionId, prefix: "asrt"),
            intent.sourceArchiveId != intent.newArchiveId,
            intent.correction == intent.correction.trimmingCharacters(
                in: .whitespacesAndNewlines),
            !intent.correction.isEmpty,
            Timestamps.parse(intent.authoredAt) != nil
        else {
            throw JazzArchiveRevisionForkError.intentConflict(
                intent.newArchiveId)
        }
    }

    private func synchronizeForkIntent(_ file: URL) throws {
        try durability.synchronizeRegularFile(
            file, permissions: Int16(0o600))
        try durability.synchronizeDirectory(file.deletingLastPathComponent())
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func forkIntentURL(
        sourceArchiveId: String,
        correction: String
    ) -> URL {
        var data = Data(sourceArchiveId.utf8)
        data.append(0)
        data.append(contentsOf: correction.utf8)
        let digest = JazzArchiveDigest.sha256Hex(data)
        return root
            .appendingPathComponent(".revision-fork-intents", isDirectory: true)
            .appendingPathComponent("\(digest).json")
    }

    private func isPrefixedUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else { return false }
        let uuid = String(value.dropFirst(marker.count))
        guard uuid == uuid.lowercased(),
            uuid.count == 36,
            uuid[uuid.index(uuid.startIndex, offsetBy: 14)] == "7",
            let parsed = UUID(uuidString: uuid)
        else { return false }
        let canonical = parsed.uuidString.lowercased()
        guard canonical == uuid else { return false }
        let variant = uuid[uuid.index(uuid.startIndex, offsetBy: 19)]
        return ["8", "9", "a", "b"].contains(variant)
    }
}
