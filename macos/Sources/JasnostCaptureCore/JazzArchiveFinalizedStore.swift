import Foundation

/// Product limits for untrusted portable archives. Every value is checked before structured data
/// is materialized. The defaults intentionally match the server-side import envelope.
public struct JazzArchiveImportLimits: Equatable, Sendable {
    public var maxArchiveBytes: Int64
    public var maxEntries: Int
    public var maxEntryBytes: Int64
    public var maxTotalExpandedBytes: Int64
    public var maxTotalStructuredBytes: Int64
    public var maxJSONEntryBytes: Int64
    public var maxNDJSONLineBytes: Int
    public var maxNDJSONRecords: Int
    public var maxPathBytes: Int

    public init(
        maxArchiveBytes: Int64 = 2 * 1024 * 1024 * 1024,
        maxEntries: Int = 10_000,
        maxEntryBytes: Int64 = 512 * 1024 * 1024,
        maxTotalExpandedBytes: Int64 = 4 * 1024 * 1024 * 1024,
        maxTotalStructuredBytes: Int64 = 256 * 1024 * 1024,
        maxJSONEntryBytes: Int64 = 32 * 1024 * 1024,
        maxNDJSONLineBytes: Int = 4 * 1024 * 1024,
        maxNDJSONRecords: Int = 250_000,
        maxPathBytes: Int = 1024
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntries = maxEntries
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalExpandedBytes = maxTotalExpandedBytes
        self.maxTotalStructuredBytes = maxTotalStructuredBytes
        self.maxJSONEntryBytes = maxJSONEntryBytes
        self.maxNDJSONLineBytes = maxNDJSONLineBytes
        self.maxNDJSONRecords = maxNDJSONRecords
        self.maxPathBytes = maxPathBytes
    }

    func validate() throws {
        guard maxArchiveBytes > 0, maxEntries > 0, maxEntryBytes > 0,
            maxTotalExpandedBytes > 0, maxTotalStructuredBytes > 0,
            maxJSONEntryBytes > 0, maxNDJSONLineBytes > 0, maxNDJSONRecords > 0,
            maxPathBytes > 0
        else { throw JazzArchiveImportError.invalidLimits }
    }
}

public enum JazzArchiveImportError: Error, Equatable, CustomStringConvertible {
    case invalidLimits
    case sourceNotRegularFile
    case archiveTooLarge
    case entryLimitExceeded(String)
    case malformedZIP(String)
    case unsupportedZIPFeature(String)
    case unsafeEntry(String)
    case duplicateEntry(String)
    case integrityMismatch(String)
    case invalidArchive(String)
    case archiveConflict(String)
    case publishFailed(String)

    public var description: String {
        switch self {
        case .invalidLimits:
            return "Jazz Archive import limits are invalid"
        case .sourceNotRegularFile:
            return "The selected Jazz Archive is not a regular file"
        case .archiveTooLarge:
            return "The selected Jazz Archive exceeds the configured package limit"
        case let .entryLimitExceeded(detail):
            return "Jazz Archive resource limit exceeded: \(detail)"
        case let .malformedZIP(detail):
            return "Malformed deterministic ZIP32 package: \(detail)"
        case let .unsupportedZIPFeature(detail):
            return "Unsupported ZIP feature: \(detail)"
        case let .unsafeEntry(path):
            return "Unsafe Jazz Archive entry: \(path)"
        case let .duplicateEntry(path):
            return "Colliding Jazz Archive entry: \(path)"
        case let .integrityMismatch(path):
            return "Jazz Archive integrity mismatch: \(path)"
        case let .invalidArchive(detail):
            return "Invalid Jazz Archive contract: \(detail)"
        case let .archiveConflict(id):
            return "A different Jazz Archive already uses \(id)"
        case let .publishFailed(detail):
            return "Jazz Archive could not be published: \(detail)"
        }
    }
}

/// A fully verified immutable directory snapshot. The canonical files are kept separately from
/// import/delivery metadata, so this value is also valid for locally finalized captures.
public struct JazzArchiveFinalizedSnapshot: Sendable {
    public let directoryURL: URL
    public let manifest: JazzArchiveManifest
    public let inventory: JazzArchiveInventory
    public let sessions: [JazzArchiveSession]
    public let recordsByCapture: [String: [JazzArchiveRecord]]
    public let labelsByCapture: [String: [JazzArchiveLabel]]
    public let artifactsByCapture: [String: [JazzArchiveArtifact]]
    public let commitsByCapture: [String: JazzArchiveCaptureCommit]
    public let assertions: [JazzArchiveAssertion]

