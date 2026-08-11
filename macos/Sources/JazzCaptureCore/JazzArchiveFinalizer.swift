import Foundation

public struct JazzArchiveFinalizedPackage: Equatable, Sendable {
    public let url: URL
    public let manifest: JazzArchiveManifest
    public let inventory: JazzArchiveInventory

    public init(url: URL, manifest: JazzArchiveManifest, inventory: JazzArchiveInventory) {
        self.url = url
        self.manifest = manifest
        self.inventory = inventory
    }
}

public enum JazzArchiveFinalizationError: Error, Equatable, CustomStringConvertible {
    case captureNotCommitted(String)
    case archiveNotConfirmed(String)
    case unsafeEntry(String)
    case malformedRecord(String)
    case duplicateRecord(String)
    case malformedLabel(String)
    case finalizedConflict(String)
    case exportConflict(String)
    case zipLimit(String)

    public var description: String {
        switch self {
        case .captureNotCommitted(let id): return "Capture is not committed: \(id)"
        case .archiveNotConfirmed(let id): return "Archive is not confirmed for export: \(id)"
        case .unsafeEntry(let path): return "Unsafe archive entry: \(path)"
        case .malformedRecord(let path): return "Malformed archive record: \(path)"
        case .duplicateRecord(let id): return "Duplicate archive record: \(id)"
        case .malformedLabel(let id): return "Malformed archive label: \(id)"
        case .finalizedConflict(let id): return "Finalized archive conflicts: \(id)"
        case .exportConflict(let path): return "Archive export already exists with other bytes: \(path)"
        case .zipLimit(let detail): return "ZIP32 limit exceeded: \(detail)"
        }
    }
}

