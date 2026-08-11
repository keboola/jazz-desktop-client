import XCTest

@testable import JazzCaptureCore

final class CaptureCapabilityObservationTests: XCTestCase {
    func testInitialPollAndDuplicateNoiseProduceExactlyOneObservation() throws {
        var machine = JazzCaptureCapabilityStateMachine()
        let sample = JazzCaptureCapabilitySample(
            capability: .screenCapture,
            authorization: .granted,
            availability: .available,
            reason: .permissionGranted)

        let initial = try machine.observe(sample, at: "2026-07-26T10:00:00.000Z")
        let duplicate = try machine.observe(sample, at: "2026-07-26T10:00:01.000Z")

        XCTAssertEqual(initial?.transition, .initial)
        XCTAssertNil(initial?.previousAuthorization)
        XCTAssertNil(initial?.previousAvailability)
        XCTAssertNil(duplicate)
    }

    func testGrantedDeniedRestoredRetainsBothSidesOfEveryTransition() throws {
        var machine = JazzCaptureCapabilityStateMachine()
        _ = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .audioCapture,
                authorization: .granted,
                availability: .available,
                reason: .permissionGranted),
            at: "2026-07-26T10:00:00.000Z")

        let revoked = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .audioCapture,
                authorization: .denied,
                availability: .unavailable,
                reason: .permissionDenied),
            at: "2026-07-26T10:00:01.000Z")
        let restored = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .audioCapture,
                authorization: .granted,
                availability: .available,
                reason: .permissionGranted),
            at: "2026-07-26T10:00:02.000Z")

        XCTAssertEqual(revoked?.transition, .revoked)
        XCTAssertEqual(revoked?.previousAuthorization, .granted)
        XCTAssertEqual(revoked?.previousAvailability, .available)
        XCTAssertEqual(restored?.transition, .restored)
        XCTAssertEqual(restored?.previousAuthorization, .denied)
        XCTAssertEqual(restored?.previousAvailability, .unavailable)
    }

    func testSecureInputIsTemporarySuppressionRatherThanPermissionRevocation() throws {
        var machine = JazzCaptureCapabilityStateMachine()
        _ = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .keyboardCapture,
                authorization: .granted,
                availability: .available,
                reason: .permissionGranted),
            at: "2026-07-26T10:00:00.000Z")

        let suppressed = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .keyboardCapture,
                authorization: .granted,
                availability: .unavailable,
                reason: .secureInput),
            at: "2026-07-26T10:00:01.000Z")
        let restored = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .keyboardCapture,
                authorization: .granted,
                availability: .available,
                reason: .sourceRecovered),
            at: "2026-07-26T10:00:02.000Z")

        XCTAssertEqual(suppressed?.transition, .temporarilyDisabled)
        XCTAssertEqual(suppressed?.authorizationStatus, .granted)
        XCTAssertEqual(restored?.transition, .restored)
    }

    func testEventTapUserInputIsNeutralTemporarySuppression() throws {
        var machine = JazzCaptureCapabilityStateMachine()
        _ = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .pointerCapture,
                authorization: .granted,
                availability: .available,
                reason: .permissionGranted),
            at: "2026-07-26T10:00:00.000Z")

        let suppressed = try machine.observe(
            JazzCaptureCapabilitySample(
                capability: .pointerCapture,
                authorization: .granted,
                availability: .unavailable,
                reason: .eventTapUserInput),
            at: "2026-07-26T10:00:01.000Z")

        XCTAssertEqual(suppressed?.transition, .temporarilyDisabled)
        XCTAssertEqual(suppressed?.reason, .eventTapUserInput)
    }

    func testTransitionReasonMatrixRejectsMisleadingCapabilityEvidence() {
        let revokedWithWrongReason = JazzCaptureCapabilityObservation(
            capability: .screenCapture,
            authorizationStatus: .denied,
            availability: .unavailable,
            transition: .revoked,
            reason: .permissionNotDetermined,
            observedAt: "2026-07-26T10:00:01.000Z",
            previousAuthorization: .granted,
            previousAvailability: .available)
        let repeatedStatePresentedAsTransition = JazzCaptureCapabilityObservation(
            capability: .screenCapture,
            authorizationStatus: .granted,
            availability: .available,
            transition: .restored,
            reason: .sourceRecovered,
            observedAt: "2026-07-26T10:00:01.000Z",
            previousAuthorization: .granted,
            previousAvailability: .available)
        let sourceFailurePresentedAsTemporarySuppression =
            JazzCaptureCapabilityObservation(
                capability: .screenCapture,
                authorizationStatus: .granted,
                availability: .unavailable,
                transition: .temporarilyDisabled,
                reason: .sourceFailure,
                observedAt: "2026-07-26T10:00:01.000Z",
                previousAuthorization: .granted,
                previousAvailability: .available)

        XCTAssertThrowsError(try revokedWithWrongReason.validate())
        XCTAssertThrowsError(try repeatedStatePresentedAsTransition.validate())
        XCTAssertThrowsError(try sourceFailurePresentedAsTemporarySuppression.validate())
    }

    func testPolicyDisabledStillPreservesAuthorizationTransitions() throws {
        var machine = JazzCaptureCapabilityStateMachine()
        let denied = try XCTUnwrap(
            machine.observe(
                JazzCaptureCapabilitySample(
                    capability: .audioCapture,
                    authorization: .denied,
                    availability: .unavailable,
                    reason: .permissionDenied),
                at: "2026-07-26T10:00:00.000Z"))
        let grantedButPolicyDisabled = try XCTUnwrap(
            machine.observe(
                JazzCaptureCapabilitySample(
                    capability: .audioCapture,
                    authorization: .granted,
                    availability: .unavailable,
                    reason: .captureDisabledByPolicy),
                at: "2026-07-26T10:00:01.000Z"))

        XCTAssertEqual(denied.transition, .initial)
        XCTAssertEqual(denied.reason, .permissionDenied)
        XCTAssertEqual(
            grantedButPolicyDisabled.transition,
            .authorizationChanged)
        XCTAssertEqual(
            grantedButPolicyDisabled.reason,
            .captureDisabledByPolicy)
    }

    func testInvalidAvailableDeniedStateFailsClosed() {
        var machine = JazzCaptureCapabilityStateMachine()

        XCTAssertThrowsError(
            try machine.observe(
                JazzCaptureCapabilitySample(
                    capability: .accessibilityContext,
                    authorization: .denied,
                    availability: .available,
                    reason: .permissionDenied),
                at: "2026-07-26T10:00:00.000Z"))
    }

    func testJournalWriterCommitsTypedCapabilityTransitionsToArchive()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-capability-writer-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = "2026-07-26T10:00:00.000Z"
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let sourceId = Identifiers.newSourceId()
        let actorId = Identifiers.newActorId()
        let legacySessionId = "s-33333333-3333-7333-8333-333333333333"
        let producer = JazzArchiveProducer(
            name: "Jazz Capture",
            version: "test",
            platform: "macOS")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: timestamp,
            producer: producer,
            contracts: [
                .activityEvent,
                .captureCapabilityObservation,
            ],
            actors: [
                JazzArchiveActor(
                    actorId: actorId,
                    kind: .human,
                    displayName: "Recorder",
                    provenance: JazzArchiveProvenance(
                        factClass: .declared,
                        sources: []))
            ],
            sources: [
                JazzArchiveSource(
                    sourceId: sourceId,
                    kind: "macos.native",
                    actorId: actorId,
                    producer: producer,
                    capabilities: ["screen.capture"],
                    provenance: JazzArchiveProvenance(
                        factClass: .observed,
                        sources: []))
            ],
            sessions: [
                JazzArchiveSessionRef(
                    captureId: captureId,
                    legacySessionId: legacySessionId)
            ],
            extensions: [
                JazzArchiveProjectionReconciler.deliveryPolicyExtension:
                    .string(JazzCaptureDeliveryPolicy.liveCompatibility.rawValue)
            ])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: legacySessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "desktop-consent-v1",
                consentedAt: timestamp,
                modalities: [.screenshots],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        let context = CaptureJournalActivityContext(
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            sourceId: sourceId,
            actorId: actorId,
            policyVersion: "desktop-consent-v1")
        let journal = CaptureJournal(root: root)
        do {
            _ = try await journal.begin(manifest: manifest, session: session)
        } catch {
            XCTFail("begin capability archive: \(error)")
            return
        }
        let writer = CaptureCapabilityJournalWriter(
            journal: journal,
            context: context)
        var machine = JazzCaptureCapabilityStateMachine()
        let initial = try XCTUnwrap(
            machine.observe(
                JazzCaptureCapabilitySample(
                    capability: .screenCapture,
                    authorization: .granted,
                    availability: .available,
                    reason: .permissionGranted),
                at: timestamp))
        let failed = try XCTUnwrap(
            machine.observe(
                JazzCaptureCapabilitySample(
                    capability: .screenCapture,
                    authorization: .granted,
                    availability: .unavailable,
                    reason: .sourceFailure),
                at: "2026-07-26T10:00:01.000Z"))
        do {
            _ = try await writer.append(initial)
            _ = try await writer.append(failed)
        } catch {
            XCTFail("append capability observations: \(error)")
            return
        }
        let commit: JazzArchiveCaptureCommit
        do {
            _ = try await journal.closeInput()
            _ = try await journal.beginDraining()
            commit = try await journal.commit(
                endedAt: "2026-07-26T10:00:02.000Z")
        } catch {
            XCTFail("commit capability archive: \(error)")
            return
        }
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 2)

        let transportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "jazz-capability-transport-\(UUID().uuidString)",
                isDirectory: true)
        defer { try? FileManager.default.removeItem(at: transportRoot) }
        let compatibilitySpool = EventSpool(
            root: transportRoot.appendingPathComponent("spool"))
        let artifactQueue = JazzArchiveDeliveryQueue(
            root: transportRoot.appendingPathComponent("artifacts"))
        let reconciliation: JazzArchiveProjectionReconciliation
        do {
            reconciliation = try await JazzArchiveProjectionReconciler(
                archiveRoot: root,
                eventSpool: compatibilitySpool,
                artifactQueue: artifactQueue
            ).reconcile(archiveId: archiveId)
        } catch {
            XCTFail("reconcile capability archive: \(error)")
            return
        }
        XCTAssertEqual(reconciliation.observationCount, 2)
        XCTAssertEqual(reconciliation.artifactCount, 0)
        XCTAssertTrue(
            compatibilitySpool.sessionEvents(sessionId: legacySessionId).isEmpty,
            "capability evidence must not fabricate a legacy ActivityEvent")
        let projectedBatches = compatibilitySpool.pendingBatches()
        XCTAssertEqual(projectedBatches.count, 2)
        for batch in projectedBatches {
            let live = try XCTUnwrap(
                compatibilitySpool.readLiveProjection(batch))
            XCTAssertEqual(
                live.observation.recordType,
                ArchiveRecord<JazzCaptureCapabilityObservation>
                    .captureCapabilityRecordType)
            XCTAssertEqual(
                try JazzLiveOtlpProjection.genericLogRecords(
                    batch: live,
                    context: OtlpMapper.SessionContext(
                        sessionId: legacySessionId,
                        traceId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                        spanId: "bbbbbbbbbbbbbbbb",
                        startedAt: timestamp,
                        user: "fixture@example.com")
                ).count,
                1)
        }

        let package: JazzArchiveFinalizedPackage
        do {
            package = try await JazzArchiveFinalizer(root: root).finalize(
                archiveId: archiveId,
                snapshotAt: "2026-07-26T10:00:03.000Z")
        } catch {
            XCTFail("finalize capability archive: \(error)")
            return
        }
        let recordsEntry = try XCTUnwrap(
            package.inventory.entries.first {
                $0.path.hasSuffix("/records.ndjson")
            })
        let records = try String(
            decoding: Data(
                contentsOf: package.url.appendingPathComponent(recordsEntry.path)),
            as: UTF8.self
        )
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map {
            try JSONDecoder().decode(
                JazzArchiveRecord.self,
                from: Data($0.utf8))
        }
        let observations = try records.map {
            try $0.captureCapabilityObservationRecord().payload
        }
        XCTAssertEqual(
            observations.map(\.transition),
            [.initial, .sourceFailed])
    }

    func testSourceSummaryDeniedForWholeCaptureIsUnavailableAndPartial() throws {
        let fixture = summaryFixture(
            capability: .screenCapture,
            modality: .screenshots,
            seedReason: .unknown)
        let records = try summaryRecords(
            fixture,
            observations: [
                JazzCaptureCapabilityObservation(
                    capability: .screenCapture,
                    authorizationStatus: .denied,
                    availability: .unavailable,
                    transition: .initial,
                    reason: .permissionDenied,
                    observedAt: "2026-07-26T10:00:00.000Z")
            ])

        let summary = try JazzCaptureCapabilitySourceSummary.materialize(
            manifest: fixture.manifest,
            records: records)
        let source = try XCTUnwrap(summary.sources.first)
        XCTAssertFalse(source.capabilities.contains("screen.capture"))
        XCTAssertEqual(
            source.unavailableCapabilities.first {
                $0.capability == "screen.capture"
            }?.reason,
            .permissionDenied)
        let quality = JazzCaptureCapabilitySourceSummary.materializeQuality(
            session: fixture.session,
            manifest: summary)
        XCTAssertEqual(quality.status, .partial)
        XCTAssertEqual(
            quality.reasons,
            ["capture_capability.screen.capture.permission_denied"])
    }

    func testSourceSummaryRestoredLaterCountsAsSuppliedAndComplete() throws {
        let fixture = summaryFixture(
            capability: .screenCapture,
            modality: .screenshots,
            seedReason: .unknown)
        let records = try summaryRecords(
            fixture,
            observations: [
                JazzCaptureCapabilityObservation(
                    capability: .screenCapture,
                    authorizationStatus: .denied,
                    availability: .unavailable,
                    transition: .initial,
                    reason: .permissionDenied,
                    observedAt: "2026-07-26T10:00:00.000Z"),
                JazzCaptureCapabilityObservation(
                    capability: .screenCapture,
                    authorizationStatus: .granted,
                    availability: .available,
                    transition: .restored,
                    reason: .permissionGranted,
                    observedAt: "2026-07-26T10:00:01.000Z",
                    previousAuthorization: .denied,
                    previousAvailability: .unavailable),
            ])

        let summary = try JazzCaptureCapabilitySourceSummary.materialize(
            manifest: fixture.manifest,
            records: records)
        let source = try XCTUnwrap(summary.sources.first)
        XCTAssertTrue(source.capabilities.contains("screen.capture"))
        XCTAssertFalse(source.unavailableCapabilities.contains {
            $0.capability == "screen.capture"
        })
        XCTAssertEqual(
            JazzCaptureCapabilitySourceSummary.materializeQuality(
                session: fixture.session,
                manifest: summary),
            JazzArchiveQuality(status: .complete))
    }

    func testSourceSummaryTemporaryOutageAfterAvailabilityRemainsSupplied()
        throws
    {
        let fixture = summaryFixture(
            capability: .pointerCapture,
            modality: .pointer,
            seedReason: .unknown)
        let records = try summaryRecords(
            fixture,
            observations: [
                JazzCaptureCapabilityObservation(
                    capability: .pointerCapture,
                    authorizationStatus: .granted,
                    availability: .available,
                    transition: .initial,
                    reason: .permissionGranted,
                    observedAt: "2026-07-26T10:00:00.000Z"),
                JazzCaptureCapabilityObservation(
                    capability: .pointerCapture,
                    authorizationStatus: .granted,
                    availability: .unavailable,
                    transition: .temporarilyDisabled,
                    reason: .secureInput,
                    observedAt: "2026-07-26T10:00:01.000Z",
                    previousAuthorization: .granted,
                    previousAvailability: .available),
            ])

        let summary = try JazzCaptureCapabilitySourceSummary.materialize(
            manifest: fixture.manifest,
            records: records)
        let source = try XCTUnwrap(summary.sources.first)
        XCTAssertTrue(source.capabilities.contains("pointer.capture"))
        XCTAssertFalse(source.unavailableCapabilities.contains {
            $0.capability == "pointer.capture"
        })
        XCTAssertEqual(
            JazzCaptureCapabilitySourceSummary.materializeQuality(
                session: fixture.session,
                manifest: summary
            ).status,
            .complete)
    }

    func testSourceSummaryPolicyDisabledRemainsExplicitWithoutQualityPenalty()
        throws
    {
        let fixture = summaryFixture(
            capability: .audioCapture,
            modality: .narration,
            seedReason: .disabledByPolicy)
        let records = try summaryRecords(
            fixture,
            observations: [
                JazzCaptureCapabilityObservation(
                    capability: .audioCapture,
                    authorizationStatus: .granted,
                    availability: .unavailable,
                    transition: .initial,
                    reason: .captureDisabledByPolicy,
                    observedAt: "2026-07-26T10:00:00.000Z")
            ])

        let summary = try JazzCaptureCapabilitySourceSummary.materialize(
            manifest: fixture.manifest,
            records: records)
        let source = try XCTUnwrap(summary.sources.first)
        XCTAssertFalse(source.capabilities.contains("audio.capture"))
        XCTAssertEqual(
            source.unavailableCapabilities.first {
                $0.capability == "audio.capture"
            }?.reason,
            .disabledByPolicy)
        XCTAssertEqual(
            JazzCaptureCapabilitySourceSummary.materializeQuality(
                session: fixture.session,
                manifest: summary),
            JazzArchiveQuality(status: .complete))
    }

    func testCommitMaterializesDeniedSummaryAndPartialSessionQuality()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-capability-summary-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = summaryFixture(
            capability: .screenCapture,
            modality: .screenshots,
            seedReason: .unknown)
        let journal = CaptureJournal(root: root)
        _ = try await journal.begin(
            manifest: fixture.manifest,
            session: fixture.session)
        let writer = CaptureCapabilityJournalWriter(
            journal: journal,
            context: fixture.context)
        _ = try await writer.append(
            JazzCaptureCapabilityObservation(
                capability: .screenCapture,
                authorizationStatus: .denied,
                availability: .unavailable,
                transition: .initial,
                reason: .permissionDenied,
                observedAt: "2026-07-26T10:00:00.000Z"))
        _ = try await journal.closeInput()
        _ = try await journal.beginDraining()
        _ = try await journal.commit(
            endedAt: "2026-07-26T10:00:01.000Z")

        let store = JazzArchiveDraftStore(root: root)
        let manifest = try await store.manifest(
            archiveId: fixture.manifest.archiveId)
        let session = try await store.session(
            archiveId: fixture.manifest.archiveId,
            captureId: fixture.session.captureId)
        XCTAssertEqual(
            manifest.sources[0].unavailableCapabilities.first {
                $0.capability == "screen.capture"
            }?.reason,
            .permissionDenied)
        XCTAssertFalse(
            manifest.sources[0].capabilities.contains("screen.capture"))
        XCTAssertEqual(session.quality.status, .partial)
        XCTAssertEqual(
            session.quality.reasons,
            ["capture_capability.screen.capture.permission_denied"])
    }

    private struct SummaryFixture {
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var context: CaptureJournalActivityContext
    }

    private func summaryFixture(
        capability: JazzCaptureCapability,
        modality: JazzArchiveModality?,
        seedReason: JazzArchiveCapabilityUnavailableReason
    ) -> SummaryFixture {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let sourceId = Identifiers.newSourceId()
        let actorId = Identifiers.newActorId()
        let timestamp = "2026-07-26T10:00:00.000Z"
        let producer = JazzArchiveProducer(name: "Jazz", version: "test")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: timestamp,
            producer: producer,
            contracts: [.captureCapabilityObservation],
            actors: [
                JazzArchiveActor(
                    actorId: actorId,
                    kind: .human,
                    provenance: JazzArchiveProvenance(
                        factClass: .declared,
                        sources: []))
            ],
            sources: [
                JazzArchiveSource(
                    sourceId: sourceId,
                    kind: "macos.native",
                    actorId: actorId,
                    producer: producer,
                    capabilities: [],
                    unavailableCapabilities: [
                        JazzArchiveUnavailableCapability(
                            capability: capability.rawValue,
                            reason: seedReason)
                    ],
                    provenance: JazzArchiveProvenance(
                        factClass: .observed,
                        sources: []))
            ],
            sessions: [JazzArchiveSessionRef(captureId: captureId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "test",
                consentedAt: timestamp,
                modalities: modality.map { [$0] } ?? [],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return SummaryFixture(
            manifest: manifest,
            session: session,
            context: CaptureJournalActivityContext(
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                policyVersion: "test"))
    }

    private func summaryRecords(
        _ fixture: SummaryFixture,
        observations: [JazzCaptureCapabilityObservation]
    ) throws -> [JazzArchiveRecord] {
        try observations.enumerated().map { sequence, observation in
            try JazzArchiveRecord(
                erasing: ArchiveRecord(
                    capabilityObservation: observation,
                    context: fixture.context,
                    streamSequence: sequence))
        }
    }
}