    let fileFingerprints: [String: JazzArchiveFileFingerprint]

    public func session(captureId: String) throws -> JazzArchiveSession {
        guard let value = sessions.first(where: { $0.captureId == captureId }) else {
            throw JazzArchiveImportError.invalidArchive("missing capture \(captureId)")
        }
        return value
    }

    public func records(captureId: String) throws -> [JazzArchiveRecord] {
        guard let value = recordsByCapture[captureId] else {
            throw JazzArchiveImportError.invalidArchive("missing records for \(captureId)")
        }
        return value
    }

    public func artifacts(captureId: String) throws -> [JazzArchiveArtifact] {
        guard let value = artifactsByCapture[captureId] else {
            throw JazzArchiveImportError.invalidArchive("missing artifacts for \(captureId)")
        }
        return value
    }

    public func labels(captureId: String) throws -> [JazzArchiveLabel] {
        guard let value = labelsByCapture[captureId] else {
            throw JazzArchiveImportError.invalidArchive("missing labels for \(captureId)")
        }
        return value
    }

    public func captureCommit(captureId: String) throws -> JazzArchiveCaptureCommit {
        guard let value = commitsByCapture[captureId] else {
            throw JazzArchiveImportError.invalidArchive("missing CaptureCommit for \(captureId)")
        }
        return value
    }
}

/// Read-only access to immutable local and imported snapshots. Verification is cached only after a
/// complete contract pass; no draft transaction recovery or mutation API is reachable here.
public actor JazzArchiveFinalizedStore {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private let limits: JazzArchiveImportLimits
    private var cache: [String: JazzArchiveFinalizedSnapshot] = [:]

    public init(
        root: URL,
        fileManager: FileManager = .default,
        limits: JazzArchiveImportLimits = JazzArchiveImportLimits()
    ) {
        self.root = root
        self.fileManager = fileManager
        self.limits = limits
    }

    public func contains(archiveId: String) -> Bool {
        fileManager.fileExists(atPath: finalizedDirectory(archiveId).path)
    }

    public func archiveIds() -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        else { return [] }
        let suffix = ".jazz-archive.finalized"
        return entries.compactMap { url -> String? in
            guard url.lastPathComponent.hasSuffix(suffix),
                let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                values.isDirectory == true, values.isSymbolicLink != true
            else { return nil }
            let archiveId = String(url.lastPathComponent.dropLast(suffix.count))
            guard !archiveId.isEmpty else { return nil }
            return archiveId
        }.sorted()
    }

    public func snapshot(archiveId: String) throws -> JazzArchiveFinalizedSnapshot {
        if let cached = cache[archiveId] { return cached }
        let verified = try JazzArchiveSnapshotVerifier.verify(
            directory: finalizedDirectory(archiveId),
            expectedArchiveId: archiveId,
            limits: limits,
            fileManager: fileManager)
        cache[archiveId] = verified
        return verified
    }

    public func invalidate(archiveId: String) {
        cache.removeValue(forKey: archiveId)
    }

    public func artifactFile(
        archiveId: String,
        captureId: String,
        artifactId: String
    ) throws -> JazzArchiveVerifiedArtifactFile {
        let verified = try snapshot(archiveId: archiveId)
        let artifact = try verified.artifacts(captureId: captureId).first {
            $0.artifactId == artifactId
        }
        guard let artifact else {
            throw JazzArchiveImportError.invalidArchive("missing artifact \(artifactId)")
        }
        let fingerprint = verified.fileFingerprints[artifact.content.path]
        guard fingerprint == JazzArchiveFileFingerprint(
            sha256: artifact.content.sha256,
            byteLength: artifact.content.byteLength)
        else { throw JazzArchiveImportError.integrityMismatch(artifact.content.path) }
        return JazzArchiveVerifiedArtifactFile(
            url: verified.directoryURL.appendingPathComponent(artifact.content.path),
            artifact: artifact)
    }

    private func finalizedDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent(
            "\(archiveId).jazz-archive.finalized", isDirectory: true)
    }
}

enum JazzArchiveSnapshotVerifier {
    static func verify(
        directory: URL,
        expectedArchiveId: String? = nil,
        limits: JazzArchiveImportLimits,
        fileManager: FileManager
    ) throws -> JazzArchiveFinalizedSnapshot {
        try limits.validate()
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw JazzArchiveImportError.invalidArchive("finalized snapshot is not a directory")
        }

