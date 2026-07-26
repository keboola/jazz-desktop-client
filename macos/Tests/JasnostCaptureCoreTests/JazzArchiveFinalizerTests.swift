import XCTest

@testable import JasnostCaptureCore

final class JazzArchiveFinalizerTests: XCTestCase {
    private let timestamp = "2026-07-22T11:00:00.000Z"

    private struct Fixture {
        var manifest: JazzArchiveManifest
        var session: JazzArchiveSession
        var originId: String
        var captureId: String
        var streamId: String
        var actorId: String
        var sourceId: String
        var legacySessionId: String
    }

    private func fixture() -> Fixture {
        let archiveId = Identifiers.newArchiveId()
        let originId = Identifiers.newOriginId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let sessionId = Identifiers.newSessionId()
        let producer = JazzArchiveProducer(
            name: "Jazz Capture", version: "test", platform: "macOS")
        let actor = JazzArchiveActor(
            actorId: actorId,
            kind: .human,
            displayName: "Recorder",
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let source = JazzArchiveSource(
            sourceId: sourceId,
            kind: "macos.capture-controller",
            actorId: actorId,
            producer: producer,
            capabilities: ["session_boundaries"],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: timestamp,
            producer: producer,
            actors: [actor],
            sources: [source],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId, legacySessionId: sessionId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: timestamp,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            area: JazzArchiveArea(
                areaId: "finance",
                nameSnapshot: "Finance",
                registryRevision: "registry-7"),
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: timestamp,
                modalities: [],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        return Fixture(
            manifest: manifest,
            session: session,
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            actorId: actorId,
            sourceId: sourceId,
            legacySessionId: sessionId)
    }

    private func record(_ fixture: Fixture, sequence: Int) -> ArchiveRecord<ActivityEvent> {
        let event = ActivityEvent(
            sessionId: fixture.legacySessionId,
            eventId: Identifiers.eventId(
                sessionId: fixture.legacySessionId, sequence: sequence),
            sequence: sequence,
            timestamp: timestamp,
            eventType: sequence == 0 ? "session_start" : "session_end",
            url: "app://session")
        return ArchiveRecord(
            event: event,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: sequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "performer",
                basis: .declared)],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("jazz-finalizer-tests-\(UUID().uuidString)")
    }

    private func labelBoundaryRecord(
        _ fixture: Fixture,
        sequence: Int,
        observationId: String,
        eventType: EventType,
        labelId: String,
        extensions: [String: JazzArchiveJSONValue]? = nil
    ) -> ArchiveRecord<ActivityEvent> {
        ArchiveRecord(
            event: ActivityEvent(
                sessionId: fixture.legacySessionId,
                eventId: Identifiers.eventId(
                    sessionId: fixture.legacySessionId, sequence: sequence),
                sequence: sequence,
                timestamp: timestamp,
                eventType: eventType.rawValue,
                url: "app://session",
                labelId: labelId,
                label: "Book monthly orders",
                processId: "monthly-booking",
                process: "Monthly booking"),
            observationId: observationId,
            originId: fixture.originId,
            captureId: fixture.captureId,
            streamId: fixture.streamId,
            streamSequence: sequence,
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: fixture.sourceId, role: "trigger")],
            actorRefs: [JazzArchiveActorRef(
                actorId: fixture.actorId,
                role: "performer",
                basis: .declared,
                method: "session_recorder")],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [fixture.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"),
            extensions: extensions)
    }

