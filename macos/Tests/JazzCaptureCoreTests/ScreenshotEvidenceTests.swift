import XCTest

@testable import JazzCaptureCore

final class ScreenshotEvidenceTests: XCTestCase {
    private func boundScreenshot(
        exclusions: [String] = ["com.example.password-manager"]
    ) -> (
        manifest: JazzArchiveManifest,
        session: JazzArchiveSession,
        artifact: JazzArchiveArtifact
    ) {
        let archiveId = "ar-11111111-1111-7111-8111-111111111111"
        let captureId = "cap-11111111-1111-7111-8111-111111111111"
        let actorId = "actor-11111111-1111-7111-8111-111111111111"
        let sourceId = "src-11111111-1111-7111-8111-111111111111"
        let producer = JazzArchiveProducer(name: "Screenshot test", version: "1")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: "origin-11111111-1111-7111-8111-111111111111",
            createdAt: "2026-07-27T10:00:00.000Z",
            producer: producer,
            actors: [
                JazzArchiveActor(
                    actorId: actorId,
                    kind: .human,
                    identityStatus: .identified,
                    displayName: "Recorder",
                    provenance: JazzArchiveProvenance(
                        factClass: .declared,
                        sources: []))
            ],
            sources: [
                JazzArchiveSource(
                    sourceId: sourceId,
                    kind: "macos.capture-controller",
                    actorId: actorId,
                    producer: producer,
                    provenance: JazzArchiveProvenance(
                        factClass: .observed,
                        sources: []))
            ],
            sessions: [JazzArchiveSessionRef(captureId: captureId)])
        let session = JazzArchiveSession(
            captureId: captureId,
            archiveId: archiveId,
            streamIds: ["stream-11111111-1111-7111-8111-111111111111"],
            startedAt: "2026-07-27T10:00:00.000Z",
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "consent-v1",
                consentedAt: "2026-07-27T09:59:59.000Z",
                modalities: [.pointer, .screenshots],
                excludedApplications: ["com.example.password-manager"],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        let evidence = JazzArchiveScreenshotEvidenceV1(
            requestStartedAt: "2026-07-27T10:00:00.000Z",
            frameCompletedAt: "2026-07-27T10:00:00.125Z",
            monotonicDurationMillis: 125,
            scope: .display(
                displayId: 7,
                excludedApplicationBundleIds: exclusions))
        let digest = String(repeating: "a", count: 64)
        let artifact = JazzArchiveArtifact(
            artifactId: "art-11111111-1111-7111-8111-111111111111",
            captureId: captureId,
            kind: "screenshot",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/aa/\(digest)",
                mediaType: "image/jpeg",
                byteLength: 1,
                sha256: digest),
            sourceRefs: [
                JazzArchiveSourceRef(
                    sourceId: sourceId,
                    role: "screen_capture")
            ],
            captureInterval: JazzArchiveArtifactCaptureInterval(
                startedAt: evidence.requestStartedAt,
                endedAt: evidence.frameCompletedAt),
            provenance: JazzArchiveProvenance(
                factClass: .observed,
                sources: [sourceId]),
            quality: JazzArchiveQuality(
                status: .partial,
                reasons: [
                    JazzArchiveScreenshotEvidenceV1.temporalIntervalReason,
                    JazzArchiveScreenshotEvidenceV1.displayFallbackReason,
                ],
                timingErrorMillis: 125),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "consent-v1"),
            extensions: evidence.extensions)
        return (manifest, session, artifact)
    }

    func testCaptureIntervalRejectsClockReversal() throws {
        try JazzArchiveArtifactCaptureInterval(
            startedAt: "2026-07-27T10:00:00.000Z",
            endedAt: "2026-07-27T10:00:00.125Z"
        ).validate()

        XCTAssertThrowsError(
            try JazzArchiveArtifactCaptureInterval(
                startedAt: "2026-07-27T10:00:00.125Z",
                endedAt: "2026-07-27T10:00:00.000Z"
            ).validate()
        ) { error in
            XCTAssertEqual(
                error as? JazzArchiveError,
                .invalidField(
                    "artifact.captureInterval.endedAt before startedAt"))
        }
    }

    func testPortableProfileRoundTripsExactVersionedKeys() throws {
        let value = JazzArchiveScreenshotEvidenceV1(
            requestStartedAt: "2026-07-27T10:00:00.000Z",
            frameCompletedAt: "2026-07-27T10:00:00.125Z",
            monotonicDurationMillis: 125,
            scope: .display(
                displayId: 7,
                excludedApplicationBundleIds: [
                    "com.example.bank",
                    "com.example.password-manager",
                ]))

        try value.validate()
        XCTAssertEqual(
            try JazzArchiveScreenshotEvidenceV1.decode(from: value.extensions),
            value)
        XCTAssertEqual(
            value.extensions[JazzArchiveScreenshotEvidenceV1.scopeKey],
            .string("display"))
    }

    func testPortableProfileRejectsPartialUnknownAndInconsistentEvidence() {
        XCTAssertThrowsError(
            try JazzArchiveScreenshotEvidenceV1.decode(from: [
                JazzArchiveScreenshotEvidenceV1.scopeKey: .string("window")
            ]))
        XCTAssertThrowsError(
            try JazzArchiveScreenshotEvidenceV1.decode(from: [
                "\(JazzArchiveScreenshotEvidenceV1.namespace).futureGuess": .bool(true)
            ]))
        XCTAssertThrowsError(
            try JazzArchiveScreenshotEvidenceV1(
                requestStartedAt: "2026-07-27T10:00:00.000Z",
                frameCompletedAt: "2026-07-27T10:00:00.125Z",
                monotonicDurationMillis: 125,
                scope: .display(
                    displayId: 7,
                    excludedApplicationBundleIds: [
                        "com.example.password-manager",
                        "com.example.bank",
                    ])
            ).validate())
    }

    func testPortableProfileRequiresExactMonotonicDuration() throws {
        let scope = JazzArchiveScreenshotEvidenceV1.Scope.window(
            ownerBundleId: "com.example.app",
            windowId: 17)
        try JazzArchiveScreenshotEvidenceV1(
            requestStartedAt: "2026-07-27T10:00:00.000Z",
            frameCompletedAt: "2026-07-27T10:00:00.125Z",
            monotonicDurationMillis: 125,
            scope: scope
        ).validate()

        for mismatchedDuration in [124, 126] {
            XCTAssertThrowsError(
                try JazzArchiveScreenshotEvidenceV1(
                    requestStartedAt: "2026-07-27T10:00:00.000Z",
                    frameCompletedAt: "2026-07-27T10:00:00.125Z",
                    monotonicDurationMillis: Int64(mismatchedDuration),
                    scope: scope
                ).validate())
        }
    }

    func testPortableProfileRejectsSubMillisecondTimestampPrecision() {
        XCTAssertThrowsError(
            try JazzArchiveScreenshotEvidenceV1(
                requestStartedAt: "2026-07-27T10:00:00.0000Z",
                frameCompletedAt: "2026-07-27T10:00:00.0015Z",
                monotonicDurationMillis: 2,
                scope: .window(
                    ownerBundleId: "com.example.app",
                    windowId: 17)
            ).validate())
    }

    func testPersistedScreenshotProfileBindsFrozenSessionPrivacyPolicy() throws {
        let valid = boundScreenshot()
        try valid.artifact.validate(
            manifest: valid.manifest,
            session: valid.session)

        var wrongPolicy = valid.artifact
        wrongPolicy.privacy.policyVersion = "other-consent"
        XCTAssertThrowsError(
            try wrongPolicy.validate(
                manifest: valid.manifest,
                session: valid.session))

        var missingModality = valid.session
        missingModality.capturePolicy.modalities = [.pointer]
        XCTAssertThrowsError(
            try valid.artifact.validate(
                manifest: valid.manifest,
                session: missingModality))

        var deniedPixels = valid.artifact
        deniedPixels.privacy.status = .denied
        XCTAssertThrowsError(
            try deniedPixels.validate(
                manifest: valid.manifest,
                session: valid.session))

        let foreignExclusion = boundScreenshot(
            exclusions: ["com.example.not-in-frozen-policy"])
        XCTAssertThrowsError(
            try foreignExclusion.artifact.validate(
                manifest: foreignExclusion.manifest,
                session: foreignExclusion.session))
    }

    func testCurrentScreenshotCannotDowngradeByDeletingProfile() throws {
        let valid = boundScreenshot()
        var missingProfile = valid.artifact
        missingProfile.extensions = nil

        XCTAssertThrowsError(
            try missingProfile.validate(
                manifest: valid.manifest,
                session: valid.session))

        // Historical inspection is a separate, source-version-pinned read-only mode. It is never
        // the default writer/import path.
        try missingProfile.validate(
            manifest: valid.manifest,
            session: valid.session,
            screenshotMode: .legacyReadOnly(
                allowedSourceProducerVersions: ["1"]))
        XCTAssertThrowsError(
            try missingProfile.validate(
                manifest: valid.manifest,
                session: valid.session,
                screenshotMode: .legacyReadOnly(
                    allowedSourceProducerVersions: ["different-version"])))

        var sourceLess = missingProfile
        sourceLess.sourceRefs = []
        XCTAssertThrowsError(
            try sourceLess.validate(
                manifest: valid.manifest,
                session: valid.session,
                screenshotMode: .legacyReadOnly(
                    allowedSourceProducerVersions: ["1"])))
    }

    func testLegacyReadOnlyScreenshotStillRequiresFrozenPolicyBinding() {
        let valid = boundScreenshot()
        var missingProfile = valid.artifact
        missingProfile.extensions = nil

        var wrongPolicy = missingProfile
        wrongPolicy.privacy.policyVersion = "other-consent"
        XCTAssertThrowsError(
            try wrongPolicy.validate(
                manifest: valid.manifest,
                session: valid.session,
                screenshotMode: .legacyReadOnly(
                    allowedSourceProducerVersions: ["1"])))

        var missingModality = valid.session
        missingModality.capturePolicy.modalities = [.pointer]
        XCTAssertThrowsError(
            try missingProfile.validate(
                manifest: valid.manifest,
                session: missingModality,
                screenshotMode: .legacyReadOnly(
                    allowedSourceProducerVersions: ["1"])))
    }
}
