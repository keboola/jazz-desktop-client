import Foundation
import XCTest

@testable import JasnostCaptureCore

final class JazzDogfoodQualificationTests: XCTestCase {
    func testProfileCoordinatesExactlyMatchIssueFourReleaseGate() {
        XCTAssertEqual(JazzDogfoodScenario.allCases.count, 33)
        XCTAssertEqual(
            JazzDogfoodScenario.allCases.map(\.rawValue),
            [
                "A01.completed_double_click",
                "A02.separated_single_clicks",
                "A03.completed_drag_select",
                "A04.focused_copy_cut",
                "A05.focused_paste",
                "A06.secure_destination",
                "A07.actual_owner_denylist",
                "A08.browser_document_context",
                "A09.local_file_context",
                "A10.capability_transitions",
                "A11.stop_during_inflight_work",
                "A12.offline_restart",
                "B01.label_baselines",
                "B02.recorded_answer_semantics",
                "B03.advisory_actions_relaunch",
                "B04.pending_prompt_focus_isolation",
                "C01.reject_never_queues",
                "C02.confirm_exact_bytes",
                "C03.retry_relaunch_exact_bytes",
                "C04.expired_offline_credential",
                "C05.signed_enrollment",
                "C06.single_use_enrollment_race",
                "C07.rotation_during_queued_delivery",
                "D01.direct_upload_ready",
                "D02.authorized_download_import",
                "D03.evidence_replay",
                "D04.guided_execution",
                "D05.expired_prepared_refresh",
                "D06.process_execution_handoff",
                "E01.live_archive_parity",
                "E02.live_mismatch_detection",
                "E03.archive_authority",
                "E04.live_disabled_completeness",
            ])
    }

    func testVersionOneEvidencePolicyExactlyCoversEveryScenario() {
        typealias Kind = JazzDogfoodEvidenceKind
        let expected: [JazzDogfoodScenario: Set<Kind>] = [
            .localCompletedDoubleClick:
                [.archiveSummary, .captureObservationSummary],
            .localSeparatedSingleClicks:
                [.archiveSummary, .captureObservationSummary],
            .localCompletedDragSelect:
                [.archiveSummary, .captureObservationSummary],
            .localFocusedCopyCut:
                [.archiveSummary, .captureObservationSummary],
            .localFocusedPaste:
                [.archiveSummary, .captureObservationSummary],
            .localSecureDestination:
                [.archiveSummary, .captureObservationSummary],
            .localActualOwnerDenylist:
                [.archiveSummary, .captureObservationSummary],
            .localBrowserDocumentContext:
                [.archiveSummary, .captureObservationSummary],
            .localFileContext:
                [.archiveSummary, .captureObservationSummary],
            .localCapabilityTransitions:
                [.archiveSummary, .capabilityTransitionSummary],
            .localStopDuringInflightWork:
                [.archiveSummary, .captureObservationSummary],
            .localOfflineRestart:
                [.archiveSummary, .playbackSummary],
            .coachLabelBaselines:
                [.archiveSummary, .coachInteractionSummary],
            .coachRecordedAnswerSemantics:
                [.archiveSummary, .coachInteractionSummary],
            .coachAdvisoryActionsRelaunch:
                [.archiveSummary, .coachInteractionSummary],
            .coachPendingPromptFocusIsolation:
                [
                    .archiveSummary,
                    .coachInteractionSummary,
                    .operatorAttestationSummary,
                ],
            .deliveryReject:
                [.archiveSummary, .deliveryReceiptSummary],
            .deliveryConfirmExactBytes:
                [.archiveSummary, .deliveryReceiptSummary],
            .deliveryRetryRelaunchExactBytes:
                [.archiveSummary, .deliveryReceiptSummary],
            .deliveryExpiredOfflineCredential:
                [.archiveSummary, .deliveryReceiptSummary],
            .enrollmentSignedBundle:
                [.buildAttestationSummary, .enrollmentReceiptSummary],
            .enrollmentSingleUseRace:
                [.enrollmentReceiptSummary, .serverStateReceiptSummary],
            .enrollmentRotationQueuedDelivery: [
                .archiveSummary,
                .deliveryReceiptSummary,
                .enrollmentReceiptSummary,
            ],
            .deployedDirectUploadReady: [
                .archiveSummary,
                .deliveryReceiptSummary,
                .serverStateReceiptSummary,
            ],
            .deployedAuthorizedDownloadImport: [
                .archiveSummary,
                .deliveryReceiptSummary,
                .importReceiptSummary,
                .serverStateReceiptSummary,
            ],
            .deployedEvidenceReplay: [
                .archiveSummary,
                .importReceiptSummary,
                .playbackSummary,
            ],
            .deployedGuidedExecution: [
                .archiveSummary,
                .executionReceiptSummary,
                .serverStateReceiptSummary,
            ],
            .deployedExpiredPreparedRefresh:
                [.executionReceiptSummary, .serverStateReceiptSummary],
            .deployedProcessExecutionHandoff:
                [
                    .executionReceiptSummary,
                    .operatorAttestationSummary,
                    .serverStateReceiptSummary,
                ],
            .liveParity:
                [.archiveSummary, .liveParitySummary],
            .liveMismatchDetection:
                [.liveParitySummary, .serverStateReceiptSummary],
            .liveArchiveAuthority: [
                .archiveSummary,
                .liveParitySummary,
                .serverStateReceiptSummary,
            ],
            .liveDisabledCompleteness: [
                .archiveSummary,
                .liveParitySummary,
                .playbackSummary,
            ],
        ]

        XCTAssertEqual(expected.count, JazzDogfoodScenario.allCases.count)
        for scenario in JazzDogfoodScenario.allCases {
            XCTAssertEqual(
                Set(scenario.requiredEvidenceKinds),
                expected[scenario],
                scenario.rawValue)
            XCTAssertFalse(scenario.requiredEvidenceKinds.isEmpty)
            XCTAssertEqual(
                Set(scenario.requiredEvidenceKinds).count,
                scenario.requiredEvidenceKinds.count)
        }
    }

