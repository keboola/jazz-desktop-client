import Foundation

/// A transport-neutral conformance transcript. These delivery fields never enter canonical archive
/// evidence; the embedded records, artifact documents, and CaptureCommit do.
public struct JazzLiveTransportFixture: Codable, Equatable, Sendable {
    public var protocolName: String
    public var protocolVersion: Int
    public var archiveFixture: String
    public var archiveId: String
    public var originId: String
    public var captureId: String
    public var messages: [JazzLiveTransportMessage]
    public var expectedOutcome: JazzLiveTransportOutcome

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case protocolVersion
        case archiveFixture
        case archiveId
        case originId
        case captureId
        case messages
        case expectedOutcome
    }
}

public enum JazzLiveMessageKind: String, Codable, Equatable, Sendable {
    case open
    case observation
    case artifact
    case blobVerified = "blob_verified"
    case commit
    case ack
}

public struct JazzLiveTransportMessage: Codable, Equatable, Sendable {
    public var kind: JazzLiveMessageKind
    public var epoch: Int
    public var resumesEpoch: Int?
    public var resume: JazzLiveResumeState?
    public var deliverySequence: Int?
    public var recordDigest: String?
    public var record: JazzArchiveRecord?
    public var artifactDigest: String?
    public var artifact: JazzArchiveArtifact?
    public var artifactId: String?
    public var contentSha256: String?
    public var byteLength: Int64?
    public var durable: Bool?
    public var commitDigest: String?
    public var commit: JazzArchiveCaptureCommit?
    public var acknowledgedThroughDeliverySequence: Int?
    public var state: JazzLiveResumeState?
}

public struct JazzLiveStreamAck: Codable, Equatable, Sendable {
    public var streamId: String
    public var nextSequence: Int
    public var acceptedBeyond: [Int]
}

public enum JazzLiveCommitStatus: String, Codable, Equatable, Sendable {
    case absent
    case incomplete
    case accepted
}

public struct JazzLiveResumeState: Codable, Equatable, Sendable {
    public var streams: [JazzLiveStreamAck]
    public var artifactIds: [String]
    public var commitStatus: JazzLiveCommitStatus
}

public struct JazzLiveTransportOutcome: Codable, Equatable, Sendable {
    public var connectionEpochs: Int
    public var observationDeliveries: Int
    public var uniqueObservations: Int
    public var duplicateObservationDeliveries: Int
    public var artifactDeliveries: Int
    public var uniqueArtifacts: Int
    public var duplicateArtifactDeliveries: Int
    public var lateObservationIds: [String]
    public var finalCommitStatus: JazzLiveCommitStatus
}

private struct JazzLiveVerifiedBlob: Equatable, Sendable {
    var sha256: String
    var byteLength: Int64
}