/// Converts a committed working draft into an immutable logical package and exports that directory
/// as a deterministic, unencrypted ZIP-compatible `.jazz-archive` file. The implementation is pure
/// Foundation and never invokes a local service or network transport.
public actor JazzArchiveFinalizer {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability
    private let draftStore: JazzArchiveDraftStore
    private let reviewStore: JazzArchiveReviewStore

    public init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        self.draftStore = JazzArchiveDraftStore(
            root: root, durability: durability, fileManager: fileManager)
        self.reviewStore = JazzArchiveReviewStore(
            root: root, durability: durability, fileManager: fileManager)
    }

    /// Finalization is idempotent by archive identity. Once a finalized package exists, later
    /// calls return it after full integrity verification; `snapshotAt` cannot change its digest.
    public func finalize(
        archiveId: String,
        snapshotAt: String = Timestamps.iso8601(),
        requireArchiveConfirmation: Bool = false
    ) async throws -> JazzArchiveFinalizedPackage {
        let destination = finalizedDirectory(archiveId)
        if fileManager.fileExists(atPath: destination.path) {
            try synchronizeFinalizedPackage(destination)
            let package = try loadFinalized(at: destination, expectedArchiveId: archiveId)
            if requireArchiveConfirmation {
                try requireConfirmation(
                    try finalizedAssertions(in: package), archiveId: archiveId)
            }
            return package
        }

        var manifest = try await draftStore.manifest(archiveId: archiveId)
        guard manifest.state == .live, let commits = manifest.captureCommits,
            commits.count == manifest.sessions.count
        else { throw JazzArchiveFinalizationError.captureNotCommitted(archiveId) }
        for sessionRef in manifest.sessions {
            let session = try await draftStore.session(
                archiveId: archiveId, captureId: sessionRef.captureId)
            guard session.status != .open, session.captureCommit != nil else {
                throw JazzArchiveFinalizationError.captureNotCommitted(sessionRef.captureId)
            }
        }
        if requireArchiveConfirmation {
            try requireConfirmation(
                try await reviewStore.assertions(archiveId: archiveId),
                archiveId: archiveId)
        }
        let assertions = try await reviewStore.seal(archiveId: archiveId)
        if requireArchiveConfirmation { try requireConfirmation(assertions, archiveId: archiveId) }
        let draftInventory = try await draftStore.inventory(archiveId: archiveId)
        let draft = draftDirectory(archiveId)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(
            ".\(archiveId).finalizing-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var keepStaging = true
        defer {
            if keepStaging { try? fileManager.removeItem(at: staging) }
        }

        var recordBatches: [String: [URL]] = [:]
        var artifactDocuments: [String: [URL]] = [:]
        for entry in draftInventory.entries.sorted(by: { $0.path < $1.path }) {
            let source = try safeURL(root: draft, relativePath: entry.path)
            if let compactPath = compactRecordsPath(entry.path) {
                recordBatches[compactPath, default: []].append(source)
            } else if let compactPath = compactArtifactsPath(entry.path) {
                artifactDocuments[compactPath, default: []].append(source)
            } else {
                let target = try safeURL(root: staging, relativePath: entry.path)
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: source, to: target)
            }
        }
        for (relativePath, batches) in recordBatches {
            let target = try safeURL(root: staging, relativePath: relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try compactRecords(batches: batches, to: target)
        }
        for (relativePath, documents) in artifactDocuments {
            let target = try safeURL(root: staging, relativePath: relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try compactArtifacts(documents: documents, to: target)
        }
        for sessionRef in manifest.sessions {
            let session = try await draftStore.session(
                archiveId: archiveId, captureId: sessionRef.captureId)
            try materializeLabels(
                manifest: manifest,
                session: session,
                sessionRef: sessionRef,
                in: staging)
        }
        for assertion in assertions {
            let target = staging.appendingPathComponent(
                "assertions/\(assertion.assertionId).json")
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JazzArchiveCanonicalJSON.encode(assertion).write(to: target, options: .atomic)
        }

        let inventory = try makeInventory(at: staging)
        let inventoryData = try JazzArchiveCanonicalJSON.encode(inventory)
        try inventoryData.write(
            to: staging.appendingPathComponent("inventory.json"), options: .atomic)

        manifest.state = .finalized
        manifest.snapshotAt = snapshotAt
        manifest.inventory.digest = JazzArchiveDigest.sha256Hex(inventoryData)
        manifest.contentDigest = nil
        manifest.contentDigest = JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(manifest))
        try manifest.validate()
        try JazzArchiveCanonicalJSON.encode(manifest).write(
            to: staging.appendingPathComponent("manifest.json"), options: .atomic)

        try durability.synchronizeTree(staging, fileManager: fileManager)
        do {
            try fileManager.moveItem(at: staging, to: destination)
            keepStaging = false
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else { throw error }
            try synchronizeFinalizedPackage(destination)
            let existing = try loadFinalized(at: destination, expectedArchiveId: archiveId)
            guard existing.manifest.contentDigest == manifest.contentDigest else {
                throw JazzArchiveFinalizationError.finalizedConflict(archiveId)
            }
            return existing
        }
        try synchronizeFinalizedPackage(destination)
        return JazzArchiveFinalizedPackage(
            url: destination, manifest: manifest, inventory: inventory)
    }

    private func requireConfirmation(
        _ assertions: [JazzArchiveAssertion],
        archiveId: String
    ) throws {
        let latest = try JazzArchiveReviewStore.archiveHead(
            in: assertions, archiveId: archiveId)
        guard latest?.decision == .confirm else {
            throw JazzArchiveFinalizationError.archiveNotConfirmed(archiveId)
        }
    }

    private func finalizedAssertions(
        in package: JazzArchiveFinalizedPackage
    ) throws -> [JazzArchiveAssertion] {
        let decoder = JSONDecoder()
        return try package.inventory.entries
            .filter { $0.path.hasPrefix("assertions/") && $0.path.hasSuffix(".json") }
            .map { entry in
                let assertion = try decoder.decode(
                    JazzArchiveAssertion.self,
                    from: Data(contentsOf: package.url.appendingPathComponent(entry.path)))
                try assertion.validate(manifest: package.manifest)
                return assertion
            }
    }

    /// Write a deterministic ZIP32 package. Entries are stored without compression, encryption,
    /// timestamps, data descriptors, symlinks, or platform-specific extras so the same finalized
    /// package always produces identical bytes and remains easy to validate before extraction.
    @discardableResult
    public func export(
        _ package: JazzArchiveFinalizedPackage,
        to destination: URL
    ) throws -> URL {
        let verified = try loadFinalized(
            at: package.url, expectedArchiveId: package.manifest.archiveId)
        guard verified.manifest.contentDigest == package.manifest.contentDigest else {
            throw JazzArchiveFinalizationError.finalizedConflict(package.manifest.archiveId)
        }
        try DeterministicJazzArchiveZIP.write(
            directory: package.url,
            to: destination,
            fileManager: fileManager)
        try durability.synchronizeRegularFile(
            destination, permissions: Int16(0o600))
        try synchronizeDirectoryHierarchy(
            destination.deletingLastPathComponent())
        return destination
    }

    /// Export accepts an arbitrary user-selected path and the ZIP writer may create more than one
    /// missing parent. Synchronizing through the filesystem root makes both the first call and a
    /// retry after a partial barrier commit durable without relying on an unpersisted list of which
    /// ancestors happened to exist before the write.
    private func synchronizeDirectoryHierarchy(_ directory: URL) throws {
        var current = directory.standardizedFileURL
        var visited = Set<String>()
        while true {
            guard visited.insert(current.path).inserted else {
                throw JazzArchiveFilesystemDurabilityError.unsafeObject(
                    current.path)
            }
            let values = try current.resourceValues(
                forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                let target = try fileManager.destinationOfSymbolicLink(
                    atPath: current.path)
                let targetPath =
                    target.hasPrefix("/")
                    ? target
                    : current.deletingLastPathComponent().path + "/" + target
                current = URL(
                    fileURLWithPath: try lexicallyNormalizedAbsolutePath(
                        targetPath),
                    isDirectory: true)
                continue
            }
            try durability.synchronizeDirectory(current)
            guard current.path != "/" else { return }
            let parentPath = (current.path as NSString).deletingLastPathComponent
            current = URL(
                fileURLWithPath: parentPath.isEmpty ? "/" : parentPath,
                isDirectory: true)
        }
    }

    /// Foundation URL normalization aliases `/private/var` back to `/var` on macOS, while older
    /// Foundation releases may make `deletingLastPathComponent()` walk above `/`. Normalize only
    /// dot components so a resolved symlink target keeps its real spelling and the explicit root
    /// guard remains portable across CI/runtime OS versions.
    private func lexicallyNormalizedAbsolutePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw JazzArchiveFilesystemDurabilityError.unsafeObject(path)
        }
        var components: [Substring] = []
        for component in path.split(
            separator: "/", omittingEmptySubsequences: true)
        {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw JazzArchiveFilesystemDurabilityError.unsafeObject(path)
                }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private func synchronizeFinalizedPackage(_ directory: URL) throws {
        try durability.synchronizeTree(directory, fileManager: fileManager)
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private func compactRecordsPath(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "sessions" else { return nil }
        if components.last == "records.ndjson" {
            return components.dropLast().joined(separator: "/") + "/records.ndjson"
        }
        guard components.count >= 4, components[components.count - 2] == "records",
            components.last?.hasSuffix(".ndjson") == true
        else { return nil }
        return components.dropLast(2).joined(separator: "/") + "/records.ndjson"
    }

    private func compactArtifactsPath(_ path: String) -> String? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 3, components[0] == "sessions" else { return nil }
        if components.last == "artifacts.ndjson" {
            return components.dropLast().joined(separator: "/") + "/artifacts.ndjson"
        }
        guard components.count >= 4, components[components.count - 2] == "artifacts",
            components.last?.hasSuffix(".json") == true
        else { return nil }
        return components.dropLast(2).joined(separator: "/") + "/artifacts.ndjson"
    }

    private struct RecordLine {
        var streamId: String
        var streamSequence: Int
        var observationId: String
        var bytes: Data
    }

    private func compactRecords(batches: [URL], to target: URL) throws {
        var records: [RecordLine] = []
        var observationIds = Set<String>()
        var streamPositions = Set<String>()
        for batch in batches.sorted(by: { $0.path < $1.path }) {
            let lines = String(decoding: try Data(contentsOf: batch), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
            for line in lines {
                let data = Data(line.utf8)
                guard
                    let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let streamId = value["streamId"] as? String,
                    let sequence = value["streamSequence"] as? Int,
                    sequence >= 0,
                    let observationId = value["observationId"] as? String
                else {
                    throw JazzArchiveFinalizationError.malformedRecord(batch.path)
                }
                guard observationIds.insert(observationId).inserted else {
                    throw JazzArchiveFinalizationError.duplicateRecord(observationId)
                }
                let position = "\(streamId):\(sequence)"
                guard streamPositions.insert(position).inserted else {
                    throw JazzArchiveFinalizationError.duplicateRecord(position)
                }
                records.append(
                    RecordLine(
                    streamId: streamId,
                    streamSequence: sequence,
                    observationId: observationId,
                    bytes: data))
            }
        }
        records.sort {
            ($0.streamId, $0.streamSequence, $0.observationId)
                < ($1.streamId, $1.streamSequence, $1.observationId)
        }
        var output = Data()
        for record in records {
            output.append(record.bytes)
            output.append(0x0a)
        }
        try output.write(to: target, options: .atomic)
    }

    private func compactArtifacts(documents: [URL], to target: URL) throws {
        let decoder = JSONDecoder()
        var byId: [String: (artifact: JazzArchiveArtifact, bytes: Data)] = [:]
        for document in documents.sorted(by: { $0.path < $1.path }) {
            let data = try Data(contentsOf: document)
            let lines: [Data]
            if document.lastPathComponent == "artifacts.ndjson" {
                lines = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { Data($0.utf8) }
            } else {
                lines = [data]
            }
            for line in lines {
                let artifact: JazzArchiveArtifact
                do {
                    artifact = try decoder.decode(JazzArchiveArtifact.self, from: line)
                } catch {
                    throw JazzArchiveFinalizationError.malformedRecord(document.path)
                }
                let canonical = try JazzArchiveCanonicalJSON.encode(artifact)
                if let existing = byId[artifact.artifactId] {
                    guard existing.bytes == canonical else {
                        throw JazzArchiveFinalizationError.duplicateRecord(artifact.artifactId)
                    }
                } else {
                    byId[artifact.artifactId] = (artifact, canonical)
                }
            }
        }
        var output = Data()
        for artifactId in byId.keys.sorted() {
            output.append(byId[artifactId]!.bytes)
            output.append(0x0a)
        }
        try output.write(to: target, options: .atomic)
    }

    private struct LabelBoundary {
        var record: JazzArchiveRecord
        var event: ActivityEvent
    }

    /// Boundary observations are the durable declaration lifecycle. Finalization materializes
    /// those explicit facts into the portable label contract; it never guesses segment boundaries
    /// from temporal proximity or surrounding UI events.
    private func materializeLabels(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        sessionRef: JazzArchiveSessionRef,
        in staging: URL
    ) throws {
        let sessionParent = sessionRef.path.split(separator: "/").dropLast().joined(separator: "/")
        let prefix = sessionParent.isEmpty ? "" : "\(sessionParent)/"
        let recordsURL = try safeURL(
            root: staging, relativePath: "\(prefix)records.ndjson")
        guard fileManager.fileExists(atPath: recordsURL.path) else {
            throw JazzArchiveFinalizationError.malformedRecord(recordsURL.path)
        }
        let records = try decodeNDJSON(JazzArchiveRecord.self, at: recordsURL)
        do {
            try JazzMeetingControlTimeline.validate(records: records)
        } catch {
            throw JazzArchiveFinalizationError.malformedRecord(recordsURL.path)
        }
        let artifactsURL = try safeURL(
            root: staging, relativePath: "\(prefix)artifacts.ndjson")
        let artifacts =
            fileManager.fileExists(atPath: artifactsURL.path)
            ? try decodeNDJSON(JazzArchiveArtifact.self, at: artifactsURL)
            : []
        let labelsURL = try safeURL(
            root: staging, relativePath: "\(prefix)labels.ndjson")

        if fileManager.fileExists(atPath: labelsURL.path) {
            let labels = try decodeNDJSON(JazzArchiveLabel.self, at: labelsURL)
            try validateLabels(
                labels,
                records: records,
                artifacts: artifacts,
                manifest: manifest,
                session: session)
            return
        }

        var starts: [String: LabelBoundary] = [:]
        var ends: [String: LabelBoundary] = [:]
        for record in records
        where
            record.recordType == ArchiveRecord<ActivityEvent>.activityRecordType
        {
            let typed: ArchiveRecord<ActivityEvent>
            do {
                typed = try record.activityRecord()
            } catch {
                throw JazzArchiveFinalizationError.malformedRecord(recordsURL.path)
            }
            let event = typed.payload
            guard
                event.eventType == EventType.labelStart.rawValue
                    || event.eventType == EventType.labelEnd.rawValue
            else { continue }
            guard let labelId = event.labelId, record.labelRefs.contains(labelId) else {
                throw JazzArchiveFinalizationError.malformedLabel(
                    event.labelId ?? record.observationId)
            }
            let boundary = LabelBoundary(record: record, event: event)
            if event.eventType == EventType.labelStart.rawValue {
                guard starts.updateValue(boundary, forKey: labelId) == nil else {
                    throw JazzArchiveFinalizationError.malformedLabel(labelId)
                }
            } else {
                guard ends.updateValue(boundary, forKey: labelId) == nil else {
                    throw JazzArchiveFinalizationError.malformedLabel(labelId)
                }
            }
        }
        guard Set(ends.keys).isSubset(of: Set(starts.keys)) else {
            let orphan = Set(ends.keys).subtracting(starts.keys).sorted().first!
            throw JazzArchiveFinalizationError.malformedLabel(orphan)
        }

        var labels: [JazzArchiveLabel] = []
        for labelId in starts.keys.sorted() {
            let start = starts[labelId]!
            let end = ends[labelId]
            guard
                let text =
                    (stringExtension(
                    "dev.jazz.label.declarationText", in: start.record.extensions)
                    ?? start.event.label)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { throw JazzArchiveFinalizationError.malformedLabel(labelId) }
            if let end {
                guard end.event.label == start.event.label,
                    end.event.processId == start.event.processId,
                    end.event.process == start.event.process,
                    end.record.streamId != start.record.streamId
                        || end.record.streamSequence >= start.record.streamSequence
                else { throw JazzArchiveFinalizationError.malformedLabel(labelId) }
            }

            let declarationMode =
                stringExtension(
                    "dev.jazz.label.declarationMode", in: start.record.extensions
                )
                .flatMap(JazzArchiveLabelDeclarationMode.init(rawValue:))
                ?? fallbackDeclarationMode(event: start.event, session: session)
            let bindingResolution =
                stringExtension(
                    "dev.jazz.label.bindingResolution", in: start.record.extensions
                )
                .flatMap(JazzArchiveProcessBindingResolution.init(rawValue:))
                ?? .exactMatch
            let processBinding: JazzArchiveProcessBinding?
            if let processId = start.event.processId,
                let processName = start.event.process,
                let area = session.area
            {
                processBinding = JazzArchiveProcessBinding(
                    areaId: area.areaId,
                    processId: processId,
                    nameSnapshot: processName,
                    registryRevision: area.registryRevision,
                    resolution: bindingResolution)
            } else {
                processBinding = nil
            }
            let sourceIds = Array(Set(start.record.sourceRefs.map(\.sourceId))).sorted()
            let declaredBy =
                start.record.actorRefs.first(where: { $0.actorId == session.recorderActorId })?
                    .actorId
                ?? start.record.actorRefs.first?.actorId
                ?? session.recorderActorId
            let narrationRefs = artifacts.filter {
                $0.kind == "narration_audio" && $0.labelRefs.contains(labelId)
            }.map(\.artifactId).sorted()
            let baselineLabelId = stringExtension(
                "dev.jazz.label.coachBaselineId",
                in: start.record.extensions)
            let resumesLabelId = stringExtension(
                "dev.jazz.label.resumesLabelId",
                in: start.record.extensions)
            if start.record.extensions?["dev.jazz.label.coachBaselineId"] != nil,
                baselineLabelId == nil
            {
                throw JazzArchiveFinalizationError.malformedLabel(labelId)
            }
            if start.record.extensions?["dev.jazz.label.resumesLabelId"] != nil,
                resumesLabelId == nil
            {
                throw JazzArchiveFinalizationError.malformedLabel(labelId)
            }
            guard resumesLabelId == nil || baselineLabelId != nil else {
                throw JazzArchiveFinalizationError.malformedLabel(labelId)
            }
            let lineage = baselineLabelId.map {
                JazzArchiveLabelLineage(
                    baselineLabelId: $0,
                    resumesLabelId: resumesLabelId)
            }
            let label = JazzArchiveLabel(
                schemaVersion: 1,
                labelId: labelId,
                captureId: session.captureId,
                status: end == nil ? .interrupted : .closed,
                declaration: JazzArchiveLabelDeclaration(
                    text: text,
                    declaredByActorId: declaredBy,
                    declaredAt: start.event.timestamp,
                    mode: declarationMode),
                interval: JazzArchiveLabelInterval(
                    startObservationId: start.record.observationId,
                    startStreamSequence: start.record.streamSequence,
                    endObservationId: end?.record.observationId,
                    endStreamSequence: end?.record.streamSequence),
                processBinding: processBinding,
                lineage: lineage,
                narrationArtifactRefs: narrationRefs,
                provenance: JazzArchiveProvenance(
                    factClass: .declared, sources: sourceIds),
                extensions: nil)
            do {
                try label.validate(manifest: manifest, session: session)
            } catch {
                throw JazzArchiveFinalizationError.malformedLabel(labelId)
            }
            labels.append(label)
        }
        try validateLabels(
            labels,
            records: records,
            artifacts: artifacts,
            manifest: manifest,
            session: session)
        guard !labels.isEmpty else { return }
        var output = Data()
        for label in labels.sorted(by: { $0.labelId < $1.labelId }) {
            output.append(try JazzArchiveCanonicalJSON.encode(label))
            output.append(0x0a)
        }
        try output.write(to: labelsURL, options: .atomic)
    }

    private func validateLabels(
        _ labels: [JazzArchiveLabel],
        records: [JazzArchiveRecord],
        artifacts: [JazzArchiveArtifact],
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        let ids = Set(labels.map(\.labelId))
        guard ids.count == labels.count else {
            throw JazzArchiveFinalizationError.malformedLabel("duplicate")
        }
        for label in labels {
            do {
                try label.validate(manifest: manifest, session: session)
            } catch {
                throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
            }
        }
        let referenced = Set(records.flatMap(\.labelRefs))
            .union(artifacts.flatMap(\.labelRefs))
        guard referenced.isSubset(of: ids) else {
            throw JazzArchiveFinalizationError.malformedLabel(
                referenced.subtracting(ids).sorted().first!)
        }
        let artifactIds = Set(artifacts.map(\.artifactId))
        let labelsById = Dictionary(uniqueKeysWithValues: labels.map {
            ($0.labelId, $0)
        })
        let recordsById = Dictionary(uniqueKeysWithValues: records.map {
            ($0.observationId, $0)
        })
        var successorByPredecessor: [String: String] = [:]
        for label in labels {
            guard Set(label.narrationArtifactRefs).isSubset(of: artifactIds) else {
                throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
            }
            guard let lineage = label.lineage else { continue }
            let baselineId = lineage.baselineLabelId
            guard ids.contains(baselineId),
                let baseline = labelsById[baselineId],
                baseline.captureId == label.captureId,
                baseline.lineage?.baselineLabelId == baselineId,
                baseline.lineage?.resumesLabelId == nil,
                labelSemanticKey(label) == labelSemanticKey(baseline)
            else {
                throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
            }
            if let resumesLabelId = lineage.resumesLabelId {
                guard resumesLabelId != label.labelId,
                    ids.contains(resumesLabelId),
                    let resumed = labelsById[resumesLabelId],
                    resumed.lineage?.baselineLabelId == baselineId,
                    labelSemanticKey(label) == labelSemanticKey(resumed),
                    let resumedStart = recordsById[
                        resumed.interval.startObservationId
                    ],
                    let currentStart = recordsById[
                        label.interval.startObservationId
                    ],
                    resumedStart.streamId == currentStart.streamId,
                    resumedStart.streamSequence < currentStart.streamSequence
                else {
                    throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
                }
                if let successor = successorByPredecessor[resumesLabelId],
                    successor != label.labelId
                {
                    throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
                }
                successorByPredecessor[resumesLabelId] = label.labelId
            } else if baselineId != label.labelId {
                throw JazzArchiveFinalizationError.malformedLabel(label.labelId)
            }
        }
    }

    private func labelSemanticKey(_ label: JazzArchiveLabel) -> String? {
        CaptureCoachLabelLineage.semanticKey(
            processId: label.processBinding?.processId,
            declaredText: label.declaration.text)
    }

    private func fallbackDeclarationMode(
        event: ActivityEvent,
        session: JazzArchiveSession
    ) -> JazzArchiveLabelDeclarationMode {
        if session.sessionKind == "bdm-workshop" { return .bdmQuestion }
        return event.processId == nil ? .freeText : .guided
    }

    private func stringExtension(
        _ key: String,
        in extensions: [String: JazzArchiveJSONValue]?
    ) -> String? {
        guard case .string(let value)? = extensions?[key] else { return nil }
        return value
    }

    private func decodeNDJSON<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> [Value] {
        let decoder = JSONDecoder()
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                do {
                    return try decoder.decode(Value.self, from: Data(line.utf8))
                } catch {
                    throw JazzArchiveFinalizationError.malformedRecord(url.path)
                }
            }
    }

    private func makeInventory(at directory: URL) throws -> JazzArchiveInventory {
        // `includingPropertiesForKeys` may canonicalize `/var` to `/private/var` on macOS. String
        // subtraction then produces an absolute-looking entry. Enumerating `atPath` gives us the
        // relative name directly and is also the value that belongs in the archive contract.
        guard let enumerator = fileManager.enumerator(atPath: directory.path)
        else { throw JazzArchiveFinalizationError.unsafeEntry(directory.path) }
        var entries: [JazzArchiveInventoryEntry] = []
        while let relative = enumerator.nextObject() as? String {
            if relative.split(separator: "/").contains(where: { $0.first == "." }) {
                enumerator.skipDescendants()
                continue
            }
            let url = try safeURL(root: directory, relativePath: relative)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw JazzArchiveFinalizationError.unsafeEntry(relative)
            }
            guard values.isRegularFile == true else { continue }
            guard relative != "manifest.json", relative != "inventory.json",
                !relative.hasPrefix("sync/")
            else { continue }
            let fingerprint = try JazzArchiveFileIO.fingerprint(url)
            entries.append(
                JazzArchiveInventoryEntry(
                path: relative,
                byteLength: fingerprint.byteLength,
                sha256: fingerprint.sha256))
        }
        let inventory = JazzArchiveInventory(entries: entries.sorted { $0.path < $1.path })
        try inventory.validate()
        return inventory
    }

    private func loadFinalized(
        at directory: URL,
        expectedArchiveId: String
    ) throws -> JazzArchiveFinalizedPackage {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(
            JazzArchiveManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.archiveId == expectedArchiveId, manifest.state == .finalized,
            let contentDigest = manifest.contentDigest
        else { throw JazzArchiveFinalizationError.finalizedConflict(expectedArchiveId) }
        var unsigned = manifest
        unsigned.contentDigest = nil
        guard
            JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(unsigned)) == contentDigest
        else { throw JazzArchiveFinalizationError.finalizedConflict(expectedArchiveId) }

        let inventoryData = try Data(
            contentsOf: directory.appendingPathComponent(manifest.inventory.path))
        let inventory = try decoder.decode(JazzArchiveInventory.self, from: inventoryData)
        try inventory.validate()
        guard
            JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(inventory)) == manifest.inventory.digest
        else { throw JazzArchiveFinalizationError.finalizedConflict(expectedArchiveId) }
        for entry in inventory.entries {
            let file = try safeURL(root: directory, relativePath: entry.path)
            let fingerprint = try JazzArchiveFileIO.fingerprint(file)
            guard fingerprint.byteLength == entry.byteLength,
                fingerprint.sha256 == entry.sha256
            else { throw JazzArchiveFinalizationError.finalizedConflict(expectedArchiveId) }
        }
        return JazzArchiveFinalizedPackage(
            url: directory, manifest: manifest, inventory: inventory)
    }

    private func safeURL(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
            !relativePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw JazzArchiveFinalizationError.unsafeEntry(relativePath) }
        let standardizedRoot = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRoot + "/") else {
            throw JazzArchiveFinalizationError.unsafeEntry(relativePath)
        }
        return candidate
    }

    private func draftDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent("\(archiveId).jazz-archive.draft", isDirectory: true)
    }

    private func finalizedDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent("\(archiveId).jazz-archive.finalized", isDirectory: true)
    }
}

