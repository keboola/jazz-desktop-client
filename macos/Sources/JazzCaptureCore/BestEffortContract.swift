import Foundation

/// Opt-in signed capability, never inferred from archive/liveCompatibility permission.
public struct JazzBestEffortCapability: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let capability: String
    public let sourceId: String
    public let ongoingTransmission: Bool
    public let lossPolicy: String
    public let lateInputPolicy: String
    public let fidelity: String
    public let coverage: String
    public let expiresAt: String

    public func validate() throws {
        guard schemaVersion == 1, capability == "dev.jazz.best-effort.v1", ongoingTransmission,
            lossPolicy == "volatile-network-crash-overload-v1", lateInputPolicy == "successorOnly",
            fidelity == "sampledActivity", coverage == "unknown",
            Timestamps.parse(expiresAt) != nil,
            JazzBestEffortContract.matches(sourceId, "^[A-Za-z0-9][A-Za-z0-9._-]{0,511}$")
        else { throw JazzBestEffortContract.Failure.invalid }
    }
}

public struct JazzBestEffortBinding: Codable, Equatable, Sendable {
    public let stackURL: String, projectId: String
    public let scope: JazzArchiveUploadScope
    public let sourceId: String, bundleId: String
    public let generation: Int

    public init(route: JazzArchiveUploadRouteBinding, sourceId: String) throws {
        guard route.hasSignedAuthority, let signed = route.signedAuthority else {
            throw JazzBestEffortContract.Failure.authority
        }
        self.stackURL = route.stackURL
        self.projectId = route.projectId
        self.scope = route.scope
        self.sourceId = sourceId
        self.bundleId = signed.bundleId
        self.generation = signed.generation
        try validate()
    }
    public func validate() throws {
        guard KeboolaStack.normalize(stackURL) == stackURL,
            JazzBestEffortContract.matches(projectId, "^[1-9][0-9]{0,15}$"),
            JazzBestEffortContract.matches(sourceId, "^[A-Za-z0-9][A-Za-z0-9._-]{0,511}$"),
            JazzBestEffortContract.matches(bundleId, "^jdb_[a-f0-9]{32}$"),
            (1...9_007_199_254_740_991).contains(generation),
            [scope.companyId, scope.areaId, scope.deviceId].allSatisfy({
                JazzBestEffortContract.matches($0, "^[a-z0-9][a-z0-9-]{0,63}$")
            })
        else { throw JazzBestEffortContract.Failure.invalid }
    }
}

public struct JazzBestEffortEpoch: Codable, Equatable, Sendable {
    public let `protocol`: String, protocolVersion: Int, documentType: String
    public let epochId: String, originId: String, captureId: String
    public let binding: JazzBestEffortBinding
    public let capability: JazzBestEffortCapability
    public let startedAt: String, coverage: String, authority: String

    public func validate() throws {
        try JazzBestEffortContract.header(
            `protocol`, protocolVersion, documentType, "epoch", coverage, authority)
        try binding.validate()
        try capability.validate()
        guard binding.sourceId == capability.sourceId,
            JazzBestEffortContract.identifier(epochId, "bep"),
            JazzBestEffortContract.identifier(originId, "origin"),
            JazzBestEffortContract.identifier(captureId, "cap"),
            let start = Timestamps.parse(startedAt),
            let expiry = Timestamps.parse(capability.expiresAt), start < expiry
        else {
            throw JazzBestEffortContract.Failure.invalid
        }
    }

    /// Expected binding/capability come from verified enrollment, not attributes in the row.
    public func authorize(
        binding expected: JazzBestEffortBinding,
        capability granted: JazzBestEffortCapability, observedSourceId: String, now: Date
    ) throws {
        try JazzBestEffortContract.header(
            `protocol`, protocolVersion, documentType, "epoch", coverage, authority)
        try validate()
        try expected.validate()
        try granted.validate()
        guard binding == expected, capability == granted,
            observedSourceId == binding.sourceId, capability.sourceId == binding.sourceId,
            JazzBestEffortContract.identifier(epochId, "bep"),
            JazzBestEffortContract.identifier(originId, "origin"),
            JazzBestEffortContract.identifier(captureId, "cap"),
            let start = Timestamps.parse(startedAt),
            let expiry = Timestamps.parse(capability.expiresAt),
            now.timeIntervalSinceReferenceDate.isFinite, start <= now, start < expiry, now < expiry
        else { throw JazzBestEffortContract.Failure.authority }
    }
}

