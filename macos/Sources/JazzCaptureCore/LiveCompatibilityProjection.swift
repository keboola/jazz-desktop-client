import Foundation

/// Stable archive identity carried by every liveCompatibility item. The binding is transport
/// metadata only; its values are minted with the canonical archive and never reconstructed from
/// legacy session or OTLP trace identity.
public struct JazzLiveCanonicalBinding: Codable, Equatable, Sendable {
    public let archiveId: String
    public let originId: String
    public let captureId: String

    public init(archiveId: String, originId: String, captureId: String) throws {
        guard Self.prefixedUUIDv7(archiveId, prefix: "ar"),
            Self.prefixedUUIDv7(originId, prefix: "origin"),
            Self.prefixedUUIDv7(captureId, prefix: "cap")
        else { throw JazzArchiveError.invalidField("live canonical binding") }
        self.archiveId = archiveId
        self.originId = originId
        self.captureId = captureId
    }

    private static func prefixedUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker),
            let uuid = UUID(uuidString: String(value.dropFirst(marker.count)))
        else { return false }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return (bytes[6] >> 4) == 7
    }
}

public enum JazzLiveProjectionItemKind: String, Codable, Equatable, Sendable {
    case observation
    case artifact
    case commit
}

/// Exact JCS document projected over OTLP. `canonicalJcs` is persisted before network delivery,
/// so retries/relaunches reuse byte-identical canonical content and digest.
public struct JazzLiveProjectionItem: Codable, Equatable, Sendable {
    public let kind: JazzLiveProjectionItemKind
    public let itemId: String
    public let canonicalDigest: String
    public let canonicalJcs: String
    public let capturedAt: String
    public let streamId: String?
    public let streamSequence: Int?
    public let recordType: String?

    public static func observation(_ record: JazzArchiveRecord) throws -> Self {
        let bytes = try JazzArchiveCanonicalJSON.encode(record)
        return try Self(
            kind: .observation,
            itemId: record.observationId,
            canonicalBytes: bytes,
            capturedAt: record.capturedAt,
            streamId: record.streamId,
            streamSequence: record.streamSequence,
            recordType: record.recordType)
    }

    public static func artifact(
        _ artifact: JazzArchiveArtifact,
        fallbackCapturedAt: String
    ) throws -> Self {
        let capturedAt =
            artifact.captureInterval?.startedAt
            ?? artifact.derivation?.computedAt
            ?? fallbackCapturedAt
        let bytes = try JazzArchiveCanonicalJSON.encode(artifact)
        return try Self(
            kind: .artifact,
            itemId: artifact.artifactId,
            canonicalBytes: bytes,
            capturedAt: capturedAt)
    }

    public static func commit(_ commit: JazzArchiveCaptureCommit) throws -> Self {
        let bytes = try JazzArchiveCanonicalJSON.encode(commit)
        return try Self(
            kind: .commit,
            itemId: commit.commitId,
            canonicalBytes: bytes,
            capturedAt: commit.endedAt)
    }

    private init(
        kind: JazzLiveProjectionItemKind,
        itemId: String,
        canonicalBytes: Data,
        capturedAt: String,
        streamId: String? = nil,
        streamSequence: Int? = nil,
        recordType: String? = nil
    ) throws {
        guard let canonicalJcs = String(data: canonicalBytes, encoding: .utf8),
            !canonicalJcs.isEmpty
        else { throw JazzArchiveError.invalidField("live canonical JCS") }
        self.kind = kind
        self.itemId = itemId
        self.canonicalDigest = JazzArchiveDigest.sha256Hex(canonicalBytes)
        self.canonicalJcs = canonicalJcs
        self.capturedAt = capturedAt
        self.streamId = streamId
        self.streamSequence = streamSequence
        self.recordType = recordType
        try validate()
    }