private enum DeterministicJazzArchiveZIP {
    private struct Entry {
        var name: Data
        var crc32: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private struct SourceFile {
        var url: URL
        var relativePath: String
    }

    static func write(
        directory: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let files = try regularFiles(in: directory, fileManager: fileManager)
        let limits = JazzArchiveImportLimits()
        guard files.count <= min(limits.maxEntries, Int(UInt16.max)) else {
            throw JazzArchiveFinalizationError.zipLimit("entry count")
        }
        var projectedArchiveBytes = Int64(22)  // fixed EOCD
        var structuredBytes = Int64(0)
        for file in files {
            let nameBytes = file.relativePath.utf8.count
            let attributes = try fileManager.attributesOfItem(atPath: file.url.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard size >= 0, size <= limits.maxEntryBytes else {
                throw JazzArchiveFinalizationError.zipLimit(file.relativePath)
            }
            projectedArchiveBytes +=
                Int64(30 + nameBytes) + size
                + Int64(46 + nameBytes)
            if file.relativePath.hasSuffix(".json")
                || file.relativePath.hasSuffix(".ndjson")
            {
                if file.relativePath.hasSuffix(".json"),
                    size > limits.maxJSONEntryBytes
                {
                    throw JazzArchiveFinalizationError.zipLimit(file.relativePath)
                }
                structuredBytes += size
                guard structuredBytes <= limits.maxTotalStructuredBytes else {
                    throw JazzArchiveFinalizationError.zipLimit("structured bytes")
                }
            }
        }
        guard projectedArchiveBytes <= limits.maxArchiveBytes else {
            throw JazzArchiveFinalizationError.zipLimit("archive bytes")
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        guard
            fileManager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
        else { throw JazzArchiveFinalizationError.exportConflict(temporary.path) }
        var keepTemporary = true
        defer {
            if keepTemporary { try? fileManager.removeItem(at: temporary) }
        }

        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        var entries: [Entry] = []
        for file in files {
            let relative = file.relativePath
            let name = Data(relative.utf8)
            guard !name.isEmpty, name.count <= Int(UInt16.max) else {
                throw JazzArchiveFinalizationError.zipLimit("entry name")
            }
            let attributes = try fileManager.attributesOfItem(atPath: file.url.path)
            let size64 = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size64 <= UInt64(UInt32.max), handle.offsetInFile <= UInt64(UInt32.max) else {
                throw JazzArchiveFinalizationError.zipLimit(relative)
            }
            let crc = try crc32(file.url)
            let entry = Entry(
                name: name,
                crc32: crc,
                size: UInt32(size64),
                offset: UInt32(handle.offsetInFile))
            var header = Data()
            header.appendLE(UInt32(0x0403_4b50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0x0021))
            header.appendLE(entry.crc32)
            header.appendLE(entry.size)
            header.appendLE(entry.size)
            header.appendLE(UInt16(name.count))
            header.appendLE(UInt16(0))
            header.append(name)
            try handle.write(contentsOf: header)
            try copy(file.url, to: handle)
            entries.append(entry)
        }

        guard handle.offsetInFile <= UInt64(UInt32.max) else {
            throw JazzArchiveFinalizationError.zipLimit("central directory offset")
        }
        let centralOffset = UInt32(handle.offsetInFile)
        for entry in entries {
            var header = Data()
            header.appendLE(UInt32(0x0201_4b50))
            header.appendLE(UInt16(0x0314))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0x0021))
            header.appendLE(entry.crc32)
            header.appendLE(entry.size)
            header.appendLE(entry.size)
            header.appendLE(UInt16(entry.name.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0o100644 << 16))
            header.appendLE(entry.offset)
            header.append(entry.name)
            try handle.write(contentsOf: header)
        }
        let centralSize64 = handle.offsetInFile - UInt64(centralOffset)
        guard centralSize64 <= UInt64(UInt32.max) else {
            throw JazzArchiveFinalizationError.zipLimit("central directory size")
        }
        var end = Data()
        end.appendLE(UInt32(0x0605_4b50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt16(entries.count))
        end.appendLE(UInt32(centralSize64))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.synchronize()
        try handle.close()

        if fileManager.fileExists(atPath: destination.path) {
            guard try filesEqual(temporary, destination) else {
                throw JazzArchiveFinalizationError.exportConflict(destination.path)
            }
            try fileManager.removeItem(at: temporary)
            keepTemporary = false
            return
        }
        try fileManager.moveItem(at: temporary, to: destination)
        keepTemporary = false
    }

    private static func regularFiles(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [SourceFile] {
        guard let enumerator = fileManager.enumerator(atPath: directory.path)
        else { throw JazzArchiveFinalizationError.unsafeEntry(directory.path) }
        var files: [SourceFile] = []
        var portableKeys = Set<String>()
        let limits = JazzArchiveImportLimits()
        while let relative = enumerator.nextObject() as? String {
            guard !relative.isEmpty, !relative.hasPrefix("/"),
                !relative.hasSuffix("/"),
                relative.utf8.count <= limits.maxPathBytes,
                relative.utf8.allSatisfy(Self.isPortablePathByte),
                !relative.split(
                    separator: "/", omittingEmptySubsequences: false
                ).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            else { throw JazzArchiveFinalizationError.unsafeEntry(relative) }
            let portableKey = relative.lowercased()
            guard portableKeys.insert(portableKey).inserted else {
                throw JazzArchiveFinalizationError.unsafeEntry(relative)
            }
            if relative.split(separator: "/").contains(where: { $0.first == "." }) {
                enumerator.skipDescendants()
                continue
            }
            let url = directory.appendingPathComponent(relative).standardizedFileURL
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw JazzArchiveFinalizationError.unsafeEntry(relative)
            }
            if values.isRegularFile == true {
                files.append(SourceFile(url: url, relativePath: relative))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private static func isPortablePathByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: ".")
            || byte == UInt8(ascii: "_")
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "/")
    }

    private static func copy(_ source: URL, to target: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return }
            try target.write(contentsOf: chunk)
        }
    }

    private static func filesEqual(_ left: URL, _ right: URL) throws -> Bool {
        let leftHandle = try FileHandle(forReadingFrom: left)
        let rightHandle = try FileHandle(forReadingFrom: right)
        defer {
            try? leftHandle.close()
            try? rightHandle.close()
        }
        while true {
            let leftData = try leftHandle.read(upToCount: 64 * 1024) ?? Data()
            let rightData = try rightHandle.read(upToCount: 64 * 1024) ?? Data()
            guard leftData == rightData else { return false }
            if leftData.isEmpty { return true }
        }
    }

    private static func crc32(_ source: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var crc = UInt32.max
        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return crc ^ UInt32.max }
            for byte in chunk {
                let index = Int((crc ^ UInt32(byte)) & 0xff)
                crc = table[index] ^ (crc >> 8)
            }
        }
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }
}

extension Data {
    fileprivate mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
