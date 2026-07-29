import Foundation
import XCTest

@testable import JasnostCaptureCore

final class SourceNeutralContractTests: XCTestCase {
    private struct CanonicalFixture {
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var records: [JazzArchiveRecord]
        var artifacts: [JazzArchiveArtifact]
        var commit: JazzArchiveCaptureCommit
    }

    func testMeetingScreenShareArchiveIsSourceNeutralAndIdentityHonest() throws {
        let fixture = try loadArchiveFixture()

        XCTAssertNil(fixture.session.legacySessionId)
        XCTAssertEqual(
            Set(fixture.session.capturePolicy.modalities.map(\.rawValue)),
            Set(["screen_share_video", "meeting_audio", "meeting_metadata", "transcript"]))
        XCTAssertEqual(fixture.records.count, 13)
        XCTAssertEqual(fixture.artifacts.map(\.kind).sorted(), [
            "meeting_audio", "screen_share_video", "transcript",
        ])
        XCTAssertTrue(fixture.manifest.sources.allSatisfy { !$0.kind.hasPrefix("macos.") })
        XCTAssertEqual(
            Set(fixture.manifest.sources.compactMap { $0.clock?.clockDomainId }).count,
            4)
        XCTAssertTrue(fixture.manifest.sources.allSatisfy {
            ($0.clock?.estimatedSkewMillis ?? 0) > 0
        })
        let forbiddenDirectCapabilities = Set([
            "accessibility.tree", "direct_input.events", "keyboard.events", "pointer.events",
        ])
        for source in fixture.manifest.sources {
            XCTAssertTrue(forbiddenDirectCapabilities.isDisjoint(with: source.capabilities))
            XCTAssertTrue(
                forbiddenDirectCapabilities.isSubset(
                    of: Set(source.unavailableCapabilities.map(\.capability))))
        }

        let participant = try XCTUnwrap(
            fixture.manifest.actors.first { $0.kind == .human })
        XCTAssertEqual(participant.identityStatus, .unknown)
        XCTAssertNil(participant.displayName)
        XCTAssertNil(participant.externalIdentities)

        let mediaRecords = fixture.records.filter {
            $0.recordType == ArchiveRecord<JazzMediaObservation>.mediaRecordType
        }
        let controlRecords = fixture.records.filter {
            $0.recordType
                == ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType
        }
        XCTAssertEqual(mediaRecords.count, 5)
        XCTAssertEqual(controlRecords.count, 8)
        for erased in mediaRecords {
            let record = try erased.mediaObservationRecord()
            try record.validate(
                manifest: fixture.manifest,
                session: fixture.session,
                artifacts: fixture.artifacts)
            XCTAssertEqual(record.payload.attribution.status, .unknown)
            XCTAssertNil(record.payload.attribution.actorId)
            XCTAssertGreaterThan(record.payload.sourceTime.uncertaintyMillis, 0)
        }
        let controls = try controlRecords.map {
            try $0.meetingControlObservationRecord()
        }
        for record in controls {
            try record.validate(manifest: fixture.manifest, session: fixture.session)
        }
        try JazzMeetingControlTimeline.validate(records: fixture.records)
        XCTAssertTrue(controls.contains {
            $0.payload.eventType == .consentGranted
                && $0.payload.consent?.status == .granted
        })
        XCTAssertTrue(controls.contains {
            $0.payload.eventType == .producerConnected
                && $0.payload.connectionEpoch == 2
                && $0.payload.resumesEpoch == 1
        })
        XCTAssertEqual(
            controls.filter {
                $0.payload.eventType == .screenShareStarted
                    || $0.payload.eventType == .screenShareStopped
            }.compactMap(\.payload.trackId),
            ["screen-track-1", "screen-track-1"])
        XCTAssertEqual(
            controls.filter {
                $0.payload.eventType == .participantJoined
                    || $0.payload.eventType == .participantLeft
            }.compactMap(\.payload.participantInstanceId),
            ["meeting-participant-opaque-1", "meeting-participant-opaque-1"])
    }

    func testUnknownParticipantCannotInheritOrganizerMetadataOrAnotherActor() throws {
        var fixture = try loadArchiveFixture()
        let participantIndex = try XCTUnwrap(
            fixture.manifest.actors.firstIndex { $0.identityStatus == .unknown })
        fixture.manifest.actors[participantIndex].displayName = "Meeting organizer"
        fixture.manifest.actors[participantIndex].externalIdentities = [
            JazzArchiveExternalIdentity(namespace: "meeting.organizer", value: "organizer@example.test")
        ]
        XCTAssertThrowsError(try fixture.manifest.validate())

        fixture = try loadArchiveFixture()
        var record = try fixture.records[0].mediaObservationRecord()
        record.payload.attribution = JazzMediaParticipantAttribution(
            status: .identified,
            actorId: fixture.session.recorderActorId,
            basis: .declared,
            method: .providerParticipantId)
        XCTAssertThrowsError(try record.validate(
            manifest: fixture.manifest,
            session: fixture.session,
            artifacts: fixture.artifacts))
    }