    public func validate() throws {
        let canonicalBytes = Data(canonicalJcs.utf8)
        guard canonicalDigest.range(
            of: #"^[a-f0-9]{64}$"#,
            options: .regularExpression) != nil,
            !canonicalJcs.isEmpty,
            JazzArchiveDigest.sha256Hex(canonicalBytes) == canonicalDigest,
            Timestamps.parse(capturedAt) != nil
        else { throw JazzArchiveError.invalidField("live canonical item") }
        switch kind {
        case .observation:
            let record = try JSONDecoder().decode(JazzArchiveRecord.self, from: canonicalBytes)
            guard try JazzArchiveCanonicalJSON.encode(record) == canonicalBytes,
                Self.prefixedUUIDv7(itemId, prefix: "obs"),
                let streamId,
                Self.prefixedUUIDv7(streamId, prefix: "stream"),
                let streamSequence,
                streamSequence >= 0,
                let recordType,
                !recordType.isEmpty,
                record.observationId == itemId,
                record.streamId == streamId,
                record.streamSequence == streamSequence,
                record.recordType == recordType,
                record.capturedAt == capturedAt
            else { throw JazzArchiveError.invalidField("live observation projection") }
        case .artifact:
            let artifact = try JSONDecoder().decode(
                JazzArchiveArtifact.self, from: canonicalBytes)
            guard try JazzArchiveCanonicalJSON.encode(artifact) == canonicalBytes,
                Self.prefixedUUIDv7(itemId, prefix: "art"),
                artifact.artifactId == itemId,
                streamId == nil, streamSequence == nil, recordType == nil
            else { throw JazzArchiveError.invalidField("live artifact projection") }
        case .commit:
            let commit = try JSONDecoder().decode(
                JazzArchiveCaptureCommit.self, from: canonicalBytes)
            try commit.validate()
            guard try JazzArchiveCanonicalJSON.encode(commit) == canonicalBytes,
                Self.prefixedUUIDv7(itemId, prefix: "cmt"),
                commit.commitId == itemId,
                commit.endedAt == capturedAt,
                streamId == nil, streamSequence == nil, recordType == nil
            else { throw JazzArchiveError.invalidField("live commit projection") }
        }
    }

    fileprivate func observationRecord() throws -> JazzArchiveRecord {
        guard kind == .observation else {
            throw JazzArchiveError.invalidField("live observation projection")
        }
        return try JSONDecoder().decode(
            JazzArchiveRecord.self, from: Data(canonicalJcs.utf8))
    }

    func artifactDocument() throws -> JazzArchiveArtifact {
        guard kind == .artifact else {
            throw JazzArchiveError.invalidField("live artifact projection")
        }
        return try JSONDecoder().decode(
            JazzArchiveArtifact.self, from: Data(canonicalJcs.utf8))
    }

    func commitDocument() throws -> JazzArchiveCaptureCommit {
        guard kind == .commit else {
            throw JazzArchiveError.invalidField("live commit projection")
        }
        return try JSONDecoder().decode(
            JazzArchiveCaptureCommit.self, from: Data(canonicalJcs.utf8))
    }

    private static func prefixedUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker),
            let uuid = UUID(uuidString: String(value.dropFirst(marker.count)))
        else { return false }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        return (bytes[6] >> 4) == 7
    }
}