public enum JazzLiveTransportValidator {
    public static func validate(
        _ fixture: JazzLiveTransportFixture,
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        archiveRecords: [JazzArchiveRecord],
        archiveArtifacts: [JazzArchiveArtifact],
        archiveCommit: JazzArchiveCaptureCommit
    ) throws -> JazzLiveTransportOutcome {
        guard fixture.protocolName == "dev.jazz.live-capture", fixture.protocolVersion == 1 else {
            throw JazzArchiveError.invalidState("unsupported live transport protocol")
        }
        guard fixture.archiveId == manifest.archiveId,
            fixture.originId == manifest.originId,
            fixture.captureId == session.captureId,
            archiveCommit.captureId == session.captureId
        else { throw JazzArchiveError.invalidState("live/archive identity mismatch") }

        let canonicalRecords = try Dictionary(
            uniqueKeysWithValues: archiveRecords.map {
                ($0.observationId, try canonicalDigest($0))
            })
        let canonicalArtifacts = try Dictionary(
            uniqueKeysWithValues: archiveArtifacts.map {
                ($0.artifactId, try canonicalDigest($0))
            })
        let canonicalArtifactObjects = Dictionary(
            uniqueKeysWithValues: archiveArtifacts.map { ($0.artifactId, $0) })
        let canonicalCommitDigest = try canonicalDigest(archiveCommit)

        var currentEpoch = 0
        var lastAckEpoch = 0
        var lastAckState: JazzLiveResumeState?
        var nextDeliverySequence = 0
        var lastDeliverySequence = -1
        var receivedRecords: [String: String] = [:]
        var receivedSlots: [String: (String, String)] = [:]
        var receivedSequences: [String: Set<Int>] = [:]
        var receivedArtifacts: [String: String] = [:]
        var verifiedArtifactBlobs: [String: JazzLiveVerifiedBlob] = [:]
        var receivedCommitDigest: String?
        var commitSeen = false
        var observationDeliveries = 0
        var artifactDeliveries = 0
        var duplicateObservationDeliveries = 0
        var duplicateArtifactDeliveries = 0
        var lateObservationIds = Set<String>()
        var maximumSequence: [String: Int] = [:]
        var finalCommitStatus = JazzLiveCommitStatus.absent

        for message in fixture.messages {
            try validateShape(message)
            if message.kind == .open {
                guard message.epoch == currentEpoch + 1 else {
                    throw JazzArchiveError.invalidState("live connection epoch is not contiguous")
                }
                if message.epoch == 1 {
                    guard message.resumesEpoch == nil, message.resume == nil else {
                        throw JazzArchiveError.invalidState("first live epoch claims a resume")
                    }
                } else {
                    guard message.resumesEpoch == lastAckEpoch,
                        let lastAckState,
                        message.resume == lastAckState
                    else { throw JazzArchiveError.invalidState("live reconnect watermark mismatch") }
                }
                currentEpoch = message.epoch
                nextDeliverySequence = 0
                lastDeliverySequence = -1
                continue
            }

            guard currentEpoch > 0, message.epoch == currentEpoch else {
                throw JazzArchiveError.invalidState("live message belongs to a closed epoch")
            }
            if message.kind != .ack, message.kind != .blobVerified {
                guard message.deliverySequence == nextDeliverySequence else {
                    throw JazzArchiveError.invalidState("live delivery sequence is not contiguous")
                }
                lastDeliverySequence = nextDeliverySequence
                nextDeliverySequence += 1
            }

            switch message.kind {
            case .open:
                throw JazzArchiveError.invalidState("unexpected live open dispatch")
            case .observation:
                observationDeliveries += 1
                guard let record = message.record, let claimedDigest = message.recordDigest else {
                    throw JazzArchiveError.invalidField("live observation")
                }
                try record.validateRecord(manifest: manifest, session: session)
                let digest = try canonicalDigest(record)
                guard claimedDigest == digest else {
                    throw JazzArchiveError.digestMismatch(path: "live observation")
                }
                guard canonicalRecords[record.observationId] == digest else {
                    throw JazzArchiveError.invalidState("live observation differs from archive")
                }
                if let prior = receivedRecords[record.observationId] {
                    guard prior == digest else {
                        throw JazzArchiveError.transactionConflict(
                            "duplicate live observationId has different content")
                    }
                    duplicateObservationDeliveries += 1
                } else {
                    receivedRecords[record.observationId] = digest
                }
                let slot = "\(record.streamId):\(record.streamSequence)"
                if let prior = receivedSlots[slot] {
                    guard prior.0 == record.observationId, prior.1 == digest else {
                        throw JazzArchiveError.transactionConflict(
                            "live stream sequence has different content")
                    }
                } else {
                    receivedSlots[slot] = (record.observationId, digest)
                }
                if let maximum = maximumSequence[record.streamId], record.streamSequence < maximum {
                    lateObservationIds.insert(record.observationId)
                }
                maximumSequence[record.streamId] = max(
                    maximumSequence[record.streamId] ?? record.streamSequence,
                    record.streamSequence)
                receivedSequences[record.streamId, default: []].insert(record.streamSequence)
            case .artifact:
                artifactDeliveries += 1
                guard let artifact = message.artifact, let claimedDigest = message.artifactDigest else {
                    throw JazzArchiveError.invalidField("live artifact")
                }
                try artifact.validate(manifest: manifest, session: session)
                let digest = try canonicalDigest(artifact)
                guard claimedDigest == digest else {
                    throw JazzArchiveError.digestMismatch(path: "live artifact")
                }
                guard canonicalArtifacts[artifact.artifactId] == digest else {
                    throw JazzArchiveError.invalidState("live artifact differs from archive")
                }
                if let prior = receivedArtifacts[artifact.artifactId] {
                    guard prior == digest else {
                        throw JazzArchiveError.transactionConflict(
                            "duplicate live artifactId has different content")
                    }
                    duplicateArtifactDeliveries += 1
                } else {
                    receivedArtifacts[artifact.artifactId] = digest
                }
            case .blobVerified:
                guard let artifactId = message.artifactId,
                    let sha256 = message.contentSha256,
                    let byteLength = message.byteLength,
                    message.durable == true,
                    let artifact = canonicalArtifactObjects[artifactId]
                else { throw JazzArchiveError.invalidField("live durable blob receipt") }
                guard receivedArtifacts[artifactId] != nil else {
                    throw JazzArchiveError.invalidState(
                        "live blob verified before artifact metadata")
                }
                let verified = JazzLiveVerifiedBlob(sha256: sha256, byteLength: byteLength)
                let canonical = JazzLiveVerifiedBlob(
                    sha256: artifact.content.sha256,
                    byteLength: artifact.content.byteLength)
                guard verified == canonical else {
                    throw JazzArchiveError.digestMismatch(path: "live durable blob receipt")
                }
                if let prior = verifiedArtifactBlobs[artifactId], prior != verified {
                    throw JazzArchiveError.transactionConflict(
                        "duplicate live durable blob receipt has different content")
                }
                verifiedArtifactBlobs[artifactId] = verified
            case .commit:
                commitSeen = true
                guard let commit = message.commit, let claimedDigest = message.commitDigest else {
                    throw JazzArchiveError.invalidField("live CaptureCommit")
                }
                try commit.validate()
                let digest = try canonicalDigest(commit)
                guard claimedDigest == digest, digest == canonicalCommitDigest,
                    commit == archiveCommit
                else { throw JazzArchiveError.invalidState("live CaptureCommit differs from archive") }
                if let prior = receivedCommitDigest, prior != digest {
                    throw JazzArchiveError.transactionConflict(
                        "duplicate live commitId has different content")
                }
                receivedCommitDigest = digest
            case .ack:
                guard message.acknowledgedThroughDeliverySequence == lastDeliverySequence,
                    let state = message.state
                else { throw JazzArchiveError.invalidState("live ack delivery prefix mismatch") }
                let complete = Set(receivedRecords.keys) == Set(canonicalRecords.keys)
                    && Set(receivedArtifacts.keys) == Set(canonicalArtifacts.keys)
                    && Set(verifiedArtifactBlobs.keys) == Set(canonicalArtifacts.keys)
                    && receivedCommitDigest == canonicalCommitDigest
                let expectedState = resumeState(
                    streamIds: session.streamIds,
                    receivedSequences: receivedSequences,
                    receivedArtifactIds: Set(verifiedArtifactBlobs.keys),
                    commitSeen: commitSeen,
                    complete: complete)
                guard state == expectedState else {
                    throw JazzArchiveError.invalidState("live ack receiver state mismatch")
                }
                lastAckEpoch = currentEpoch
                lastAckState = state
                finalCommitStatus = state.commitStatus
            }
        }

        guard Set(receivedRecords.keys) == Set(canonicalRecords.keys),
            Set(receivedArtifacts.keys) == Set(canonicalArtifacts.keys),
            Set(verifiedArtifactBlobs.keys) == Set(canonicalArtifacts.keys),
            receivedCommitDigest == canonicalCommitDigest,
            finalCommitStatus == .accepted
        else { throw JazzArchiveError.invalidState("live receiver is not archive-complete") }
        let outcome = JazzLiveTransportOutcome(
            connectionEpochs: currentEpoch,
            observationDeliveries: observationDeliveries,
            uniqueObservations: receivedRecords.count,
            duplicateObservationDeliveries: duplicateObservationDeliveries,
            artifactDeliveries: artifactDeliveries,
            uniqueArtifacts: receivedArtifacts.count,
            duplicateArtifactDeliveries: duplicateArtifactDeliveries,
            lateObservationIds: lateObservationIds.sorted(),
            finalCommitStatus: finalCommitStatus)
        guard outcome == fixture.expectedOutcome else {
            throw JazzArchiveError.invalidState("live expected outcome mismatch")
        }
        return outcome
    }