    func testMeetingControlEvidenceFailsClosedOnConsentAndReconnectRebinding() throws {
        let fixture = try loadArchiveFixture()
        let controls = try fixture.records
            .filter {
                $0.recordType
                    == ArchiveRecord<JazzMeetingControlObservation>.meetingControlRecordType
            }
            .map { try $0.meetingControlObservationRecord() }

        var consent = try XCTUnwrap(
            controls.first { $0.payload.eventType == .consentGranted })
        consent.payload.consent?.policyVersion = "different-policy"
        XCTAssertThrowsError(
            try consent.validate(manifest: fixture.manifest, session: fixture.session))

        var reconnect = try XCTUnwrap(
            controls.first {
                $0.payload.eventType == .producerConnected
                    && $0.payload.resumesEpoch != nil
            })
        reconnect.payload.resumesEpoch = reconnect.payload.connectionEpoch
        XCTAssertThrowsError(
            try reconnect.validate(manifest: fixture.manifest, session: fixture.session))

        var participant = try XCTUnwrap(
            controls.first { $0.payload.eventType == .participantJoined })
        participant.payload.participantAttribution = JazzMediaParticipantAttribution(
            status: .identified,
            actorId: fixture.session.recorderActorId,
            basis: .observed,
            method: .providerParticipantId)
        XCTAssertThrowsError(
            try participant.validate(manifest: fixture.manifest, session: fixture.session))

        var invalidTimeline = fixture.records
        let leaveIndex = try XCTUnwrap(invalidTimeline.firstIndex {
            (try? $0.meetingControlObservationRecord().payload.eventType) == .participantLeft
        })
        var leave = try invalidTimeline[leaveIndex].meetingControlObservationRecord()
        leave.payload.participantInstanceId = "different-presence"
        invalidTimeline[leaveIndex] = try JazzArchiveRecord(erasing: leave)
        XCTAssertThrowsError(try JazzMeetingControlTimeline.validate(records: invalidTimeline))

        var unicodeToken = try XCTUnwrap(
            controls.first { $0.payload.eventType == .participantJoined })
        unicodeToken.payload.participantInstanceId = "účastník"
        XCTAssertThrowsError(
            try unicodeToken.validate(manifest: fixture.manifest, session: fixture.session))
    }

    func testLiveFixtureDeduplicatesReconnectAndLateMediaIntoSameCommit() throws {
        let canonical = try loadArchiveFixture()
        let live = try JSONDecoder().decode(
            JazzLiveTransportFixture.self,
            from: Data(contentsOf: contractRoot()
                .appendingPathComponent("live/fixtures/01-reconnect-late-media.json")))

        let outcome = try JazzLiveTransportValidator.validate(
            live,
            manifest: canonical.manifest,
            session: canonical.session,
            archiveRecords: canonical.records,
            archiveArtifacts: canonical.artifacts,
            archiveCommit: canonical.commit)

        XCTAssertEqual(outcome, live.expectedOutcome)
        XCTAssertEqual(outcome.connectionEpochs, 2)
        XCTAssertEqual(outcome.duplicateObservationDeliveries, 3)
        XCTAssertEqual(outcome.duplicateArtifactDeliveries, 1)
        XCTAssertEqual(
            outcome.lateObservationIds,
            ["obs-44444444-4444-7444-8444-444444444442"])
        XCTAssertEqual(outcome.finalCommitStatus, .accepted)
    }

    func testLiveFixtureRejectsDifferentContentForDuplicateIdAndReconnectMismatch() throws {
        let canonical = try loadArchiveFixture()
        let data = try Data(contentsOf: contractRoot()
            .appendingPathComponent("live/fixtures/01-reconnect-late-media.json"))
        let original = try JSONDecoder().decode(JazzLiveTransportFixture.self, from: data)

        var conflict = original
        let duplicateIndex = try XCTUnwrap(conflict.messages.lastIndex {
            $0.kind == .observation
                && $0.record?.observationId
                    == "obs-44444444-4444-7444-8444-444444444443"
        })
        conflict.messages[duplicateIndex].record?.capturedAt = "2026-07-23T00:00:00.000Z"
        conflict.messages[duplicateIndex].recordDigest = JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(
                try XCTUnwrap(conflict.messages[duplicateIndex].record)))
        XCTAssertThrowsError(try JazzLiveTransportValidator.validate(
            conflict,
            manifest: canonical.manifest,
            session: canonical.session,
            archiveRecords: canonical.records,
            archiveArtifacts: canonical.artifacts,
            archiveCommit: canonical.commit))