/// Durable sidecar for one legacy EventSpool batch. The ActivityEvent remains available for the
/// old Keboola projection, while these exact objects let the server prove archive parity.
///
/// `artifacts` is an inline compatibility partition, not ownership. New spools persist artifacts
/// in their own ID-keyed outbox and may therefore leave this array empty. Older sidecars that
/// carried the record's complete artifact set remain valid and byte-compatible.
public struct JazzLiveProjectionBatch: Codable, Equatable, Sendable {
    public let protocolName: String
    public let protocolVersion: Int
    public let binding: JazzLiveCanonicalBinding
    public let observation: JazzLiveProjectionItem
    public let artifacts: [JazzLiveProjectionItem]

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case protocolVersion
        case binding
        case observation
        case artifacts
    }

    public init(
        binding: JazzLiveCanonicalBinding,
        record: JazzArchiveRecord,
        artifacts: [JazzArchiveArtifact]
    ) throws {
        guard record.originId == binding.originId,
            record.captureId == binding.captureId,
            artifacts.allSatisfy({ $0.captureId == binding.captureId }),
            Set(artifacts.map(\.artifactId)).isSubset(
                of: Set(record.artifactRefs.map(\.artifactId)))
        else { throw JazzArchiveError.invalidState("live projection identity mismatch") }
        let observation = try JazzLiveProjectionItem.observation(record)
        let projectedArtifacts = try artifacts.map {
            try JazzLiveProjectionItem.artifact(
                $0,
                fallbackCapturedAt: record.capturedAt)
        }
        guard Set(projectedArtifacts.map(\.itemId)).count == projectedArtifacts.count else {
            throw JazzArchiveError.invalidState("duplicate live artifact projection")
        }
        protocolName = "dev.jazz.live-otlp-projection"
        protocolVersion = 1
        self.binding = binding
        self.observation = observation
        self.artifacts = projectedArtifacts.sorted { $0.itemId < $1.itemId }
    }

    public func validate() throws {
        guard protocolName == "dev.jazz.live-otlp-projection", protocolVersion == 1,
            observation.kind == .observation,
            Set(artifacts.map(\.itemId)).count == artifacts.count,
            artifacts.allSatisfy({ $0.kind == .artifact })
        else { throw JazzArchiveError.invalidField("live projection batch") }
        try observation.validate()
        for artifact in artifacts { try artifact.validate() }
        let record = try observation.observationRecord()
        let artifactDocuments = try artifacts.map { try $0.artifactDocument() }
        guard record.originId == binding.originId,
            record.captureId == binding.captureId,
            artifactDocuments.allSatisfy({ $0.captureId == binding.captureId }),
            Set(artifactDocuments.map(\.artifactId)).isSubset(
                of: Set(record.artifactRefs.map(\.artifactId)))
        else { throw JazzArchiveError.invalidState("live projection identity mismatch") }
    }
}

/// Local durable carrier for one canonical artifact. Artifacts are independent live protocol
/// items, so zero, one, or many observations may reference the same outbox identity without
/// changing its bytes or transport timestamp.
public struct JazzLiveArtifactProjection: Codable, Equatable, Sendable {
    public let protocolName: String
    public let protocolVersion: Int
    public let binding: JazzLiveCanonicalBinding
    public let artifact: JazzLiveProjectionItem

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case protocolVersion
        case binding
        case artifact
    }

    public init(
        binding: JazzLiveCanonicalBinding,
        artifact: JazzArchiveArtifact,
        fallbackCapturedAt: String
    ) throws {
        guard artifact.captureId == binding.captureId else {
            throw JazzArchiveError.invalidState("live artifact projection identity mismatch")
        }
        protocolName = "dev.jazz.live-otlp-projection"
        protocolVersion = 1
        self.binding = binding
        self.artifact = try JazzLiveProjectionItem.artifact(
            artifact,
            fallbackCapturedAt: fallbackCapturedAt)
        try validate()
    }

    public func validate() throws {
        guard protocolName == "dev.jazz.live-otlp-projection",
            protocolVersion == 1,
            artifact.kind == .artifact
        else { throw JazzArchiveError.invalidField("live artifact projection") }
        try artifact.validate()
        guard try artifact.artifactDocument().captureId == binding.captureId else {
            throw JazzArchiveError.invalidState("live artifact projection identity mismatch")
        }
    }
}

/// Frozen OTLP attribute mapping mirrored by the server receiver.
public enum JazzLiveOtlpProjection {
    public static let protocolVersion = 1

    public static func attributes(
        item: JazzLiveProjectionItem,
        binding: JazzLiveCanonicalBinding
    ) -> [Otlp.KeyValue] {
        var values: [Otlp.KeyValue] = [
            string("jazz.archive.id", binding.archiveId),
            string("jazz.origin.id", binding.originId),
            string("jazz.capture.id", binding.captureId),
            integer("jazz.live.protocol_version", protocolVersion),
            string("jazz.live.kind", item.kind.rawValue),
            string("jazz.live.item_id", item.itemId),
            string("jazz.live.digest", item.canonicalDigest),
            string("jazz.live.canonical", item.canonicalJcs),
            string("jazz.live.captured_at", item.capturedAt),
        ]
        if item.kind == .observation {
            values.append(string("jazz.stream.id", item.streamId ?? ""))
            values.append(integer("jazz.stream.sequence", item.streamSequence ?? 0))
            values.append(string("jazz.record.type", item.recordType ?? ""))
        }
        return values
    }