public struct JazzBestEffortEnvelope: Codable, Equatable, Sendable {
    public let `protocol`: String, protocolVersion: Int, documentType: String
    public let epochId: String, epochDigest: String, coverage: String, authority: String
    public let item: JazzLiveProjectionItem
    public let mediaState: String

    public func validate(epoch: JazzBestEffortEpoch) throws {
        try epoch.validate()
        guard try JazzArchiveCanonicalJSON.encode(self).count <= JazzBestEffortContract.maximumBytes
        else { throw JazzBestEffortContract.Failure.limit }
        try JazzBestEffortContract.header(
            `protocol`, protocolVersion, documentType, "envelope", coverage, authority)
        guard epochId == epoch.epochId, epochDigest == (try JazzBestEffortContract.digest(epoch)),
            item.kind != .commit
        else {
            throw JazzBestEffortContract.Failure.invalid
        }
        // Same observation/artifact identity/JCS codec, never a fabricated commit.
        try item.validate()
        guard
            JazzBestEffortContract.identifier(
                item.itemId, item.kind == .observation ? "obs" : "art")
        else { throw JazzBestEffortContract.Failure.invalid }
        if item.kind == .observation {
            let record = try item.observationRecord()
            guard record.originId == epoch.originId, record.captureId == epoch.captureId,
                record.recordType == "jazz.activity-event", record.schemaVersion == 1,
                record.payloadSchema == "https://jazz.dev/schema/activity-event.schema.json",
                JazzBestEffortContract.identifier(record.streamId, "stream"),
                mediaState == "notExpected"
            else { throw JazzBestEffortContract.Failure.invalid }
        } else {
            let artifact = try item.artifactDocument()
            guard artifact.captureId == epoch.captureId, artifact.schemaVersion == 1,
                ["pending", "unknown", "unavailable"].contains(mediaState)
            else { throw JazzBestEffortContract.Failure.invalid }
        }
    }
}

public struct JazzBestEffortSelection: Codable, Equatable, Sendable {
    public struct Reference: Codable, Equatable, Sendable {
        public let itemId: String, envelopeDigest: String
    }
    public let `protocol`: String, protocolVersion: Int, documentType: String
    public let epochId: String, epochDigest: String, selectionId: String
    public let items: [Reference]
    public let supersedesSelectionId: String?
    public let coverage: String, authority: String, analysisEligibility: String
    public let archiveReady: Bool
}

public enum JazzBestEffortContract {
    public enum Failure: Error { case invalid, authority, conflict, limit, analysisBlocked }
    public static let maximumBytes = 1_048_576
    public static let maximumItems = 256