        var mismatch = original
        let reconnectIndex = try XCTUnwrap(mismatch.messages.firstIndex {
            $0.kind == .open && $0.epoch == 2
        })
        mismatch.messages[reconnectIndex].resume?.streams[0].nextSequence += 1
        XCTAssertThrowsError(try JazzLiveTransportValidator.validate(
            mismatch,
            manifest: canonical.manifest,
            session: canonical.session,
            archiveRecords: canonical.records,
            archiveArtifacts: canonical.artifacts,
            archiveCommit: canonical.commit))
    }

    func testLiveSwiftRunnerRejectsWrongKindFieldsAndNegativeSequences() throws {
        let canonical = try loadArchiveFixture()
        let data = try Data(contentsOf: contractRoot()
            .appendingPathComponent("live/fixtures/01-reconnect-late-media.json"))
        let original = try JSONDecoder().decode(JazzLiveTransportFixture.self, from: data)

        var extraField = original
        let observationIndex = try XCTUnwrap(extraField.messages.firstIndex {
            $0.kind == .observation
        })
        extraField.messages[observationIndex].commit = canonical.commit
        extraField.messages[observationIndex].commitDigest = JazzArchiveDigest.sha256Hex(
            try JazzArchiveCanonicalJSON.encode(canonical.commit))
        XCTAssertThrowsError(try validate(extraField, against: canonical))

        var negativeEpoch = original
        negativeEpoch.messages[0].epoch = -1
        XCTAssertThrowsError(try validate(negativeEpoch, against: canonical))

        var negativeDelivery = original
        negativeDelivery.messages[observationIndex].deliverySequence = -1
        XCTAssertThrowsError(try validate(negativeDelivery, against: canonical))
    }

    func testLiveSwiftRunnerAcknowledgesOnlyVerifiedDurableBlobBytes() throws {
        let canonical = try loadArchiveFixture()
        let data = try Data(contentsOf: contractRoot()
            .appendingPathComponent("live/fixtures/01-reconnect-late-media.json"))
        let original = try JSONDecoder().decode(JazzLiveTransportFixture.self, from: data)

        var metadataOnly = original
        let firstAckIndex = try XCTUnwrap(metadataOnly.messages.firstIndex { $0.kind == .ack })
        let audioId = try XCTUnwrap(
            canonical.artifacts.first { $0.kind == "meeting_audio" }?.artifactId)
        metadataOnly.messages[firstAckIndex].state?.artifactIds.append(audioId)
        metadataOnly.messages[firstAckIndex].state?.artifactIds.sort()
        XCTAssertThrowsError(try validate(metadataOnly, against: canonical))

        var mismatchedReceipt = original
        let receiptIndex = try XCTUnwrap(mismatchedReceipt.messages.firstIndex {
            $0.kind == .blobVerified
        })
        mismatchedReceipt.messages[receiptIndex].byteLength? += 1
        XCTAssertThrowsError(try validate(mismatchedReceipt, against: canonical))
    }

    private func loadArchiveFixture() throws -> CanonicalFixture {
        let decoder = JSONDecoder()
        let root = contractRoot().appendingPathComponent(
            "archive/fixtures/04-meeting-screen-share")
        let manifest = try decoder.decode(
            JazzArchiveManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let sessionRef = try XCTUnwrap(manifest.sessions.first)
        let sessionURL = root.appendingPathComponent(sessionRef.path)
        let session = try decoder.decode(
            JazzArchiveSession.self, from: Data(contentsOf: sessionURL))
        try session.validate()
        let base = sessionURL.deletingLastPathComponent()
        let records = try decodeNDJSON(
            JazzArchiveRecord.self, at: base.appendingPathComponent("records.ndjson"))
        let artifacts = try decodeNDJSON(
            JazzArchiveArtifact.self, at: base.appendingPathComponent("artifacts.ndjson"))
        let commit = try decoder.decode(
            JazzArchiveCaptureCommit.self,
            from: Data(contentsOf: base.appendingPathComponent("commit.json")))
        try commit.validate()
        return CanonicalFixture(
            manifest: manifest,
            session: session,
            records: records,
            artifacts: artifacts,
            commit: commit)
    }

    private func validate(
        _ live: JazzLiveTransportFixture,
        against canonical: CanonicalFixture
    ) throws -> JazzLiveTransportOutcome {
        try JazzLiveTransportValidator.validate(
            live,
            manifest: canonical.manifest,
            session: canonical.session,
            archiveRecords: canonical.records,
            archiveArtifacts: canonical.artifacts,
            archiveCommit: canonical.commit)
    }

    private func decodeNDJSON<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> [Value] {
        let decoder = JSONDecoder()
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(type, from: Data($0.utf8)) }
    }

    private func contractRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let contract = candidate.appendingPathComponent("contract")
            if FileManager.default.fileExists(atPath: contract.path) { return contract }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("contract root not found")
    }
}