    public static func logRecords(
        event: ActivityEvent,
        batch: JazzLiveProjectionBatch,
        context: OtlpMapper.SessionContext,
        now: Date = Date()
    ) -> [Otlp.LogRecord] {
        var observation = OtlpMapper.logRecord(for: event, in: context, now: now)
        observation.attributes.append(
            contentsOf: attributes(item: batch.observation, binding: batch.binding))
        let artifacts = batch.artifacts.map { item in
            let nanos =
                OtlpMapper.unixNanos(fromISO8601: item.capturedAt)
                ?? OtlpMapper.unixNanos(now)
            return Otlp.LogRecord(
                timeUnixNano: String(nanos),
                observedTimeUnixNano: String(nanos),
                severityText: "INFO",
                severityNumber: 9,
                traceId: context.traceId,
                spanId: context.spanId,
                body: .string("jazz.live.artifact"),
                attributes: attributes(item: item, binding: batch.binding))
        }
        return [observation] + artifacts
    }

    /// OTLP carrier for canonical observations that have no legacy `ActivityEvent` representation.
    /// Only the exact record/artifact JCS and transport binding are emitted; no user interaction is
    /// synthesized to satisfy the compatibility stream.
    public static func genericLogRecords(
        batch: JazzLiveProjectionBatch,
        context: OtlpMapper.SessionContext,
        now: Date = Date()
    ) throws -> [Otlp.LogRecord] {
        try batch.validate()
        guard batch.observation.recordType
            != ArchiveRecord<ActivityEvent>.activityRecordType
        else {
            throw JazzArchiveError.invalidField("generic live observation projection")
        }
        let items = [batch.observation] + batch.artifacts
        return items.map { item in
                let nanos =
                    OtlpMapper.unixNanos(fromISO8601: item.capturedAt)
                    ?? OtlpMapper.unixNanos(now)
                return Otlp.LogRecord(
                    timeUnixNano: String(nanos),
                    observedTimeUnixNano: String(nanos),
                    severityText: "INFO",
                    severityNumber: 9,
                    traceId: context.traceId,
                    spanId: context.spanId,
                    body: .string(
                        item.kind == .artifact
                            ? "jazz.live.artifact"
                            : "jazz.live.observation"),
                    attributes: attributes(item: item, binding: batch.binding))
            }
    }

    public static func artifactLogRecords(
        projection: JazzLiveArtifactProjection,
        context: OtlpMapper.SessionContext,
        now: Date = Date()
    ) throws -> [Otlp.LogRecord] {
        try projection.validate()
        let item = projection.artifact
        let nanos =
            OtlpMapper.unixNanos(fromISO8601: item.capturedAt)
            ?? OtlpMapper.unixNanos(now)
        return [
            Otlp.LogRecord(
                timeUnixNano: String(nanos),
                observedTimeUnixNano: String(nanos),
                severityText: "INFO",
                severityNumber: 9,
                traceId: context.traceId,
                spanId: context.spanId,
                body: .string("jazz.live.artifact"),
                attributes: attributes(item: item, binding: projection.binding))
        ]
    }

    public static func commitSpanAttributes(
        commit: JazzLiveProjectionItem,
        binding: JazzLiveCanonicalBinding
    ) throws -> [Otlp.KeyValue] {
        guard commit.kind == .commit else {
            throw JazzArchiveError.invalidField("live commit span projection")
        }
        try commit.validate()
        guard try commit.commitDocument().captureId == binding.captureId else {
            throw JazzArchiveError.invalidState("live commit binding mismatch")
        }
        return attributes(item: commit, binding: binding)
    }

    private static func string(_ key: String, _ value: String) -> Otlp.KeyValue {
        Otlp.KeyValue(key: key, value: .string(value))
    }

    private static func integer(_ key: String, _ value: Int) -> Otlp.KeyValue {
        Otlp.KeyValue(key: key, value: .int(Int64(value)))
    }
}
