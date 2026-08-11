import Foundation

public enum JazzArchiveLabelStatus: String, Codable, Equatable, Sendable {
    case open
    case closed
    case interrupted
}

public enum JazzArchiveLabelDeclarationMode: String, Codable, Equatable, Sendable {
    case freeText = "free_text"
    case guided
    case bdmQuestion = "bdm_question"
    case meetingTopic = "meeting_topic"
}

public struct JazzArchiveLabelDeclaration: Codable, Equatable, Sendable {
    public var text: String
    public var declaredByActorId: String
    public var declaredAt: String
    public var mode: JazzArchiveLabelDeclarationMode
}

public struct JazzArchiveLabelInterval: Codable, Equatable, Sendable {
    public var startObservationId: String
    public var startStreamSequence: Int
    public var endObservationId: String?
    public var endStreamSequence: Int?
}

public enum JazzArchiveProcessBindingResolution: String, Codable, Equatable, Sendable {
    case userSelected = "user_selected"
    case exactMatch = "exact_match"
    case uniqueSubstring = "unique_substring"
}

public struct JazzArchiveProcessBinding: Codable, Equatable, Sendable {
    public var areaId: String
    public var processId: String
    public var nameSnapshot: String
    public var registryRevision: String?
    public var resolution: JazzArchiveProcessBindingResolution
}

/// Portable lineage for separately recorded segments of the same declared process step.
///
/// The baseline is the first immutable label segment. Every later segment points to exactly one
/// immediately preceding segment; archive validation rejects cycles, branches, semantic rebinding,
/// and predecessors that do not occur earlier on the same canonical stream.
public struct JazzArchiveLabelLineage: Codable, Equatable, Sendable {
    public var baselineLabelId: String
    public var resumesLabelId: String?

    public init(
        baselineLabelId: String,
        resumesLabelId: String? = nil
    ) {
        self.baselineLabelId = baselineLabelId
        self.resumesLabelId = resumesLabelId
    }
}

/// Canonical `archive-label.schema.json` mirror used by portable archive import. Labels remain
/// user declarations with explicit boundaries; they are never inferred from nearby observations.
public struct JazzArchiveLabel: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var labelId: String
    public var captureId: String
    public var status: JazzArchiveLabelStatus
    public var declaration: JazzArchiveLabelDeclaration
    public var interval: JazzArchiveLabelInterval
    public var processBinding: JazzArchiveProcessBinding?
    public var lineage: JazzArchiveLabelLineage? = nil
    public var narrationArtifactRefs: [String]
    public var provenance: JazzArchiveProvenance
    public var extensions: [String: JazzArchiveJSONValue]?

    func validate(
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession
    ) throws {
        guard schemaVersion == 1,
            Self.isUUIDv7(labelId, prefix: "l"),
            captureId == session.captureId,
            !declaration.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            Self.isUUIDv7(declaration.declaredByActorId, prefix: "actor"),
            manifest.actors.contains(where: {
                $0.actorId == declaration.declaredByActorId
            }),
            Timestamps.parse(declaration.declaredAt) != nil,
            Self.isUUIDv7(interval.startObservationId, prefix: "obs"),
            interval.startStreamSequence >= 0
        else { throw JazzArchiveImportError.invalidArchive("label \(labelId)") }

        let hasEndObservation = interval.endObservationId != nil
        let hasEndSequence = interval.endStreamSequence != nil
        guard hasEndObservation == hasEndSequence else {
            throw JazzArchiveImportError.invalidArchive("label interval \(labelId)")
        }
        if status == .closed, !hasEndObservation {
            throw JazzArchiveImportError.invalidArchive("closed label interval \(labelId)")
        }
        if let endObservationId = interval.endObservationId,
            let endStreamSequence = interval.endStreamSequence
        {
            guard Self.isUUIDv7(endObservationId, prefix: "obs"),
                endStreamSequence >= interval.startStreamSequence
            else { throw JazzArchiveImportError.invalidArchive("label interval \(labelId)") }
        }
        if let processBinding {
            guard !processBinding.areaId.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty,
                !processBinding.processId.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                !processBinding.nameSnapshot.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
            else { throw JazzArchiveImportError.invalidArchive("process binding \(labelId)") }
        }
        if let lineage {
            guard Self.isUUIDv7(lineage.baselineLabelId, prefix: "l"),
                lineage.resumesLabelId.map({
                    Self.isUUIDv7($0, prefix: "l") && $0 != labelId
                }) ?? true,
                lineage.resumesLabelId != nil || lineage.baselineLabelId == labelId
            else { throw JazzArchiveImportError.invalidArchive("label lineage \(labelId)") }
        }
        guard Set(narrationArtifactRefs).count == narrationArtifactRefs.count,
            narrationArtifactRefs.allSatisfy({
                Self.isUUIDv7($0, prefix: "art")
            }),
            Set(provenance.sources).count == provenance.sources.count,
            provenance.sources.allSatisfy({ sourceId in
                Self.isUUIDv7(sourceId, prefix: "src")
                    && manifest.sources.contains(where: { $0.sourceId == sourceId })
            })
        else { throw JazzArchiveImportError.invalidArchive("label references \(labelId)") }
    }

    private static func isUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else { return false }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }
}