    func testFinalizeCompactsBatchesAndExportIsDeterministic() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: value.manifest, session: value.session)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 1)])
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 0)])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z")

        let finalizer = JazzArchiveFinalizer(root: root)
        let first = try await finalizer.finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2026-07-22T11:02:00.000Z")
        XCTAssertEqual(first.manifest.state, .finalized)
        XCTAssertFalse(first.inventory.entries.contains { $0.path.contains("/records/") })
        let compact = try XCTUnwrap(
            first.inventory.entries.first { $0.path.hasSuffix("/records.ndjson") })
        let compactData = try Data(contentsOf: first.url.appendingPathComponent(compact.path))
        let compactLines = String(decoding: compactData, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(compactLines.count, 2)
        XCTAssertTrue(compactLines[0].contains("\"streamSequence\":0"))
        XCTAssertTrue(compactLines[1].contains("\"streamSequence\":1"))

        var unsigned = first.manifest
        unsigned.contentDigest = nil
        XCTAssertEqual(
            first.manifest.contentDigest,
            JazzArchiveDigest.sha256Hex(try JazzArchiveCanonicalJSON.encode(unsigned)))

        let second = try await finalizer.finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2099-01-01T00:00:00.000Z")
        XCTAssertEqual(first.manifest.contentDigest, second.manifest.contentDigest)
        XCTAssertEqual(first.manifest.snapshotAt, second.manifest.snapshotAt)

        let exportURL = root.appendingPathComponent("capture.jazz-archive")
        try await finalizer.export(first, to: exportURL)
        let firstBytes = try Data(contentsOf: exportURL)
        try await finalizer.export(second, to: exportURL)
        XCTAssertEqual(firstBytes, try Data(contentsOf: exportURL))
        XCTAssertEqual(Array(firstBytes.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
        XCTAssertTrue(firstBytes.range(of: Data("manifest.json".utf8)) != nil)
        XCTAssertTrue(firstBytes.range(of: Data("inventory.json".utf8)) != nil)
    }

    func testFinalizeEmitsCanonicalArtifactAndLabelNDJSON() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: value.manifest, session: value.session)

        let labelId = Identifiers.newLabelId()
        let startObservationId = Identifiers.newObservationId()
        let endObservationId = Identifiers.newObservationId()
        let start = labelBoundaryRecord(
            value,
            sequence: 0,
            observationId: startObservationId,
            eventType: .labelStart,
            labelId: labelId,
            extensions: [
                "dev.jazz.label.declarationMode": .string("guided"),
                "dev.jazz.label.bindingResolution": .string("unique_substring"),
                "dev.jazz.label.declarationText": .string("Book the monthly orders"),
            ])
        let end = labelBoundaryRecord(
            value,
            sequence: 2,
            observationId: endObservationId,
            eventType: .labelEnd,
            labelId: labelId)

        let bytes = Data("narration".utf8)
        let digest = JazzArchiveDigest.sha256Hex(bytes)
        let artifactId = Identifiers.newArtifactId()
        let artifact = JazzArchiveArtifact(
            artifactId: artifactId,
            captureId: value.captureId,
            kind: "narration_audio",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(digest.prefix(2))/\(digest)",
                mediaType: "audio/mp4",
                byteLength: Int64(bytes.count),
                sha256: digest),
            sourceRefs: [JazzArchiveSourceRef(
                sourceId: value.sourceId, role: "microphone_capture")],
            actorRefs: [JazzArchiveActorRef(
                actorId: value.actorId,
                role: "narrator",
                basis: .declared,
                method: "session_recorder")],
            labelRefs: [labelId],
            observationRefs: [startObservationId],
            provenance: JazzArchiveProvenance(
                factClass: .observed, sources: [value.sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(
                status: .captured, policyVersion: "consent-v1"))
        _ = try await store.ingestArtifact(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            artifact: artifact,
            bytes: bytes)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [start, end])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z",
            artifactDigests: [artifactId: digest])

        let package = try await JazzArchiveFinalizer(root: root).finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2026-07-22T11:02:00.000Z")
        XCTAssertFalse(package.inventory.entries.contains {
            $0.path.contains("/artifacts/")
        })
        let artifactsEntry = try XCTUnwrap(package.inventory.entries.first {
            $0.path.hasSuffix("/artifacts.ndjson")
        })
        let artifactLines = String(
            decoding: try Data(
                contentsOf: package.url.appendingPathComponent(artifactsEntry.path)),
            as: UTF8.self
        ).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(artifactLines.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(
                JazzArchiveArtifact.self, from: Data(artifactLines[0].utf8)),
            artifact)

        let labelsEntry = try XCTUnwrap(package.inventory.entries.first {
            $0.path.hasSuffix("/labels.ndjson")
        })
        let labelLines = String(
            decoding: try Data(
                contentsOf: package.url.appendingPathComponent(labelsEntry.path)),
            as: UTF8.self
        ).split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(labelLines.count, 1)
        let label = try JSONDecoder().decode(
            JazzArchiveLabel.self, from: Data(labelLines[0].utf8))
        XCTAssertEqual(label.labelId, labelId)
        XCTAssertEqual(label.status, .closed)
        XCTAssertEqual(label.interval.startObservationId, startObservationId)
        XCTAssertEqual(label.interval.endObservationId, endObservationId)
        XCTAssertEqual(label.declaration.text, "Book the monthly orders")
        XCTAssertEqual(label.declaration.mode, .guided)
        XCTAssertEqual(label.processBinding?.resolution, .uniqueSubstring)
        XCTAssertEqual(label.narrationArtifactRefs, [artifactId])

        let exportURL = root.appendingPathComponent("canonical-layout.jazz-archive")
        _ = try await JazzArchiveFinalizer(root: root).export(package, to: exportURL)
        let imported = try await JazzArchiveImporter(
            root: root.appendingPathComponent("imported-library", isDirectory: true)
        ).importArchive(
            at: exportURL,
            importedAt: "2026-07-22T11:03:00.000Z")
        XCTAssertEqual(
            try imported.snapshot.labels(captureId: value.captureId).map(\.labelId),
            [labelId])
        XCTAssertEqual(
            try imported.snapshot.artifacts(captureId: value.captureId).map(\.artifactId),
            [artifactId])
    }

    func testUncommittedCaptureCannotFinalize() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: value.manifest, session: value.session)
        let review = JazzArchiveReviewStore(root: root)
        _ = try await review.append(
            archiveId: value.manifest.archiveId,
            assertion: JazzArchiveAssertion(
                target: JazzArchiveAssertionTarget(
                    kind: .archive, id: value.manifest.archiveId),
                decision: .confirm,
                authoredByActorId: value.actorId,
                baseRevision: value.manifest.revision,
                scope: .archive,
                provenance: JazzArchiveProvenance(factClass: .declared, sources: [])))

        let finalizer = JazzArchiveFinalizer(root: root)
        do {
            _ = try await finalizer.finalize(
                archiveId: value.manifest.archiveId,
                requireArchiveConfirmation: true)
            XCTFail("expected captureNotCommitted")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .captureNotCommitted(value.manifest.archiveId))
        }
    }

    func testReviewAppendFailsClosedAndRetryResynchronizesPublishedAssertion()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        _ = try await JazzArchiveDraftStore(
            root: root,
            durability: foundationTestFilesystemDurability()
        ).create(manifest: value.manifest, session: value.session)
        let assertionId = Identifiers.newAssertionId()
        let assertion = JazzArchiveAssertion(
            assertionId: assertionId,
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: value.manifest.archiveId),
            decision: .confirm,
            authoredByActorId: value.actorId,
            authoredAt: timestamp,
            baseRevision: value.manifest.revision,
            scope: .archive,
            provenance: JazzArchiveProvenance(
                factClass: .declared, sources: []))
        let assertionURL = root
            .appendingPathComponent(".review", isDirectory: true)
            .appendingPathComponent(value.manifest.archiveId, isDirectory: true)
            .appendingPathComponent("assertions", isDirectory: true)
            .appendingPathComponent("\(assertionId).json")
        let recorder = CanonicalDurabilityRecorder()
        recorder.failOnce(on: .file(
            CanonicalDurabilityRecorder.path(assertionURL)))
        let failing = JazzArchiveReviewStore(
            root: root, durability: recorder.value())

        do {
            _ = try await failing.append(
                archiveId: value.manifest.archiveId, assertion: assertion)
            XCTFail("append must not report success before assertion durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: assertionURL.path))

        let retry = JazzArchiveReviewStore(
            root: root,
            durability: foundationTestFilesystemDurability())
        let appended = try await retry.append(
            archiveId: value.manifest.archiveId, assertion: assertion)
        XCTAssertFalse(appended)
        let latest = try await retry.latestArchiveAssertion(
            archiveId: value.manifest.archiveId)
        XCTAssertEqual(latest?.assertionId, assertionId)
    }

    func testFinalizationAndExportFailClosedUntilPublishedBytesAreSynchronized()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let foundation = foundationTestFilesystemDurability()
        let store = JazzArchiveDraftStore(
            root: root, durability: foundation)
        _ = try await store.create(
            manifest: value.manifest, session: value.session)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 0)])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z")

        let finalizedDirectory = root.appendingPathComponent(
            "\(value.manifest.archiveId).jazz-archive.finalized",
            isDirectory: true)
        let finalizationRecorder = CanonicalDurabilityRecorder()
        finalizationRecorder.failOnce(on: .directory(
            CanonicalDurabilityRecorder.path(finalizedDirectory)))
        let failingFinalizer = JazzArchiveFinalizer(
            root: root, durability: finalizationRecorder.value())
        do {
            _ = try await failingFinalizer.finalize(
                archiveId: value.manifest.archiveId,
                snapshotAt: "2026-07-22T11:02:00.000Z")
            XCTFail("finalize must not report success before snapshot durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: finalizedDirectory.path))

        let healthyFinalizer = JazzArchiveFinalizer(
            root: root, durability: foundation)
        let package = try await healthyFinalizer.finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2099-01-01T00:00:00.000Z")
        XCTAssertEqual(package.manifest.state, .finalized)

        let exportURL = root.appendingPathComponent(
            "\(value.manifest.archiveId).jazz-archive")
        let exportRecorder = CanonicalDurabilityRecorder()
        exportRecorder.failOnce(on: .file(
            CanonicalDurabilityRecorder.path(exportURL)))
        let failingExporter = JazzArchiveFinalizer(
            root: root, durability: exportRecorder.value())
        do {
            _ = try await failingExporter.export(package, to: exportURL)
            XCTFail("export must not report success before ZIP durability")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        _ = try await healthyFinalizer.export(package, to: exportURL)
        XCTAssertGreaterThan(
            try Data(contentsOf: exportURL).count, 0)
    }

    func testNestedExportRetryResynchronizesEveryAncestorAfterPartialBarrierFailure()
        async throws
    {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let foundation = foundationTestFilesystemDurability()
        let store = JazzArchiveDraftStore(
            root: root, durability: foundation)
        _ = try await store.create(
            manifest: value.manifest, session: value.session)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 0)])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z")
        let package = try await JazzArchiveFinalizer(
            root: root, durability: foundation
        ).finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2026-07-22T11:02:00.000Z")

        let createdAncestor = root.appendingPathComponent(
            "exports/new/deep", isDirectory: true)
        let output = createdAncestor.appendingPathComponent(
            "capture.jazz-archive")
        let failedAncestor = root.appendingPathComponent(
            "exports", isDirectory: true)
        let recorder = CanonicalDurabilityRecorder()
        recorder.failOnce(on: .directory(
            CanonicalDurabilityRecorder.path(failedAncestor)))
        let exporter = JazzArchiveFinalizer(
            root: root, durability: recorder.value())

        do {
            _ = try await exporter.export(package, to: output)
            XCTFail("export must fail closed after a partial ancestor barrier")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFilesystemDurabilityError,
                .synchronizationFailed)
        }
        let publishedBytes = try Data(contentsOf: output)
        XCTAssertFalse(publishedBytes.isEmpty)

        _ = try await exporter.export(package, to: output)
        XCTAssertEqual(try Data(contentsOf: output), publishedBytes)
        let events = recorder.events()
        let expectedAncestors = [
            createdAncestor,
            createdAncestor.deletingLastPathComponent(),
            failedAncestor,
            root,
            root.deletingLastPathComponent(),
        ].map {
            CanonicalDurabilityRecorder.Event.directory(
                CanonicalDurabilityRecorder.path($0))
        }
        for ancestor in expectedAncestors {
            XCTAssertGreaterThanOrEqual(
                events.filter { $0 == ancestor }.count,
                1,
                "retry must synchronize \(ancestor)")
        }
        XCTAssertGreaterThanOrEqual(
            events.filter {
                $0 == .directory(
                    CanonicalDurabilityRecorder.path(failedAncestor))
            }.count,
            2,
            "the failed ancestor must be retried")
        XCTAssertEqual(
            events.filter {
                $0 == .directory("/")
            }.count,
            1,
            "the successful retry synchronizes the filesystem root exactly once")
        XCTAssertFalse(events.contains {
            if case let .directory(path) = $0 {
                return path.split(separator: "/").contains("..")
            }
            return false
        })
    }

    func testReviewIsAppendOnlyAndExportRequiresLatestArchiveConfirmation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: value.manifest, session: value.session)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 0)])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z")

        let finalizer = JazzArchiveFinalizer(root: root)
        do {
            _ = try await finalizer.finalize(
                archiveId: value.manifest.archiveId,
                requireArchiveConfirmation: true)
            XCTFail("expected archiveNotConfirmed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(value.manifest.archiveId))
        }

        let review = JazzArchiveReviewStore(root: root)
        let rejected = JazzArchiveAssertion(
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: value.manifest.archiveId),
            decision: .reject,
            reason: "Needs a correction",
            authoredByActorId: value.actorId,
            authoredAt: "2026-07-22T11:01:10.000Z",
            baseRevision: value.manifest.revision,
            scope: .archive,
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let appendedReject = try await review.append(
            archiveId: value.manifest.archiveId, assertion: rejected)
        XCTAssertTrue(appendedReject)
        do {
            _ = try await finalizer.finalize(
                archiveId: value.manifest.archiveId,
                requireArchiveConfirmation: true)
            XCTFail("latest reject must block export")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(value.manifest.archiveId))
        }

        let firstConfirmation = JazzArchiveAssertion(
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: value.manifest.archiveId),
            decision: .confirm,
            authoredByActorId: value.actorId,
            // Simulate wall-clock rollback: chain order, never authoredAt, determines the head.
            authoredAt: "2026-07-22T10:59:00.000Z",
            baseRevision: value.manifest.revision,
            scope: .archive,
            supersedes: rejected.assertionId,
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        _ = try await review.append(
            archiveId: value.manifest.archiveId, assertion: firstConfirmation)
        let latestReject = JazzArchiveAssertion(
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: value.manifest.archiveId),
            decision: .reject,
            reason: "Found another issue",
            authoredByActorId: value.actorId,
            authoredAt: "2026-07-22T10:58:00.000Z",
            baseRevision: value.manifest.revision,
            scope: .archive,
            supersedes: firstConfirmation.assertionId,
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        _ = try await review.append(
            archiveId: value.manifest.archiveId, assertion: latestReject)
        do {
            _ = try await finalizer.finalize(
                archiveId: value.manifest.archiveId,
                requireArchiveConfirmation: true)
            XCTFail("structural latest reject must block despite older authoredAt")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .archiveNotConfirmed(value.manifest.archiveId))
        }

        let confirmed = JazzArchiveAssertion(
            target: JazzArchiveAssertionTarget(
                kind: .archive, id: value.manifest.archiveId),
            decision: .confirm,
            authoredByActorId: value.actorId,
            authoredAt: "2026-07-22T10:57:00.000Z",
            baseRevision: value.manifest.revision,
            scope: .archive,
            supersedes: latestReject.assertionId,
            provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
        let appendedConfirmation = try await review.append(
            archiveId: value.manifest.archiveId, assertion: confirmed)
        let repeatedConfirmation = try await review.append(
            archiveId: value.manifest.archiveId, assertion: confirmed)
        XCTAssertTrue(appendedConfirmation)
        XCTAssertFalse(repeatedConfirmation)

        let package = try await finalizer.finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2026-07-22T11:02:00.000Z",
            requireArchiveConfirmation: true)
        let assertionEntries = package.inventory.entries.filter {
            $0.path.hasPrefix("assertions/")
        }
        XCTAssertEqual(assertionEntries.count, 4)
        let latest = try await review.latestArchiveAssertion(
            archiveId: value.manifest.archiveId)
        XCTAssertEqual(latest?.decision, .confirm)
    }

    func testExportNeverOverwritesDifferentBytes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = fixture()
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: value.manifest, session: value.session)
        _ = try await store.append(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            records: [record(value, sequence: 0)])
        _ = try await store.end(
            archiveId: value.manifest.archiveId,
            captureId: value.captureId,
            endedAt: "2026-07-22T11:01:00.000Z")
        let finalizer = JazzArchiveFinalizer(root: root)
        let package = try await finalizer.finalize(
            archiveId: value.manifest.archiveId,
            snapshotAt: "2026-07-22T11:02:00.000Z")
        let output = root.appendingPathComponent("occupied.jazz-archive")
        let original = Data("do-not-overwrite".utf8)
        try original.write(to: output)

        do {
            try await finalizer.export(package, to: output)
            XCTFail("expected exportConflict")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveFinalizationError,
                .exportConflict(output.path))
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }
}