    private static func canonicalDigest<T: Encodable>(_ value: T) throws -> String {
        JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(value))
    }

    private static func validateShape(_ message: JazzLiveTransportMessage) throws {
        guard message.epoch >= 1 else {
            throw JazzArchiveError.invalidCount(message.epoch)
        }
        let hasResume = message.resumesEpoch != nil || message.resume != nil
        let hasObservation = message.recordDigest != nil || message.record != nil
        let hasArtifact = message.artifactDigest != nil || message.artifact != nil
        let hasBlobReceipt = message.artifactId != nil || message.contentSha256 != nil
            || message.byteLength != nil || message.durable != nil
        let hasCommit = message.commitDigest != nil || message.commit != nil
        let hasAck = message.acknowledgedThroughDeliverySequence != nil || message.state != nil
        switch message.kind {
        case .open:
            guard message.deliverySequence == nil,
                !hasObservation, !hasArtifact, !hasBlobReceipt, !hasCommit, !hasAck,
                (message.resumesEpoch == nil) == (message.resume == nil),
                (message.resumesEpoch ?? 1) >= 1
            else { throw JazzArchiveError.invalidField("live open message shape") }
            if let resume = message.resume { try validateResumeStateShape(resume) }
        case .observation:
            guard !hasResume, !hasArtifact, !hasBlobReceipt, !hasCommit, !hasAck,
                let deliverySequence = message.deliverySequence,
                deliverySequence >= 0,
                message.recordDigest != nil,
                message.record != nil
            else { throw JazzArchiveError.invalidField("live observation message shape") }
        case .artifact:
            guard !hasResume, !hasObservation, !hasBlobReceipt, !hasCommit, !hasAck,
                let deliverySequence = message.deliverySequence,
                deliverySequence >= 0,
                message.artifactDigest != nil,
                message.artifact != nil
            else { throw JazzArchiveError.invalidField("live artifact message shape") }
        case .blobVerified:
            guard !hasResume, !hasObservation, !hasArtifact, !hasCommit, !hasAck,
                message.deliverySequence == nil,
                message.artifactId != nil,
                message.contentSha256 != nil,
                let byteLength = message.byteLength,
                byteLength >= 0,
                message.durable == true
            else { throw JazzArchiveError.invalidField("live blob receipt message shape") }
        case .commit:
            guard !hasResume, !hasObservation, !hasArtifact, !hasBlobReceipt, !hasAck,
                let deliverySequence = message.deliverySequence,
                deliverySequence >= 0,
                message.commitDigest != nil,
                message.commit != nil
            else { throw JazzArchiveError.invalidField("live commit message shape") }
        case .ack:
            guard !hasResume, !hasObservation, !hasArtifact, !hasBlobReceipt, !hasCommit,
                message.deliverySequence == nil,
                let acknowledged = message.acknowledgedThroughDeliverySequence,
                acknowledged >= 0,
                let state = message.state
            else { throw JazzArchiveError.invalidField("live ack message shape") }
            try validateResumeStateShape(state)
        }
    }

    private static func validateResumeStateShape(_ state: JazzLiveResumeState) throws {
        guard Set(state.streams.map(\.streamId)).count == state.streams.count,
            Set(state.artifactIds).count == state.artifactIds.count
        else { throw JazzArchiveError.invalidField("live resume duplicate identity") }
        for stream in state.streams {
            guard stream.nextSequence >= 0,
                Set(stream.acceptedBeyond).count == stream.acceptedBeyond.count,
                stream.acceptedBeyond.allSatisfy({ $0 >= stream.nextSequence })
            else { throw JazzArchiveError.invalidField("live resume stream watermark") }
        }
    }

    private static func resumeState(
        streamIds: [String],
        receivedSequences: [String: Set<Int>],
        receivedArtifactIds: Set<String>,
        commitSeen: Bool,
        complete: Bool
    ) -> JazzLiveResumeState {
        let streams = streamIds.sorted().map { streamId -> JazzLiveStreamAck in
            let accepted = receivedSequences[streamId] ?? []
            var next = 0
            while accepted.contains(next) { next += 1 }
            return JazzLiveStreamAck(
                streamId: streamId,
                nextSequence: next,
                acceptedBeyond: accepted.filter { $0 >= next }.sorted())
        }
        return JazzLiveResumeState(
            streams: streams,
            artifactIds: receivedArtifactIds.sorted(),
            commitStatus: complete ? .accepted : commitSeen ? .incomplete : .absent)
    }
}