        let fingerprints = try scanFiles(
            directory: directory, limits: limits, fileManager: fileManager)
        guard fingerprints["manifest.json"] != nil, fingerprints["inventory.json"] != nil else {
            throw JazzArchiveImportError.invalidArchive("manifest.json or inventory.json is missing")
        }

        let manifestData = try structuredData(
            path: "manifest.json",
            directory: directory,
            fingerprints: fingerprints,
            limit: limits.maxJSONEntryBytes)
        let manifest = try decodeJSON(
            JazzArchiveManifest.self, data: manifestData, path: "manifest.json")
        try wrapContract("manifest.json") { try manifest.validate() }
        guard manifest.state == .finalized, let contentDigest = manifest.contentDigest else {
            throw JazzArchiveImportError.invalidArchive("manifest is not finalized")
        }
        if let expectedArchiveId, manifest.archiveId != expectedArchiveId {
            throw JazzArchiveImportError.archiveConflict(expectedArchiveId)
        }
        var unsignedManifest = manifest
        unsignedManifest.contentDigest = nil
        guard JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(unsignedManifest)) == contentDigest
        else { throw JazzArchiveImportError.integrityMismatch("manifest.contentDigest") }

        let inventoryData = try structuredData(
            path: "inventory.json",
            directory: directory,
            fingerprints: fingerprints,
            limit: limits.maxJSONEntryBytes)
        let inventory = try decodeJSON(
            JazzArchiveInventory.self, data: inventoryData, path: "inventory.json")
        try wrapContract("inventory.json") { try inventory.validate() }
        guard inventory.entries == inventory.entries.sorted(by: { $0.path < $1.path }) else {
            throw JazzArchiveImportError.invalidArchive("inventory entries are not canonical")
        }
        guard JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(inventory)) == manifest.inventory.digest
        else { throw JazzArchiveImportError.integrityMismatch("manifest.inventory.digest") }

        var expectedFiles = Set(["manifest.json", "inventory.json"])
        for entry in inventory.entries {
            guard entry.path != "manifest.json", entry.path != "inventory.json",
                !entry.path.hasPrefix("sync/")
            else { throw JazzArchiveImportError.invalidArchive("invalid inventory path \(entry.path)") }
            expectedFiles.insert(entry.path)
            guard fingerprints[entry.path] == JazzArchiveFileFingerprint(
                sha256: entry.sha256, byteLength: entry.byteLength)
            else { throw JazzArchiveImportError.integrityMismatch(entry.path) }
        }
        guard expectedFiles == Set(fingerprints.keys) else {
            let extra = Set(fingerprints.keys).subtracting(expectedFiles).sorted()
            let missing = expectedFiles.subtracting(fingerprints.keys).sorted()
            let detail = !extra.isEmpty ? "unlisted \(extra[0])" : "missing \(missing.first ?? "file")"
            throw JazzArchiveImportError.invalidArchive("inventory coverage: \(detail)")
        }

        try validateSupportedContracts(manifest)
        let commitRefs = manifest.captureCommits ?? []
        guard commitRefs.count == manifest.sessions.count else {
            throw JazzArchiveImportError.invalidArchive("CaptureCommit coverage")
        }
        let refsByCapture = Dictionary(
            uniqueKeysWithValues: commitRefs.map { ($0.captureId, $0) })

        var sessions: [JazzArchiveSession] = []
        var recordsByCapture: [String: [JazzArchiveRecord]] = [:]
        var labelsByCapture: [String: [JazzArchiveLabel]] = [:]
        var artifactsByCapture: [String: [JazzArchiveArtifact]] = [:]
        var commitsByCapture: [String: JazzArchiveCaptureCommit] = [:]
        var everyObservation = Set<String>()
        var everyLabel = Set<String>()
        var everyArtifact = Set<String>()
        var sessionAssertions: [JazzArchiveAssertion] = []
        var referencedBlobPaths = Set<String>()
        var parsedJSONPaths = Set(["manifest.json", "inventory.json"])
        var parsedNDJSONPaths = Set<String>()
        var totalRecords = 0

        for reference in manifest.sessions {
            let sessionData = try structuredData(
                path: reference.path,
                directory: directory,
                fingerprints: fingerprints,
                limit: limits.maxJSONEntryBytes)
            let session = try decodeJSON(
                JazzArchiveSession.self, data: sessionData, path: reference.path)
            try wrapContract(reference.path) { try session.validate() }
            guard session.archiveId == manifest.archiveId,
                session.captureId == reference.captureId,
                session.status != .open,
                session.endedAt != nil,
                session.captureCommit == refsByCapture[session.captureId],
                manifest.actors.contains(where: { $0.actorId == session.recorderActorId }),
                session.sourceIds.allSatisfy({ sourceId in
                    manifest.sources.contains(where: { $0.sourceId == sourceId })
                })
            else { throw JazzArchiveImportError.invalidArchive("session \(session.captureId)") }
            sessions.append(session)
            parsedJSONPaths.insert(reference.path)

            let recordsPath = pathBeside(reference.path, child: "records.ndjson")
            guard fingerprints[recordsPath] != nil else {
                throw JazzArchiveImportError.invalidArchive("missing \(recordsPath)")
            }
            let records = try readRecords(
                at: directory.appendingPathComponent(recordsPath),
                manifest: manifest,
                session: session,
                limits: limits,
                totalRecords: &totalRecords)
            for record in records {
                guard everyObservation.insert(record.observationId).inserted else {
                    throw JazzArchiveImportError.invalidArchive(
                        "duplicate observation \(record.observationId)")
                }
            }
            recordsByCapture[session.captureId] = records
            parsedNDJSONPaths.insert(recordsPath)

            let labelsPath = pathBeside(reference.path, child: "labels.ndjson")
            let labels: [JazzArchiveLabel]
            if fingerprints[labelsPath] != nil {
                labels = try readCanonicalNDJSON(
                    JazzArchiveLabel.self,
                    at: directory.appendingPathComponent(labelsPath),
                    path: labelsPath,
                    limits: limits,
                    totalRecords: &totalRecords)
                parsedNDJSONPaths.insert(labelsPath)
            } else {
                labels = []
            }
            for label in labels {
                try label.validate(manifest: manifest, session: session)
                guard everyLabel.insert(label.labelId).inserted else {
                    throw JazzArchiveImportError.invalidArchive(
                        "duplicate label \(label.labelId)")
                }
            }
            labelsByCapture[session.captureId] = labels.sorted {
                ($0.interval.startStreamSequence, $0.labelId)
                    < ($1.interval.startStreamSequence, $1.labelId)
            }

            // The language-neutral v1 fixtures use one artifacts.ndjson file. Early native
            // writers used one canonical JSON document per artifact; dual-read keeps those exact
            // immutable packages usable while preventing ambiguous mixed layouts.
            let artifactsPath = pathBeside(reference.path, child: "artifacts.ndjson")
            let artifactPrefix = pathBeside(reference.path, child: "artifacts/")
            let artifactPaths = inventory.entries.map(\.path).filter {
                $0.hasPrefix(artifactPrefix) && $0.hasSuffix(".json")
            }.sorted()
            guard fingerprints[artifactsPath] == nil || artifactPaths.isEmpty else {
                throw JazzArchiveImportError.invalidArchive("mixed artifact layouts")
            }
            var artifacts: [JazzArchiveArtifact] = []
            if fingerprints[artifactsPath] != nil {
                artifacts = try readCanonicalNDJSON(
                    JazzArchiveArtifact.self,
                    at: directory.appendingPathComponent(artifactsPath),
                    path: artifactsPath,
                    limits: limits,
                    totalRecords: &totalRecords)
                parsedNDJSONPaths.insert(artifactsPath)
            } else {
                for artifactPath in artifactPaths {
                    let data = try structuredData(
                        path: artifactPath,
                        directory: directory,
                        fingerprints: fingerprints,
                        limit: limits.maxJSONEntryBytes)
                    let artifact = try decodeJSON(
                        JazzArchiveArtifact.self, data: data, path: artifactPath)
                    guard artifactPath == "\(artifactPrefix)\(artifact.artifactId).json" else {
                        throw JazzArchiveImportError.invalidArchive(
                            "artifact path \(artifactPath)")
                    }
                    artifacts.append(artifact)
                    parsedJSONPaths.insert(artifactPath)
                }
            }
            for artifact in artifacts {
                try wrapContract("artifact \(artifact.artifactId)") {
                    try artifact.validate(manifest: manifest, session: session)
                }
                guard everyArtifact.insert(artifact.artifactId).inserted,
                    fingerprints[artifact.content.path] == JazzArchiveFileFingerprint(
                        sha256: artifact.content.sha256,
                        byteLength: artifact.content.byteLength)
                else { throw JazzArchiveImportError.invalidArchive("artifact \(artifact.artifactId)") }
                referencedBlobPaths.insert(artifact.content.path)
            }
            artifactsByCapture[session.captureId] = artifacts.sorted {
                $0.artifactId < $1.artifactId
            }
            let captureArtifactIds = Set(artifacts.map(\.artifactId))
            let captureObservationIds = Set(records.map(\.observationId))
            let captureLabelIds = Set(labels.map(\.labelId))
            let recordsById = Dictionary(
                uniqueKeysWithValues: records.map { ($0.observationId, $0) })
            for record in records {
                for ref in record.artifactRefs
                    where !captureArtifactIds.contains(ref.artifactId)
                {
                    throw JazzArchiveImportError.invalidArchive(
                        "record references artifact from another capture \(ref.artifactId)")
                }
                for labelId in record.labelRefs where !captureLabelIds.contains(labelId) {
                    throw JazzArchiveImportError.invalidArchive(
                        "record references label from another capture \(labelId)")
                }
            }
            for artifact in artifacts {
                for ref in artifact.observationRefs
                    where !captureObservationIds.contains(ref)
                {
                    throw JazzArchiveImportError.invalidArchive(
                        "artifact references observation from another capture \(ref)")
                }
                for labelId in artifact.labelRefs where !captureLabelIds.contains(labelId) {
                    throw JazzArchiveImportError.invalidArchive(
                        "artifact references label from another capture \(labelId)")
                }
            }
            for label in labels {
                guard let start = recordsById[label.interval.startObservationId],
                    start.streamSequence == label.interval.startStreamSequence
                else {
                    throw JazzArchiveImportError.invalidArchive(
                        "label start boundary \(label.labelId)")
                }
                if let endId = label.interval.endObservationId,
                    let endSequence = label.interval.endStreamSequence
                {
                    guard let end = recordsById[endId],
                        end.streamSequence == endSequence
                    else {
                        throw JazzArchiveImportError.invalidArchive(
                            "label end boundary \(label.labelId)")
                    }
                }
                for artifactId in label.narrationArtifactRefs
                    where !captureArtifactIds.contains(artifactId)
                {
                    throw JazzArchiveImportError.invalidArchive(
                        "label references artifact from another capture \(artifactId)")
                }
            }

            let sessionAssertionsPath = pathBeside(
                reference.path, child: "assertions.ndjson")
            if fingerprints[sessionAssertionsPath] != nil {
                let values = try readCanonicalNDJSON(
                    JazzArchiveAssertion.self,
                    at: directory.appendingPathComponent(sessionAssertionsPath),
                    path: sessionAssertionsPath,
                    limits: limits,
                    totalRecords: &totalRecords)
                for assertion in values {
                    try wrapContract(sessionAssertionsPath) {
                        try validateImportedAssertion(assertion, manifest: manifest)
                    }
                }
                sessionAssertions.append(contentsOf: values)
                parsedNDJSONPaths.insert(sessionAssertionsPath)
            }

            guard let commitRef = refsByCapture[session.captureId] else {
                throw JazzArchiveImportError.invalidArchive(
                    "missing CaptureCommit for \(session.captureId)")
            }
            let commitData = try structuredData(
                path: commitRef.path,
                directory: directory,
                fingerprints: fingerprints,
                limit: limits.maxJSONEntryBytes)
            let commit = try decodeJSON(
                JazzArchiveCaptureCommit.self, data: commitData, path: commitRef.path)
            try wrapContract(commitRef.path) { try commit.validate() }
            guard JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(commit)) == commitRef.digest
            else { throw JazzArchiveImportError.integrityMismatch(commitRef.path) }
            guard commit.commitId == commitRef.commitId,
                commit.captureId == session.captureId,
                commit.revision == manifest.revision,
                commit.endedAt == session.endedAt
            else { throw JazzArchiveImportError.invalidArchive("CaptureCommit \(commit.commitId)") }
            let artifactDigests = Dictionary(
                uniqueKeysWithValues: artifacts.map { ($0.artifactId, $0.content.sha256) })
            let recomputed = try JazzArchiveCaptureCommit.make(
                commitId: commit.commitId,
                captureId: commit.captureId,
                revision: commit.revision,
                endedAt: commit.endedAt,
                records: records,
                artifactDigests: artifactDigests,
                declaredGaps: commit.gaps)
            guard recomputed.streamSummaries == commit.streamSummaries,
                recomputed.orderedObservationDigest == commit.orderedObservationDigest,
                recomputed.artifactCount == commit.artifactCount,
                recomputed.artifactSetDigest == commit.artifactSetDigest,
                recomputed.gaps == commit.gaps
            else { throw JazzArchiveImportError.integrityMismatch("CaptureCommit closure") }
            commitsByCapture[session.captureId] = commit
            parsedJSONPaths.insert(commitRef.path)
        }

        for (captureId, records) in recordsByCapture {
            for record in records {
                guard record.captureId == captureId else {
                    throw JazzArchiveImportError.invalidArchive("cross-capture record")
                }
            }
        }
        let actualBlobPaths = Set(fingerprints.keys.filter { $0.hasPrefix("blobs/") })
        guard actualBlobPaths == referencedBlobPaths else {
            throw JazzArchiveImportError.invalidArchive("unreferenced or missing blob")
        }

        let assertionPaths = inventory.entries.map(\.path).filter {
            $0.hasPrefix("assertions/") && $0.hasSuffix(".json")
        }.sorted()
        var assertions = sessionAssertions
        for path in assertionPaths {
            let data = try structuredData(
                path: path,
                directory: directory,
                fingerprints: fingerprints,
                limit: limits.maxJSONEntryBytes)
            let assertion = try decodeJSON(
                JazzArchiveAssertion.self, data: data, path: path)
            try wrapContract(path) {
                try validateImportedAssertion(assertion, manifest: manifest)
            }
            guard path == "assertions/\(assertion.assertionId).json" else {
                throw JazzArchiveImportError.invalidArchive("assertion path \(path)")
            }
            assertions.append(assertion)
            parsedJSONPaths.insert(path)
        }
        guard Set(assertions.map(\.assertionId)).count == assertions.count else {
            throw JazzArchiveImportError.invalidArchive("duplicate assertion")
        }
        let captureIds = Set(sessions.map(\.captureId))
        let labelIds = Set(everyLabel)
        let observationIds = Set(everyObservation)
        let artifactIds = Set(everyArtifact)
        let assertionIds = Set(assertions.map(\.assertionId))
        let assertionsById = Dictionary(
            uniqueKeysWithValues: assertions.map { ($0.assertionId, $0) })
        for assertion in assertions {
            let targetExists: Bool
            switch assertion.target.kind {
            case .archive:
                targetExists = assertion.target.id == manifest.archiveId
            case .capture:
                targetExists = captureIds.contains(assertion.target.id)
            case .label:
                targetExists = labelIds.contains(assertion.target.id)
            case .observation:
                targetExists = observationIds.contains(assertion.target.id)
            case .artifact:
                targetExists = artifactIds.contains(assertion.target.id)
            case .assertion:
                targetExists = assertionIds.contains(assertion.target.id)
            }
            guard targetExists else {
                throw JazzArchiveImportError.invalidArchive(
                    "assertion target \(assertion.assertionId)")
            }
            if let supersedes = assertion.supersedes {
                guard supersedes != assertion.assertionId,
                    let prior = assertionsById[supersedes],
                    prior.target == assertion.target,
                    prior.scope == assertion.scope
                else {
                    throw JazzArchiveImportError.invalidArchive(
                        "assertion supersession \(assertion.assertionId)")
                }
            }
            var seen = Set<String>()
            var current: JazzArchiveAssertion? = assertion
            while let value = current {
                guard seen.insert(value.assertionId).inserted else {
                    throw JazzArchiveImportError.invalidArchive("assertion cycle")
                }
                current = value.supersedes.flatMap { assertionsById[$0] }
            }
        }
        _ = try wrapContractValue("assertion chain") {
            try JazzArchiveReviewStore.archiveHead(
                in: assertions, archiveId: manifest.archiveId)
        }

        let allNDJSON = Set(fingerprints.keys.filter { $0.hasSuffix(".ndjson") })
        guard allNDJSON == parsedNDJSONPaths else {
            throw JazzArchiveImportError.invalidArchive("unknown NDJSON entry")
        }
        for path in fingerprints.keys where path.hasSuffix(".json")
            && !parsedJSONPaths.contains(path)
        {
            let data = try structuredData(
                path: path,
                directory: directory,
                fingerprints: fingerprints,
                limit: limits.maxJSONEntryBytes)
            _ = try wrapContractValue(path) {
                try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
            }
        }

        return JazzArchiveFinalizedSnapshot(
            directoryURL: directory,
            manifest: manifest,
            inventory: inventory,
            sessions: sessions,
            recordsByCapture: recordsByCapture,
            labelsByCapture: labelsByCapture,
            artifactsByCapture: artifactsByCapture,
            commitsByCapture: commitsByCapture,
            assertions: assertions,
            fileFingerprints: fingerprints)
    }

    static func scanFiles(
        directory: URL,
        limits: JazzArchiveImportLimits,
        fileManager: FileManager
    ) throws -> [String: JazzArchiveFileFingerprint] {
        // `URL` enumeration may canonicalize `/var` to `/private/var`; subtracting the original
        // root string then invents a bogus relative path. `enumerator(atPath:)` is explicitly
        // relative and therefore also keeps verification deterministic across root aliases.
        guard let enumerator = fileManager.enumerator(atPath: directory.path)
        else { throw JazzArchiveImportError.invalidArchive("cannot enumerate snapshot") }
        var fingerprints: [String: JazzArchiveFileFingerprint] = [:]
        var nodeCollisionKeys = Set<String>()
        var total: Int64 = 0
        var structured: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            try JazzArchivePortablePath.validate(relative, maxBytes: limits.maxPathBytes)
            guard nodeCollisionKeys.insert(
                JazzArchivePortablePath.collisionKey(relative)).inserted
            else { throw JazzArchiveImportError.duplicateEntry(relative) }
            let url = directory.appendingPathComponent(relative)
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw JazzArchiveImportError.unsafeEntry(relative)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw JazzArchiveImportError.unsafeEntry(relative)
            }
            guard fingerprints.count < limits.maxEntries else {
                throw JazzArchiveImportError.entryLimitExceeded("entry count")
            }
            let fingerprint = try JazzArchiveFileIO.fingerprint(url)
            guard fingerprint.byteLength <= limits.maxEntryBytes else {
                throw JazzArchiveImportError.entryLimitExceeded(relative)
            }
            total = try boundedAdd(total, fingerprint.byteLength, limit: limits.maxTotalExpandedBytes)
            if relative.hasSuffix(".json") || relative.hasSuffix(".ndjson") {
                structured = try boundedAdd(
                    structured,
                    fingerprint.byteLength,
                    limit: limits.maxTotalStructuredBytes)
            }
            guard fingerprints.updateValue(fingerprint, forKey: relative) == nil else {
                throw JazzArchiveImportError.duplicateEntry(relative)
            }
        }
        return fingerprints
    }

    private static func validateSupportedContracts(_ manifest: JazzArchiveManifest) throws {
        let supported = [
            JazzArchiveContract.activityEvent,
            JazzArchiveContract.captureCoachInteraction,
            JazzArchiveContract.mediaObservation,
            JazzArchiveContract.meetingControlObservation,
        ]
        for contract in manifest.contracts where !supported.contains(contract) {
            throw JazzArchiveImportError.invalidArchive(
                "unsupported payload contract \(contract.recordType)")
        }
    }

    private static func readRecords(
        at url: URL,
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        limits: JazzArchiveImportLimits,
        totalRecords: inout Int
    ) throws -> [JazzArchiveRecord] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var records: [JazzArchiveRecord] = []
        var observationIds = Set<String>()
        var positions = Set<String>()
        while true {
            let chunk = try handle.read(upToCount: JazzArchiveFileIO.chunkSize) ?? Data()
            if !chunk.isEmpty { buffer.append(chunk) }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty, line.count <= limits.maxNDJSONLineBytes else {
                    throw JazzArchiveImportError.entryLimitExceeded("NDJSON line")
                }
                totalRecords += 1
                guard totalRecords <= limits.maxNDJSONRecords else {
                    throw JazzArchiveImportError.entryLimitExceeded("NDJSON record count")
                }
                let record = try wrapContractValue(url.lastPathComponent) {
                    try JSONDecoder().decode(JazzArchiveRecord.self, from: line)
                }
                try wrapContract(url.lastPathComponent) {
                    try record.validateRecord(manifest: manifest, session: session)
                }
                guard observationIds.insert(record.observationId).inserted else {
                    throw JazzArchiveImportError.invalidArchive(
                        "duplicate observation \(record.observationId)")
                }
                let position = "\(record.streamId):\(record.streamSequence)"
                guard positions.insert(position).inserted else {
                    throw JazzArchiveImportError.invalidArchive(
                        "duplicate stream position \(position)")
                }
                records.append(record)
            }
            guard buffer.count <= limits.maxNDJSONLineBytes else {
                throw JazzArchiveImportError.entryLimitExceeded("NDJSON line")
            }
            if chunk.isEmpty { break }
        }
        guard buffer.isEmpty, !records.isEmpty else {
            throw JazzArchiveImportError.invalidArchive("records.ndjson framing")
        }
        let ordered = records.sorted {
            ($0.streamId, $0.streamSequence, $0.observationId)
                < ($1.streamId, $1.streamSequence, $1.observationId)
        }
        guard records.map(\.observationId) == ordered.map(\.observationId) else {
            throw JazzArchiveImportError.invalidArchive("records.ndjson order")
        }
        try wrapContract(url.lastPathComponent) {
            try JazzMeetingControlTimeline.validate(records: records)
        }
        return records
    }

    private static func readCanonicalNDJSON<T: Codable>(
        _ type: T.Type,
        at url: URL,
        path: String,
        limits: JazzArchiveImportLimits,
        totalRecords: inout Int
    ) throws -> [T] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        var values: [T] = []
        while true {
            let chunk = try handle.read(upToCount: JazzArchiveFileIO.chunkSize) ?? Data()
            if !chunk.isEmpty { buffer.append(chunk) }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty, line.count <= limits.maxNDJSONLineBytes else {
                    throw JazzArchiveImportError.entryLimitExceeded("NDJSON line \(path)")
                }
                totalRecords += 1
                guard totalRecords <= limits.maxNDJSONRecords else {
                    throw JazzArchiveImportError.entryLimitExceeded("NDJSON record count")
                }
                let value = try wrapContractValue(path) {
                    try JSONDecoder().decode(type, from: line)
                }
                values.append(value)
            }
            guard buffer.count <= limits.maxNDJSONLineBytes else {
                throw JazzArchiveImportError.entryLimitExceeded("NDJSON line \(path)")
            }
            if chunk.isEmpty { break }
        }
        guard buffer.isEmpty else {
            throw JazzArchiveImportError.invalidArchive("NDJSON framing \(path)")
        }
        return values
    }

    private static func structuredData(
        path: String,
        directory: URL,
        fingerprints: [String: JazzArchiveFileFingerprint],
        limit: Int64
    ) throws -> Data {
        guard let fingerprint = fingerprints[path], fingerprint.byteLength <= limit else {
            throw JazzArchiveImportError.entryLimitExceeded(path)
        }
        return try Data(contentsOf: directory.appendingPathComponent(path))
    }

    private static func decodeJSON<T: Codable>(
        _ type: T.Type,
        data: Data,
        path: String
    ) throws -> T {
        try wrapContractValue(path) { try JSONDecoder().decode(type, from: data) }
    }

    private static func pathBeside(_ sessionPath: String, child: String) -> String {
        let parent = sessionPath.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? child : "\(parent)/\(child)"
    }

    private static func validateImportedAssertion(
        _ assertion: JazzArchiveAssertion,
        manifest: JazzArchiveManifest
    ) throws {
        // Assertions are immutable review overlays and may have been authored against any
        // preceding archive revision. The public authoring API deliberately requires an exact
        // current revision, while import must preserve valid historical base revisions.
        guard assertion.baseRevision >= 0, assertion.baseRevision <= manifest.revision else {
            throw JazzArchiveImportError.invalidArchive(
                "assertion base revision \(assertion.assertionId)")
        }
        var baseManifest = manifest
        baseManifest.revision = assertion.baseRevision
        try assertion.validate(manifest: baseManifest)
    }

    private static func wrapContract(_ path: String, _ body: () throws -> Void) throws {
        do { try body() } catch let error as JazzArchiveImportError {
            throw error
        } catch {
            throw JazzArchiveImportError.invalidArchive("\(path): \(error)")
        }
    }

    private static func wrapContractValue<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as JazzArchiveImportError {
            throw error
        } catch {
            throw JazzArchiveImportError.invalidArchive("\(path): \(error)")
        }
    }

    private static func boundedAdd(_ left: Int64, _ right: Int64, limit: Int64) throws -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow, value <= limit else {
            throw JazzArchiveImportError.entryLimitExceeded("total bytes")
        }
        return value
    }
}

enum JazzArchivePortablePath {
    static func validate(_ path: String, maxBytes: Int) throws {
        let bytes = Array(path.utf8)
        let allowed = Set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/".utf8)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !bytes.isEmpty, bytes.count <= maxBytes,
            bytes.allSatisfy(allowed.contains),
            !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\\"),
            !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
            !path.hasPrefix("sync/")
        else { throw JazzArchiveImportError.unsafeEntry(path) }
    }

    static func collisionKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased(
            with: Locale(identifier: "en_US_POSIX"))
    }
}