    /// Exact canonical decoding rejects unknown fields, duplicate keys, noncanonical numbers and
    /// strings, and unsupported versions without guessing an archive or legacy projection mode.
    public static func decode<T: Codable>(_ type: T.Type, from bytes: Data) throws -> T {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.limit }
        do {
            let value = try JSONDecoder().decode(type, from: bytes)
            guard try JazzArchiveCanonicalJSON.encode(value) == bytes else { throw Failure.invalid }
            return value
        } catch { throw Failure.invalid }
    }
    public static func digest<T: Encodable>(_ value: T) throws -> String {
        JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(value))
    }
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static func identifier(_ value: String, _ prefix: String) -> Bool {
        matches(
            value, "^\(prefix)-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        )
    }
    static func header(
        _ proto: String, _ version: Int, _ type: String, _ expected: String,
        _ coverage: String, _ authority: String
    ) throws {
        guard proto == "dev.jazz.best-effort", version == 1, type == expected,
            coverage == "unknown", authority == "provisional"
        else { throw Failure.invalid }
    }

    /// Bounded atomic reducer, not a persistence service. The caller supplies retained prior state;
    /// production must transact that state and identity fences durably before acknowledging input.
    /// Nothing evicts identities to fit a new batch or claims completeness after process restart.
    public static func merge(
        epoch: JazzBestEffortEpoch, existing: [JazzBestEffortEnvelope],
        incoming: [JazzBestEffortEnvelope]
    ) throws -> [JazzBestEffortEnvelope] {
        guard existing.count <= maximumItems, incoming.count <= maximumItems else {
            throw Failure.limit
        }
        var ids: [String: JazzBestEffortEnvelope] = [:]
        var slots: [String: String] = [:]
        var bytes = 0
        for envelope in existing + incoming {
            bytes += try JazzArchiveCanonicalJSON.encode(envelope).count
            guard bytes <= 16 * maximumBytes else { throw Failure.limit }
            try envelope.validate(epoch: epoch)
            let key = envelope.item.itemId
            if let old = ids[key], old != envelope { throw Failure.conflict }
            if let stream = envelope.item.streamId, let seq = envelope.item.streamSequence {
                let slot = "\(stream):\(seq)"
                if let old = slots[slot], old != key { throw Failure.conflict }
                slots[slot] = key
            }
            ids[key] = envelope
            guard ids.count <= maximumItems else { throw Failure.limit }
        }
        return ids.values.sorted { $0.item.itemId < $1.item.itemId }
    }

    /// Shared identity claims for a caller-owned transaction. Persist pins across epochs/restarts;
    /// never use an empty map merely because the current selection is small. No eviction/ACK here.
    public static func identityPins(
        epoch: JazzBestEffortEpoch, envelopes: [JazzBestEffortEnvelope],
        prior: [String: String]
    ) throws -> [String: String] {
        try epoch.validate()
        guard prior.count <= 4096,
            prior.allSatisfy({
                matches($0.key, "^[A-Za-z0-9:._-]{1,512}$") && matches($0.value, "^[a-f0-9]{64}$")
            })
        else { throw Failure.limit }
        var next = prior
        func pin(_ key: String, _ value: String) throws {
            if let old = next[key], old != value { throw Failure.conflict }
            next[key] = value
            guard next.count <= 4096 else { throw Failure.limit }
        }
        let epochDigest = try digest(epoch)
        try pin("epoch:" + epoch.epochId, epochDigest)
        try pin("capture:" + epoch.captureId, epochDigest)
        for envelope in try merge(epoch: epoch, existing: [], incoming: envelopes) {
            let item = envelope.item
            let content = try digest(envelope)
            try pin("item:" + item.itemId, content)
            if let stream = item.streamId, let sequence = item.streamSequence {
                try pin("slot:\(epoch.captureId):\(stream):\(sequence)", content)
            }
        }
        return next
    }

    public static func freeze(
        epoch: JazzBestEffortEpoch, envelopes: [JazzBestEffortEnvelope],
        predecessor: JazzBestEffortSelection? = nil
    ) throws -> JazzBestEffortSelection {
        let selected = try merge(epoch: epoch, existing: [], incoming: envelopes)
        guard !selected.isEmpty else { throw Failure.invalid }
        if let predecessor {
            guard predecessor.epochId == epoch.epochId,
                predecessor.epochDigest == (try digest(epoch))
            else { throw Failure.conflict }
            try validateSelectionIdentity(predecessor)
        }
        let material = JazzBestEffortSelection(
            protocol: "dev.jazz.best-effort", protocolVersion: 1,
            documentType: "inputSelection", epochId: epoch.epochId, epochDigest: try digest(epoch),
            selectionId: "",
            items: try selected.map {
                .init(itemId: $0.item.itemId, envelopeDigest: try digest($0))
            },
            supersedesSelectionId: predecessor?.selectionId, coverage: "unknown",
            authority: "provisional",
            analysisEligibility: "blocked", archiveReady: false)
        let id = try selectionDigest(material)
        return JazzBestEffortSelection(
            protocol: material.protocol, protocolVersion: 1, documentType: material.documentType,
            epochId: material.epochId, epochDigest: material.epochDigest, selectionId: id,
            items: material.items,
            supersedesSelectionId: material.supersedesSelectionId, coverage: "unknown",
            authority: "provisional",
            analysisEligibility: "blocked", archiveReady: false)
    }
    private static func selectionDigest(_ selection: JazzBestEffortSelection) throws -> String {
        let data = try JazzArchiveCanonicalJSON.encode(selection)
        guard
            case .object(var value) = try JSONDecoder().decode(
                JazzArchiveJSONValue.self, from: data)
        else { throw Failure.invalid }
        value.removeValue(forKey: "selectionId")
        return "bes-"
            + JazzArchiveDigest.sha256Hex(
                try JazzArchiveCanonicalJSON.encode(JazzArchiveJSONValue.object(value)))
    }
    public static func validateSelectionIdentity(_ selection: JazzBestEffortSelection) throws {
        try header(
            selection.protocol, selection.protocolVersion, selection.documentType, "inputSelection",
            selection.coverage, selection.authority)
        guard !selection.archiveReady, selection.analysisEligibility == "blocked",
            identifier(selection.epochId, "bep"), matches(selection.epochDigest, "^[a-f0-9]{64}$"),
            selection.supersedesSelectionId.map({ matches($0, "^bes-[a-f0-9]{64}$") }) ?? true,
            selection.items.allSatisfy({
                (identifier($0.itemId, "obs") || identifier($0.itemId, "art"))
                    && matches($0.envelopeDigest, "^[a-f0-9]{64}$")
            }),
            !selection.items.isEmpty, selection.items.count <= maximumItems,
            selection.items == selection.items.sorted(by: { $0.itemId < $1.itemId }),
            Set(selection.items.map(\.itemId)).count == selection.items.count,
            try selection.selectionId == selectionDigest(selection)
        else { throw Failure.invalid }
    }
    public static func resolve(
        _ selection: JazzBestEffortSelection, epoch: JazzBestEffortEpoch,
        envelopes: [JazzBestEffortEnvelope]
    ) throws -> [JazzBestEffortEnvelope] {
        try validateSelectionIdentity(selection)
        let selected = try merge(epoch: epoch, existing: [], incoming: envelopes)
        let refs = try selected.map {
            JazzBestEffortSelection.Reference(
                itemId: $0.item.itemId, envelopeDigest: try digest($0))
        }
        guard selection.epochId == epoch.epochId, selection.epochDigest == (try digest(epoch)),
            refs == selection.items
        else { throw Failure.conflict }
        return selected
    }

    public static func requireArchiveOrAnalysisAuthority(_ selection: JazzBestEffortSelection)
        throws
    {
        try validateSelectionIdentity(selection)
        // v1 selections are immutable provenance, not READY/analysis grants.
        throw Failure.analysisBlocked
    }

    public static func otlpRequest(_ envelope: JazzBestEffortEnvelope, epoch: JazzBestEffortEpoch)
        throws -> Otlp.ExportLogsServiceRequest
    {
        let attributes = try otlpAttributes(envelope, epoch: epoch)
        guard let nanos = OtlpMapper.unixNanos(fromISO8601: envelope.item.capturedAt) else {
            throw Failure.invalid
        }
        let record = Otlp.LogRecord(
            timeUnixNano: String(nanos), observedTimeUnixNano: String(nanos),
            severityText: "INFO", severityNumber: 9, traceId: "", spanId: "",
            body: .string("jazz.best_effort.provisional"), attributes: attributes)
        return .init(resourceLogs: [
            .init(
                resource: .init(attributes: []),
                scopeLogs: [.init(scope: .init(name: "dev.jazz.best-effort"), logRecords: [record])]
            )
        ])
    }

    public static func otlpAttributes(
        _ envelope: JazzBestEffortEnvelope, epoch: JazzBestEffortEpoch
    ) throws -> [Otlp.KeyValue] {
        try envelope.validate(epoch: epoch)
        let data = try JazzArchiveCanonicalJSON.encode(envelope)
        guard data.count <= maximumBytes else { throw Failure.limit }
        return [
            .init(key: "jazz.best_effort.version", value: .int(1)),
            .init(key: "jazz.best_effort.epoch", value: .string(epoch.epochId)),
            .init(
                key: "jazz.best_effort.canonical",
                value: .string(String(decoding: data, as: UTF8.self))),
            .init(
                key: "jazz.best_effort.digest", value: .string(JazzArchiveDigest.sha256Hex(data))),
        ]
    }
}