    func testCanonicalEncodingIsIndependentOfCallerArrayOrder() throws {
        let receipts = try requiredEvidenceReceipts(
            scenario: .localCompletedDoubleClick)
        let evidenceIds = receipts.map(\.evidenceId)
        let forward = sampleBundle(
            evidence: receipts,
            results: results(
                outcome: .notRun,
                overrides: [
                    .localCompletedDoubleClick:
                        (.passed, evidenceIds)
                ]),
            reverseEnvironmentArrays: false)
        let reversed = sampleBundle(
            evidence: Array(receipts.reversed()),
            results: Array(results(
                outcome: .notRun,
                overrides: [
                    .localCompletedDoubleClick:
                        (.passed, Array(evidenceIds.reversed()))
                ]).reversed()),
            reverseEnvironmentArrays: true)
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())

        let first = try exporter.encodedBundle(forward)
        let second = try exporter.encodedBundle(reversed)

        XCTAssertEqual(first, second)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertFalse(text.contains("screenshot"))
        XCTAssertFalse(text.contains("clipboard"))
        XCTAssertFalse(text.contains("narration"))
        XCTAssertFalse(text.contains("user@example"))
        XCTAssertFalse(text.contains("\"path\""))
        XCTAssertFalse(text.contains("\"url\""))
    }

    func testEvidenceIdentityCoversMeasurementsAndCanonicalizesTheirOrder()
        throws
    {
        let first = try JazzDogfoodEvidenceReceipt(
            scenario: .localCompletedDoubleClick,
            kind: .captureObservationSummary,
            sourceSHA256: sha("a"),
            sourceByteLength: 4_096,
            capturedAt: "2026-07-27T10:00:01.000Z",
            measurements: [
                .init(name: "pointer.single_click_count", value: .integer(2)),
                .init(name: "pointer.double_click_count", value: .integer(1)),
            ])
        let reordered = try JazzDogfoodEvidenceReceipt(
            scenario: .localCompletedDoubleClick,
            kind: .captureObservationSummary,
            sourceSHA256: sha("a"),
            sourceByteLength: 4_096,
            capturedAt: "2026-07-27T10:00:01.000Z",
            measurements: [
                .init(name: "pointer.double_click_count", value: .integer(1)),
                .init(name: "pointer.single_click_count", value: .integer(2)),
            ])
        let changed = try JazzDogfoodEvidenceReceipt(
            scenario: .localCompletedDoubleClick,
            kind: .captureObservationSummary,
            sourceSHA256: sha("a"),
            sourceByteLength: 4_096,
            capturedAt: "2026-07-27T10:00:01.000Z",
            measurements: [
                .init(name: "pointer.double_click_count", value: .integer(1)),
                .init(name: "pointer.single_click_count", value: .integer(3)),
            ])

        XCTAssertEqual(first, reordered)
        XCTAssertNotEqual(first.evidenceId, changed.evidenceId)
        XCTAssertTrue(first.evidenceId.hasPrefix("dqe-sha256-"))
    }

    func testFullProfileAndEvidenceClosureFailClosed() throws {
        let receipt = try evidenceReceipt()
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())
        let missingScenario = sampleBundle(
            evidence: [],
            results: Array(results(outcome: .notRun).dropLast()))
        XCTAssertThrowsError(
            try exporter.encodedBundle(missingScenario)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .incompleteProfile)
        }

        let unsupportedPass = sampleBundle(
            evidence: [],
            results: results(
                outcome: .notRun,
                overrides: [.localCompletedDoubleClick: (.passed, [])]))
        XCTAssertThrowsError(
            try exporter.encodedBundle(unsupportedPass)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .missingEvidence(
                    JazzDogfoodScenario.localCompletedDoubleClick.rawValue))
        }

        let orphan = sampleBundle(
            evidence: [receipt],
            results: results(outcome: .notRun))
        XCTAssertThrowsError(
            try exporter.encodedBundle(orphan)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .orphanEvidence(receipt.evidenceId))
        }

        for outcome: JazzDogfoodScenarioOutcome in [.passed, .failed] {
            let wrongKind = sampleBundle(
                evidence: [receipt],
                results: results(
                    outcome: .notRun,
                    overrides: [
                        .localCompletedDoubleClick:
                            (outcome, [receipt.evidenceId])
                    ]))
            XCTAssertThrowsError(
                try exporter.encodedBundle(wrongKind)
            ) {
                XCTAssertEqual(
                    $0 as? JazzDogfoodQualificationError,
                    .missingEvidenceKind(
                        scenario:
                            JazzDogfoodScenario.localCompletedDoubleClick
                            .rawValue,
                        kind:
                            JazzDogfoodEvidenceKind.archiveSummary.rawValue))
            }
        }

        let wrongScenario = sampleBundle(
            evidence: [receipt],
            results: results(
                outcome: .notRun,
                overrides: [
                    .localSeparatedSingleClicks:
                        (.passed, [receipt.evidenceId])
                ]))
        XCTAssertThrowsError(
            try exporter.encodedBundle(wrongScenario)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .invalidField("result scenario evidence"))
        }
    }

    func testOverallOutcomeIsDerivedWithoutClaimingBlockedWorkPassed()
        throws
    {
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())
        let (receipts, passedResults) =
            try fullPassingEvidenceAndResults()
        let passed = sampleBundle(
            evidence: receipts,
            results: passedResults)
        let failed = sampleBundle(
            evidence: receipts,
            results: passedResults.map {
                JazzDogfoodScenarioResult(
                    scenario: $0.scenario,
                    outcome:
                        $0.scenario == .liveMismatchDetection
                        ? .failed : .passed,
                    evidenceIds: $0.evidenceIds)
            })
        let offlineReceipts = try requiredEvidenceReceipts(
            scenario: .localOfflineRestart)
        let blocked = sampleBundle(
            evidence: offlineReceipts,
            results: results(
                outcome: .notRun,
                overrides: [
                    .localOfflineRestart:
                        (.passed, offlineReceipts.map(\.evidenceId))
                ]))

        XCTAssertEqual(passed.overallOutcome, .passed)
        XCTAssertEqual(failed.overallOutcome, .failed)
        XCTAssertEqual(blocked.overallOutcome, .blocked)
        XCTAssertNoThrow(try exporter.encodedBundle(passed))
        XCTAssertNoThrow(try exporter.encodedBundle(failed))
        XCTAssertNoThrow(try exporter.encodedBundle(blocked))
    }

    func testTerminalProfileRequiresTwoDevicesTwoOperatorsAndProviderVersions()
        throws
    {
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())
        let (receipts, passedResults) =
            try fullPassingEvidenceAndResults()
        let failedResults = passedResults.map {
            JazzDogfoodScenarioResult(
                scenario: $0.scenario,
                outcome:
                    $0.scenario == .liveMismatchDetection
                    ? .failed : .passed,
                evidenceIds: $0.evidenceIds)
        }
        let oneDevice = [sha("4")]
        let oneOperator = [sha("8")]
        let provider = [
            JazzDogfoodProviderVersion(
                provider: "postgresql", version: "16.9")
        ]

        for terminalResults in [passedResults, failedResults] {
            let incompleteEnvironments = [
                sampleBundle(
                    evidence: receipts,
                    results: terminalResults,
                    deviceIdentitySHA256s: oneDevice),
                sampleBundle(
                    evidence: receipts,
                    results: terminalResults,
                    operatorIdentitySHA256s: oneOperator),
                sampleBundle(
                    evidence: receipts,
                    results: terminalResults,
                    providers: []),
            ]

            for bundle in incompleteEnvironments {
                XCTAssertTrue(
                    bundle.overallOutcome == .passed
                        || bundle.overallOutcome == .failed)
                XCTAssertThrowsError(
                    try exporter.encodedBundle(bundle)
                ) {
                    XCTAssertEqual(
                        $0 as? JazzDogfoodQualificationError,
                        .invalidField(
                            "terminal profile environment coverage"))
                }
            }
        }

        let complete = sampleBundle(
            evidence: receipts,
            results: passedResults,
            providers: provider)
        XCTAssertNoThrow(try exporter.encodedBundle(complete))

        let partial = sampleBundle(
            evidence: [],
            results: results(outcome: .notRun),
            deviceIdentitySHA256s: oneDevice,
            operatorIdentitySHA256s: oneOperator,
            providers: [])
        XCTAssertEqual(partial.overallOutcome, .blocked)
        XCTAssertNoThrow(try exporter.encodedBundle(partial))
    }

    func testPrivacyAndResourceBoundsRejectFreeTextAndUnsafeNumbers() {
        XCTAssertThrowsError(
            try JazzDogfoodEvidenceReceipt(
                scenario: .localCompletedDoubleClick,
                kind: .operatorAttestationSummary,
                sourceSHA256: sha("a"),
                sourceByteLength: 1,
                capturedAt: "2026-07-27T10:00:00.000Z",
                measurements: [
                    .init(
                        name: "operator said this contains free text",
                        value: .boolean(true))
                ]))
        XCTAssertThrowsError(
            try JazzDogfoodEvidenceReceipt(
                scenario: .localCompletedDoubleClick,
                kind: .archiveSummary,
                sourceSHA256: sha("A"),
                sourceByteLength: 1,
                capturedAt: "2026-07-27T10:00:00.000Z",
                measurements: []))
        XCTAssertThrowsError(
            try JazzDogfoodEvidenceReceipt(
                scenario: .localCompletedDoubleClick,
                kind: .archiveSummary,
                sourceSHA256: sha("a"),
                sourceByteLength: 1,
                capturedAt: "2026-07-27T10:00:00.000Z",
                measurements: [
                    .init(
                        name: "archive.record_count",
                        value: .integer(9_007_199_254_740_992))
                ]))
        XCTAssertThrowsError(
            try JazzDogfoodEvidenceReceipt(
                scenario: .localCompletedDoubleClick,
                kind: .archiveSummary,
                sourceSHA256: sha("a"),
                sourceByteLength: 1,
                capturedAt: "2026-07-27T10:00:00.000Z",
                measurements: (0...64).map {
                    .init(
                        name: "archive.measurement_\($0)",
                        value: .integer(Int64($0)))
                }))
    }

    func testReferencedEvidenceMustBeCapturedInsideRunInterval() throws {
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())
        for capturedAt in [
            "2026-07-27T09:59:59.999Z",
            "2026-07-27T10:05:00.001Z",
        ] {
            let receipt = try evidenceReceipt(
                scenario: .deliveryReject,
                kind: .deliveryReceiptSummary,
                capturedAt: capturedAt)
            let bundle = sampleBundle(
                evidence: [receipt],
                results: results(
                    outcome: .notRun,
                    overrides: [
                        .deliveryReject:
                            (.blocked, [receipt.evidenceId])
                    ]))

            XCTAssertThrowsError(
                try exporter.encodedBundle(bundle)
            ) {
                XCTAssertEqual(
                    $0 as? JazzDogfoodQualificationError,
                    .invalidField(
                        "evidence.capturedAt outside qualification interval"))
            }
        }
    }

    func testExportIsDurableIdempotentAndNeverOverwritesConflict()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-dogfood-qualification-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(
            "qualification.json")
        let receipts = try requiredEvidenceReceipts(
            scenario: .localCompletedDoubleClick)
        let bundle = sampleBundle(
            evidence: receipts,
            results: results(
                outcome: .notRun,
                overrides: [
                    .localCompletedDoubleClick:
                        (.passed, receipts.map(\.evidenceId))
                ]))
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())

        let first = try exporter.export(bundle, to: destination)
        let firstBytes = try Data(contentsOf: destination)
        let second = try exporter.export(bundle, to: destination)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.fingerprint.sha256,
            JazzArchiveDigest.sha256Hex(firstBytes))
        XCTAssertEqual(first.fingerprint.byteLength, Int64(firstBytes.count))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[
                .posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let conflicting = sampleBundle(
            completedAt: "2026-07-27T10:06:00.000Z",
            evidence: receipts,
            results: results(
                outcome: .notRun,
                overrides: [
                    .localCompletedDoubleClick:
                        (.passed, receipts.map(\.evidenceId))
                ]))
        XCTAssertThrowsError(
            try exporter.export(conflicting, to: destination)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .exportConflict)
        }
        XCTAssertEqual(try Data(contentsOf: destination), firstBytes)
    }

    func testExportRejectsSymlinkDestinationAndHonorsByteLimit()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-dogfood-qualification-symlink-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.json")
        try Data("existing".utf8).write(to: target)
        let symlink = root.appendingPathComponent("qualification.json")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: target)
        let bundle = sampleBundle(evidence: [], results: results(outcome: .notRun))
        let exporter = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability())

        XCTAssertThrowsError(
            try exporter.export(bundle, to: symlink)
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .unsafeDestination)
        }
        let bounded = JazzDogfoodQualificationExporter(
            durability: foundationTestFilesystemDurability(),
            maximumBundleBytes: 1)
        XCTAssertThrowsError(
            try bounded.encodedBundle(bundle)
        ) {
            guard case .bundleTooLarge? =
                $0 as? JazzDogfoodQualificationError
            else {
                return XCTFail("unexpected error: \($0)")
            }
        }
    }

    func testGeneratedRunIdsAndEnvironmentIdentitySetsFailClosed()
        throws
    {
        let runId = JazzDogfoodQualificationBundle.newRunId()
        let raw = String(runId.dropFirst("qrun-".count))
        XCTAssertEqual(Array(raw)[14], "7")
        XCTAssertTrue("89ab".contains(Array(raw)[19]))

        let invalid = JazzDogfoodQualificationEnvironment(
            desktopCommit: String(repeating: "1", count: 40),
            serverCommit: String(repeating: "2", count: 40),
            appBundleId: "com.keboola.jazz",
            appVersion: "1.0.0",
            appBuild: "42",
            codeIdentitySHA256: sha("3"),
            serverBuildIdentitySHA256: sha("7"),
            macOSVersion: "15.5",
            deviceIdentitySHA256s: [sha("4")],
            operatorIdentitySHA256s: [],
            providers: [])
        let bundle = JazzDogfoodQualificationBundle(
            qualificationRunId: fixedRunId,
            startedAt: "2026-07-27T10:00:00.000Z",
            completedAt: "2026-07-27T10:05:00.000Z",
            environment: invalid,
            archives: [archiveAnchor],
            evidence: [],
            results: results(outcome: .notRun))

        XCTAssertThrowsError(try bundle.validate())

        let duplicateDeviceEnvironment = JazzDogfoodQualificationEnvironment(
            desktopCommit: String(repeating: "1", count: 40),
            serverCommit: String(repeating: "2", count: 40),
            appBundleId: "com.keboola.jazz",
            appVersion: "1.0.0",
            appBuild: "42",
            codeIdentitySHA256: sha("3"),
            serverBuildIdentitySHA256: sha("7"),
            macOSVersion: "15.5",
            deviceIdentitySHA256s: [sha("4"), sha("4")],
            operatorIdentitySHA256s: [sha("8")],
            providers: [])
        let duplicateDeviceBundle = JazzDogfoodQualificationBundle(
            qualificationRunId: fixedRunId,
            startedAt: "2026-07-27T10:00:00.000Z",
            completedAt: "2026-07-27T10:05:00.000Z",
            environment: duplicateDeviceEnvironment,
            archives: [archiveAnchor],
            evidence: [],
            results: results(outcome: .notRun))
        XCTAssertThrowsError(
            try duplicateDeviceBundle.validate()
        ) {
            XCTAssertEqual(
                $0 as? JazzDogfoodQualificationError,
                .duplicate("device identity"))
        }
    }

    private let fixedRunId =
        "qrun-01900000-0000-7000-8000-000000000001"

    private var archiveAnchor: JazzDogfoodArchiveAnchor {
        JazzDogfoodArchiveAnchor(
            archiveId: "ar-01900000-0000-7000-8000-000000000002",
            contentDigest: sha("5"),
            packageSHA256: sha("6"),
            packageByteLength: 25_072)
    }

    private func evidenceReceipt(
        scenario: JazzDogfoodScenario = .localCompletedDoubleClick,
        kind: JazzDogfoodEvidenceKind = .captureObservationSummary,
        capturedAt: String = "2026-07-27T10:00:01.000Z"
    ) throws -> JazzDogfoodEvidenceReceipt {
        try JazzDogfoodEvidenceReceipt(
            scenario: scenario,
            kind: kind,
            sourceSHA256: sha("a"),
            sourceByteLength: 512,
            capturedAt: capturedAt,
            measurements: [
                .init(name: "pointer.click_count", value: .integer(1)),
                .init(name: "pointer.has_gesture_id", value: .boolean(true)),
                .init(name: "pointer.source_digest", value: .sha256(sha("b"))),
            ])
    }

    private func requiredEvidenceReceipts(
        scenario: JazzDogfoodScenario
    ) throws -> [JazzDogfoodEvidenceReceipt] {
        try scenario.requiredEvidenceKinds.map {
            try evidenceReceipt(scenario: scenario, kind: $0)
        }
    }

    private func fullPassingEvidenceAndResults() throws
        -> ([JazzDogfoodEvidenceReceipt], [JazzDogfoodScenarioResult])
    {
        let receipts = try JazzDogfoodScenario.allCases.flatMap {
            try requiredEvidenceReceipts(scenario: $0)
        }
        let receiptIdsByScenario = Dictionary(
            grouping: receipts, by: \.scenario)
            .mapValues { $0.map(\.evidenceId) }
        let results = JazzDogfoodScenario.allCases.map {
            JazzDogfoodScenarioResult(
                scenario: $0,
                outcome: .passed,
                evidenceIds: receiptIdsByScenario[$0]!)
        }
        return (receipts, results)
    }

    private func sampleBundle(
        completedAt: String = "2026-07-27T10:05:00.000Z",
        evidence: [JazzDogfoodEvidenceReceipt],
        results: [JazzDogfoodScenarioResult],
        reverseEnvironmentArrays: Bool = false,
        deviceIdentitySHA256s: [String]? = nil,
        operatorIdentitySHA256s: [String]? = nil,
        providers: [JazzDogfoodProviderVersion]? = nil
    ) -> JazzDogfoodQualificationBundle {
        let devices = deviceIdentitySHA256s ?? [sha("4"), sha("c")]
        let operators = operatorIdentitySHA256s ?? [sha("8"), sha("9")]
        let providerValues = providers ?? [
            JazzDogfoodProviderVersion(
                provider: "google-cloud-storage", version: "v1"),
            JazzDogfoodProviderVersion(
                provider: "postgresql", version: "16.9"),
        ]
        return JazzDogfoodQualificationBundle(
            qualificationRunId: fixedRunId,
            startedAt: "2026-07-27T10:00:00.000Z",
            completedAt: completedAt,
            environment: JazzDogfoodQualificationEnvironment(
                desktopCommit: String(repeating: "1", count: 40),
                serverCommit: String(repeating: "2", count: 40),
                appBundleId: "com.keboola.jazz",
                appVersion: "1.0.0",
                appBuild: "42",
                codeIdentitySHA256: sha("3"),
                serverBuildIdentitySHA256: sha("7"),
                macOSVersion: "15.5",
                deviceIdentitySHA256s:
                    reverseEnvironmentArrays
                    ? Array(devices.reversed()) : devices,
                operatorIdentitySHA256s:
                    reverseEnvironmentArrays
                    ? Array(operators.reversed()) : operators,
                providers:
                    reverseEnvironmentArrays
                    ? Array(providerValues.reversed()) : providerValues),
            archives: [archiveAnchor],
            evidence: evidence,
            results: Array(results))
    }

    private func results(
        outcome: JazzDogfoodScenarioOutcome,
        overrides:
            [JazzDogfoodScenario:
                (JazzDogfoodScenarioOutcome, [String])] = [:],
        evidenceIds: [String] = []
    ) -> [JazzDogfoodScenarioResult] {
        JazzDogfoodScenario.allCases.map { scenario in
            let value = overrides[scenario] ?? (outcome, evidenceIds)
            return JazzDogfoodScenarioResult(
                scenario: scenario,
                outcome: value.0,
                evidenceIds: value.1)
        }
    }

    private func sha(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}
