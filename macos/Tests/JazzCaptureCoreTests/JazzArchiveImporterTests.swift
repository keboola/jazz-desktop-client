import Foundation
import ImageIO
import XCTest

@testable import JazzCaptureCore

final class JazzArchiveImporterTests: XCTestCase {
    private let startedAt = "2026-07-23T10:00:00.000Z"

    func testExportImportIndexAndPlaybackRoundTripUsesImmutableCompactSnapshot() async throws {
        let sourceRoot = temporaryRoot("source")
        let importedRoot = temporaryRoot("imported")
        let spoolRoot = temporaryRoot("spool")
        defer {
            removeTemporaryTree(sourceRoot)
            removeTemporaryTree(importedRoot)
            removeTemporaryTree(spoolRoot)
        }
        try FileManager.default.createDirectory(
            at: spoolRoot, withIntermediateDirectories: true)
        let fixture = try await makePortablePackage(root: sourceRoot)
        let sourceBytes = try Data(contentsOf: fixture.packageURL)
        let importer = JazzArchiveImporter(root: importedRoot)
        let firstContext = JazzArchiveImportContext(
            importedBy: JazzArchiveExternalIdentity(
                namespace: "user.email", value: "alice@example.com"),
            importingOriginId: Identifiers.newOriginId(),
            importingSourceId: Identifiers.newSourceId(),
            importingDevice: JazzArchiveExternalIdentity(
                namespace: "macos.device-name", value: "Alice Mac"))

        let first = try await importer.importArchive(
            at: fixture.packageURL,
            importedAt: "2026-07-23T11:00:00.000Z",
            context: firstContext)

        XCTAssertEqual(first.disposition, .imported)
        XCTAssertEqual(first.snapshot.manifest.archiveId, fixture.archiveId)
        XCTAssertEqual(first.snapshot.manifest.actors.first?.displayName, "Recorder")
        XCTAssertNotEqual(
            first.snapshot.manifest.actors.first?.displayName,
            firstContext.importedBy?.value)
        XCTAssertEqual(first.provenance.archiveId, fixture.archiveId)
        XCTAssertEqual(
            first.provenance.packageId,
            JazzArchivePackageProvenance.packageId(
                sha256: JazzArchiveDigest.sha256Hex(sourceBytes)))
        XCTAssertEqual(first.provenance.packageByteLength, Int64(sourceBytes.count))
        XCTAssertEqual(first.provenance.receipts.count, 1)
        XCTAssertEqual(first.provenance.importedBy, firstContext.importedBy)
        XCTAssertEqual(
            first.provenance.importingOriginId,
            firstContext.importingOriginId)
        XCTAssertEqual(
            first.provenance.importingSourceId,
            firstContext.importingSourceId)
        XCTAssertEqual(
            first.provenance.importingDevice,
            firstContext.importingDevice)
        XCTAssertEqual(first.provenance.acquisition, .userSelectedFile)
        XCTAssertEqual(try Data(contentsOf: first.packageURL), sourceBytes)
        XCTAssertTrue(
            first.snapshot.inventory.entries.contains {
            $0.path.hasSuffix("/records.ndjson")
        })
        XCTAssertFalse(
            first.snapshot.inventory.entries.contains {
            $0.path.contains("/records/")
        })
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    importedRoot
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    importedRoot
            .appendingPathComponent(
                        "\(fixture.archiveId).jazz-archive.finalized", isDirectory: true
                    ).path))

        let index = JazzArchiveLocalIndex(
            root: importedRoot,
            eventSpool: EventSpool(root: spoolRoot))
        let summaries = await index.sessions()
        let summary = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summary.archiveId, fixture.archiveId)
        XCTAssertEqual(summary.captureId, fixture.captureId)
        XCTAssertEqual(summary.user, "Recorder")
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.artifactCount, 1)
        XCTAssertTrue(summary.isFinalized)
        XCTAssertTrue(summary.isCommitted)
        XCTAssertFalse(summary.hasWorkingDraft)
        XCTAssertEqual(summary.sentCount, 0)
        XCTAssertEqual(summary.pendingCount, 0)

        let playback = try await JazzArchiveEvidencePlaybackBuilder(
            root: importedRoot
        ).build(
                archiveId: fixture.archiveId,
                captureId: fixture.captureId)
        XCTAssertEqual(playback.entries.map(\.item.kind), [.screenshot, .gap, .event])
        let screenshot = try XCTUnwrap(playback.entries.first?.artifact)
        XCTAssertEqual(screenshot.artifactId, fixture.artifactId)
        XCTAssertTrue(screenshot.url.path.contains(".jazz-archive.finalized/"))
        XCTAssertEqual(
            try Data(contentsOf: screenshot.url),
            fixture.artifactBytes)

        let secondContext = JazzArchiveImportContext(
            importedBy: JazzArchiveExternalIdentity(
                namespace: "user.email", value: "bob@example.com"),
            importingOriginId: Identifiers.newOriginId(),
            importingSourceId: Identifiers.newSourceId(),
            importingDevice: JazzArchiveExternalIdentity(
                namespace: "macos.device-name", value: "Bob Mac"),
            acquisition: .jazzServerDownload,
            downloadOperationId: Identifiers.newDownloadOperationId(),
            downloadAuthorizationId: "download-auth-existing-package")
        let second = try await importer.importArchive(
            at: fixture.packageURL,
            importedAt: "2099-01-01T00:00:00.000Z",
            context: secondContext)
        XCTAssertEqual(second.disposition, .alreadyPresent)
        XCTAssertEqual(second.provenance.receipts.count, 2)
        XCTAssertEqual(second.provenance.receipts.first, first.provenance.receipts.first)
        XCTAssertEqual(second.provenance.importedBy, firstContext.importedBy)
        XCTAssertEqual(second.provenance.receipts.last?.importedBy, secondContext.importedBy)
        XCTAssertEqual(second.provenance.receipts.last?.acquisition, .jazzServerDownload)
        XCTAssertEqual(
            second.provenance.receipts.last?.importingOriginId,
            secondContext.importingOriginId)
        XCTAssertEqual(second.snapshot.manifest.actors.first?.displayName, "Recorder")
        let persisted = try await importer.provenance(archiveId: fixture.archiveId)
        XCTAssertEqual(persisted, second.provenance)
    }

    func testDifferentValidPackageWithSameArchiveIdIsConflict() async throws {
        let firstRoot = temporaryRoot("collision-a")
        let secondRoot = temporaryRoot("collision-b")
        let importedRoot = temporaryRoot("collision-import")
        defer {
            removeTemporaryTree(firstRoot)
            removeTemporaryTree(secondRoot)
            removeTemporaryTree(importedRoot)
        }
        let archiveId = Identifiers.newArchiveId()
        let first = try await makePortablePackage(
            root: firstRoot, archiveId: archiveId, finalEventType: .navigate)
        let second = try await makePortablePackage(
            root: secondRoot, archiveId: archiveId, finalEventType: .paste)
        let importer = JazzArchiveImporter(root: importedRoot)
        _ = try await importer.importArchive(at: first.packageURL)

        do {
            _ = try await importer.importArchive(at: second.packageURL)
            XCTFail("different canonical bytes must not reuse an archive identity")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveImportError,
                .archiveConflict(archiveId))
        }
        let storedProvenance = try await importer.provenance(archiveId: archiveId)
        let persisted = try XCTUnwrap(storedProvenance)
        XCTAssertEqual(
            persisted.packageFingerprint,
            try JazzArchiveFileIO.fingerprint(first.packageURL))
        XCTAssertNotEqual(
            persisted.packageFingerprint,
            try JazzArchiveFileIO.fingerprint(second.packageURL))
    }

    func testRejectsTraversalDuplicateCaseAliasUnicodeAliasAndSymlinkEntries() async throws {
        let cases: [(String, [TestZIPEntry], ExpectedRejection)] = [
            (
                "traversal",
                standardEntries(extra: [
                    TestZIPEntry(name: "../escape.json", data: Data("{}".utf8))
                ]),
                .unsafe
            ),
            (
                "exact duplicate",
                standardEntries(extra: [
                    TestZIPEntry(name: "same.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "same.json", data: Data("{}".utf8)),
                ]),
                .duplicate
            ),
            (
                "case alias",
                standardEntries(extra: [
                    TestZIPEntry(name: "A.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "a.json", data: Data("{}".utf8)),
                ]),
                .duplicate
            ),
            (
                "NFC alias",
                standardEntries(extra: [
                    TestZIPEntry(name: "café.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "cafe\u{301}.json", data: Data("{}".utf8)),
                ]),
                .unsafe
            ),
            (
                "symlink",
                standardEntries(extra: [
                    TestZIPEntry(
                        name: "link.json",
                        data: Data("target".utf8),
                        externalAttributes: UInt32(0o120777 << 16))
                ]),
                .unsupported
            ),
        ]

        for (name, entries, expected) in cases {
            let root = temporaryRoot("malicious-\(name)")
            defer { removeTemporaryTree(root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let package = root.appendingPathComponent("attack.jazz-archive")
            try makeStoredZIP(entries).write(to: package)
            do {
                _ = try await JazzArchiveImporter(
                    root: root.appendingPathComponent("library")
                ).importArchive(at: package)
                XCTFail("\(name) package must be rejected")
            } catch let error as JazzArchiveImportError {
                switch (expected, error) {
                case (.unsafe, .unsafeEntry),
                    (.duplicate, .duplicateEntry),
                    (.unsupported, .unsupportedZIPFeature):
                    break
                default:
                    XCTFail("\(name) returned unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsCompressionBecausePortableContractIsDeterministicStoredZIP32() async throws {
        let root = temporaryRoot("compressed")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("compressed.jazz-archive")
        try makeStoredZIP(standardEntries(), method: 8).write(to: package)

        do {
            _ = try await JazzArchiveImporter(
                root: root.appendingPathComponent("library")
            ).importArchive(at: package)
            XCTFail("even otherwise-valid ZIP32 compression is outside the portable profile")
        } catch let error as JazzArchiveImportError {
            guard case .unsupportedZIPFeature = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testRejectsEncryptionDataDescriptorsExtrasCommentsAndZIP64() async throws {
        let base = makeStoredZIP(standardEntries())
        let eocdOffset = base.count - 22
        let centralOffset = Int(base.testU32(eocdOffset + 16))
        var encrypted = base
        encrypted.setTestU16(centralOffset + 8, 0x0801)
        var dataDescriptor = base
        dataDescriptor.setTestU16(centralOffset + 8, 0x0808)
        var extra = base
        extra.setTestU16(centralOffset + 30, 1)
        var comment = base
        comment.setTestU16(centralOffset + 32, 1)
        var zip64 = base
        zip64.setTestU32(eocdOffset + 16, UInt32.max)
        let cases = [
            ("encryption", encrypted),
            ("data descriptor", dataDescriptor),
            ("extra field", extra),
            ("entry comment", comment),
            ("ZIP64", zip64),
        ]

        for (name, bytes) in cases {
            let root = temporaryRoot("profile-\(name)")
            defer { removeTemporaryTree(root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let package = root.appendingPathComponent("unsupported.jazz-archive")
            try bytes.write(to: package)
            do {
                _ = try await JazzArchiveImporter(
                    root: root.appendingPathComponent("library")
                ).importArchive(at: package)
                XCTFail("\(name) is outside the deterministic portable profile")
            } catch let error as JazzArchiveImportError {
                guard case .unsupportedZIPFeature = error else {
                    return XCTFail("\(name) returned unexpected error: \(error)")
                }
            }
        }
    }

    func testRejectsTruncatedAndCRCTamperedValidExportsWithoutPublishing() async throws {
        let sourceRoot = temporaryRoot("tamper-source")
        let importedRoot = temporaryRoot("tamper-import")
        defer {
            removeTemporaryTree(sourceRoot)
            removeTemporaryTree(importedRoot)
        }
        let fixture = try await makePortablePackage(root: sourceRoot)
        let original = try Data(contentsOf: fixture.packageURL)
        let truncated = sourceRoot.appendingPathComponent("truncated.jazz-archive")
        try Data(original.dropLast()).write(to: truncated)

        var tampered = original
        let firstNameLength = Int(tampered.testU16(26))
        let firstSize = Int(tampered.testU32(18))
        XCTAssertGreaterThan(firstSize, 0)
        let firstPayload = 30 + firstNameLength
        tampered[firstPayload] ^= 0xff
        let crcBroken = sourceRoot.appendingPathComponent("crc-broken.jazz-archive")
        try tampered.write(to: crcBroken)

        for package in [truncated, crcBroken] {
            do {
                _ = try await JazzArchiveImporter(root: importedRoot).importArchive(at: package)
                XCTFail("\(package.lastPathComponent) must fail closed")
            } catch let error as JazzArchiveImportError {
                switch error {
                case .malformedZIP, .integrityMismatch:
                    break
                default:
                    XCTFail("unexpected tamper error: \(error)")
                }
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    importedRoot
            .appendingPathComponent(
                        "\(fixture.archiveId).jazz-archive.finalized", isDirectory: true
                    ).path))
    }

    func testRejectsEntryCountBeforeExtraction() async throws {
        let root = temporaryRoot("limit")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("too-many.jazz-archive")
        try makeStoredZIP(
            standardEntries(extra: [
            TestZIPEntry(name: "third.json", data: Data("{}".utf8))
            ])
        ).write(to: package)
        let limits = JazzArchiveImportLimits(maxEntries: 2)

        do {
            _ = try await JazzArchiveImporter(
                root: root.appendingPathComponent("library"),
                limits: limits
            ).importArchive(at: package)
            XCTFail("entry limit must fail before extraction")
        } catch let error as JazzArchiveImportError {
            XCTAssertEqual(error, .entryLimitExceeded("entry count"))
        }
    }

    func testDefaultLimitsMatchPublishedServerIngestEnvelope() {
        let limits = JazzArchiveImportLimits()
        XCTAssertEqual(limits.maxArchiveBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(limits.maxEntries, 10_000)
        XCTAssertEqual(limits.maxEntryBytes, 512 * 1024 * 1024)
        XCTAssertEqual(limits.maxTotalExpandedBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(limits.maxTotalStructuredBytes, 256 * 1024 * 1024)
        XCTAssertEqual(limits.maxJSONEntryBytes, 32 * 1024 * 1024)
        XCTAssertEqual(limits.maxNDJSONLineBytes, 4 * 1024 * 1024)
        XCTAssertEqual(limits.maxNDJSONRecords, 250_000)
        XCTAssertEqual(limits.maxPathBytes, 1024)
    }

    func testImportsCanonicalLabeledNarrationFixtureWithoutRewritingEvidence() async throws {
        let importedRoot = temporaryRoot("canonical-fixture")
        defer { removeTemporaryTree(importedRoot) }
        try FileManager.default.createDirectory(
            at: importedRoot, withIntermediateDirectories: true)

        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let packageBytes = try Data(contentsOf: packageURL)

        let libraryRoot = importedRoot.appendingPathComponent(
            "library", isDirectory: true)
        let context = JazzArchiveImportContext(
            importedBy: JazzArchiveExternalIdentity(
                namespace: "user.email", value: "reviewer@example.com"),
            importingOriginId: Identifiers.newOriginId(),
            importingSourceId: Identifiers.newSourceId())
        let result = try await JazzArchiveImporter(root: libraryRoot).importArchive(
            at: packageURL,
            importedAt: "2026-07-23T12:00:00.000Z",
            context: context)

        let archiveId = "ar-22222222-2222-7222-8222-222222222222"
        let captureId = "cap-22222222-2222-7222-8222-222222222222"
        let artifactId = "art-22222222-2222-7222-8222-222222222222"
        XCTAssertEqual(result.snapshot.manifest.archiveId, archiveId)
        XCTAssertEqual(
            result.snapshot.manifest.actors.first?.displayName,
            "Recorder and narrator")
        XCTAssertEqual(try result.snapshot.records(captureId: captureId).count, 7)
        XCTAssertEqual(try result.snapshot.labels(captureId: captureId).count, 1)
        XCTAssertEqual(try result.snapshot.artifacts(captureId: captureId).count, 1)
        let commit = try result.snapshot.captureCommit(captureId: captureId)
        XCTAssertEqual(commit.streamSummaries.first?.firstSequence, 0)
        XCTAssertEqual(commit.streamSummaries.first?.lastSequence, 7)
        XCTAssertEqual(commit.streamSummaries.first?.observationCount, 7)
        XCTAssertEqual(
            commit.gaps,
            [
                JazzArchiveSequenceGap(
                    streamId: "stream-22222222-2222-7222-8222-222222222222",
                    firstSequence: 7,
                    lastSequence: 7,
                    reason: .sourceUnavailable,
                    detail: "The source stopped after reserving the final sequence.")
            ])
        XCTAssertEqual(result.snapshot.assertions.count, 1)
        XCTAssertEqual(result.provenance.importedBy, context.importedBy)
        XCTAssertEqual(try Data(contentsOf: result.packageURL), packageBytes)

        let reexportedURL = importedRoot.appendingPathComponent(
            "desktop-reexport.jazz-archive")
        _ = try await JazzArchiveFinalizer(root: libraryRoot).export(
            JazzArchiveFinalizedPackage(
                url: result.snapshot.directoryURL,
                manifest: result.snapshot.manifest,
                inventory: result.snapshot.inventory),
            to: reexportedURL)
        XCTAssertEqual(try Data(contentsOf: reexportedURL), packageBytes)

        let artifact = try await JazzArchiveFinalizedStore(root: libraryRoot).artifactFile(
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId)
        XCTAssertEqual(try Data(contentsOf: artifact.url), Data("abc\n".utf8))

        let playback = try await JazzArchiveEvidencePlaybackBuilder(
            root: libraryRoot
        ).build(
                archiveId: archiveId,
                captureId: captureId)
        XCTAssertEqual(playback.captureId, captureId)
        XCTAssertTrue(
            playback.entries.contains {
            $0.artifact?.artifactId == artifactId
        })

        let spoolRoot = importedRoot.appendingPathComponent(
            "event-spool", isDirectory: true)
        try FileManager.default.createDirectory(
            at: spoolRoot, withIntermediateDirectories: true)
        let summaries = await JazzArchiveLocalIndex(
            root: libraryRoot,
            eventSpool: EventSpool(root: spoolRoot)
        ).sessions()
        XCTAssertTrue(
            summaries.first?.labels.contains(
            "Book the monthly orders") == true)
        XCTAssertEqual(summaries.first?.areaId, "finance")
        XCTAssertEqual(summaries.first?.processIds, ["monthly-booking"])
    }

    func testAuthorizedReadyServerDownloadSealsVerifiesAndImportsExactPackage() async throws {
        let root = temporaryRoot("server-download")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-1",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count),
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-1",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
            ])
        let transport = FakeArchiveServerDownloadTransport(
            grant: grant, bytes: bytes, chunkSize: 733)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let context = JazzArchiveImportContext(
            importedBy: JazzArchiveExternalIdentity(
                namespace: "user.email", value: "mallory@local.invalid"),
            importingOriginId: Identifiers.newOriginId(),
            importingSourceId: Identifiers.newSourceId(),
            importingDevice: JazzArchiveExternalIdentity(
                namespace: "macos.device-name", value: "Untrusted Local Name"))
        let result = try await JazzArchiveServerImportCoordinator(
            root: root,
            importer: JazzArchiveImporter(root: library),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).importReadyArchive(
            request,
            importedAt: "2026-07-23T12:00:00Z",
            context: context)

        XCTAssertEqual(result.snapshot.manifest.archiveId, grant.archiveId)
        XCTAssertEqual(result.snapshot.manifest.actors.first?.displayName, "Recorder and narrator")
        let receipt = try XCTUnwrap(result.provenance.receipts.last)
        XCTAssertEqual(receipt.acquisition, .jazzServerDownload)
        XCTAssertEqual(
            receipt.importedBy,
            JazzArchiveExternalIdentity(
                namespace: "jazz.authenticated-principal-id",
                value: grant.requestedBy.principalId))
        XCTAssertEqual(
            receipt.importingDevice,
            JazzArchiveExternalIdentity(
                namespace: "jazz.enrolled-device-id",
                value: grant.requestedBy.deviceId))
        XCTAssertNotEqual(receipt.importedBy, context.importedBy)
        XCTAssertNotEqual(receipt.importingDevice, context.importingDevice)
        XCTAssertEqual(receipt.importingOriginId, context.importingOriginId)
        XCTAssertEqual(receipt.importingSourceId, context.importingSourceId)
        XCTAssertEqual(receipt.downloadOperationId, request.downloadOperationId)
        XCTAssertEqual(
            receipt.downloadAuthorizationId,
            grant.downloadAuthorizationId)
        XCTAssertEqual(try Data(contentsOf: result.packageURL), bytes)
        let authorizationCalls = await transport.authorizationCalls()
        let bodyCalls = await transport.bodyCalls()
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(bodyCalls, 1)
    }

    func testServerDownloadJournalSurvivesImporterDirectorySyncFailureAndRelaunch()
        async throws
    {
        let root = temporaryRoot("server-download-import-durability")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true)
        let downloadRoot = root.appendingPathComponent(
            "downloads",
            isDirectory: true)
        let scope = JazzArchiveServerScope(
            companyId: "acme",
            areaId: "finance",
            deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-import-durability",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count),
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-import-durability",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/import-durability"),
            ])
        let controlledDurability = ControllableFilesystemDurability()
        let finalized = library.appendingPathComponent(
            "\(grant.archiveId).jazz-archive.finalized",
            isDirectory: true)
        controlledDurability.armDirectory(finalized)
        let firstTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: bytes,
            chunkSize: 733)

        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: downloadRoot,
                importer: JazzArchiveImporter(
                    root: library,
                    durability: controlledDurability.value()),
                transport: firstTransport
            ).importReadyArchive(
                request,
                importedAt: "2026-07-24T09:00:00Z",
                context: JazzArchiveImportContext())
            XCTFail("download journal completed before the imported tree was durable")
        } catch let importError as JazzArchiveImportError {
            guard case .publishFailed = importError else {
                return XCTFail("unexpected importer error: \(importError)")
            }
        }
        let journalDirectory = downloadRoot.appendingPathComponent(
            JazzArchiveServerImportCoordinator.operationJournalDirectoryName,
            isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalized.path))
        let firstAuthorizationCalls = await firstTransport.authorizationCalls()
        let firstBodyCalls = await firstTransport.bodyCalls()
        XCTAssertEqual(firstAuthorizationCalls, 1)
        XCTAssertEqual(firstBodyCalls, 1)
        let pending = try await JazzArchiveServerDownloadRecovery(
            root: downloadRoot,
            importTargetRoot: library
        ).pendingOperation()
        XCTAssertEqual(
            pending?.downloadOperationId,
            request.downloadOperationId)

        let retryTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: bytes,
            chunkSize: 1_024)
        let result = try await JazzArchiveServerImportCoordinator(
            root: downloadRoot,
            importer: JazzArchiveImporter(
                root: library,
                durability: controlledDurability.value()),
            transport: retryTransport
        ).importReadyArchive(
            request,
            importedAt: "2026-07-24T09:00:01Z",
            context: JazzArchiveImportContext())

        XCTAssertEqual(result.disposition, .alreadyPresent)
        XCTAssertEqual(try Data(contentsOf: result.packageURL), bytes)
        XCTAssertTrue(
            result.provenance.receipts.contains {
            $0.downloadOperationId == request.downloadOperationId
                && $0.downloadAuthorizationId == grant.downloadAuthorizationId
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
        let retryAuthorizationCalls = await retryTransport.authorizationCalls()
        let retryBodyCalls = await retryTransport.bodyCalls()
        XCTAssertEqual(retryAuthorizationCalls, 1)
        XCTAssertEqual(retryBodyCalls, 1)
    }

    func testServerDownloadBindingAndProfileFailBeforeOpeningProviderBody() async throws {
        let root = temporaryRoot("server-download-fail-closed")
        defer { removeTemporaryTree(root) }
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-fail-closed",
            scope: scope,
            downloadOperationId:
                "dop-018bcfe5-6800-7fff-bfff-ffffffffffff")
        let validDownload: [String: JazzArchiveJSONValue] = [
            "transport": .string("http-get/v1"),
            "method": .string("GET"),
            "url": .string("https://download.invalid/opaque-token"),
        ]
        let cases:
            [(
                name: String,
                operationId: String,
                download: [String: JazzArchiveJSONValue],
                expected: JazzArchiveServerDownloadError
            )] = [
            (
                "operation mismatch",
                "dop-018bcfe5-6801-7fff-bfff-ffffffffffff",
                validDownload,
                .invalidGrant("authorization")
            ),
            (
                "unknown transport",
                request.downloadOperationId,
                validDownload.merging(["transport": .string("http-get/v2")]) {
                    _, new in new
                },
                .invalidGrant("download")
            ),
            (
                "provider headers",
                request.downloadOperationId,
                validDownload.merging([
                    "headers": .object(["Range": .string("bytes=0-1")])
                ]) { _, new in new },
                .invalidGrant("download")
            ),
        ]

        for testCase in cases {
            let grant = JazzArchiveServerDownloadGrant(
                ingestId: request.ingestId,
                archiveId: "ar-22222222-2222-7222-8222-222222222222",
                formatVersion: 1,
                contentDigest: String(repeating: "0", count: 64),
                rawSha256: String(repeating: "1", count: 64),
                byteLength: 1,
                downloadOperationId: testCase.operationId,
                downloadAuthorizationId: "download-auth-fail-closed",
                grantExpiresAt: "2099-01-01T00:00:00Z",
                requestedBy: JazzArchiveServerDownloadPrincipal(
                    principalId: "bob@example.com",
                    tenantId: "tenant-acme",
                    companyId: scope.companyId,
                    areaId: scope.areaId,
                    deviceId: scope.deviceId,
                    basis: "authenticated_control_plane"),
                download: testCase.download)
            let transport = FakeArchiveServerDownloadTransport(
                grant: grant, bytes: Data([0]), chunkSize: 1)
            do {
                _ = try await JazzArchiveServerImportCoordinator(
                    root: root,
                    importer: JazzArchiveImporter(
                        root: root.appendingPathComponent("library", isDirectory: true)),
                    transport: transport,
                    now: { Date(timeIntervalSince1970: 1_800_000_000) }
                ).importReadyArchive(
                    request,
                    context: JazzArchiveImportContext())
                XCTFail("\(testCase.name) reached provider body")
            } catch {
                XCTAssertEqual(
                    error as? JazzArchiveServerDownloadError,
                    testCase.expected,
                    testCase.name)
            }
            let authorizationCalls = await transport.authorizationCalls()
            let bodyCalls = await transport.bodyCalls()
            XCTAssertEqual(authorizationCalls, 1, testCase.name)
            XCTAssertEqual(bodyCalls, 0, testCase.name)
        }
    }

    func testServerDownloadOperationSurvivesLegacyReplicaMismatchAndRelaunch() async throws {
        let root = temporaryRoot("server-download-operation-relaunch")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let durableOperationId =
            "dop-018bcfe5-6800-7fff-bfff-ffffffffffff"
        let firstRequest = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-relaunch",
            scope: scope,
            downloadOperationId: durableOperationId)
        let firstGenerationGrant = JazzArchiveServerDownloadGrant(
            ingestId: firstRequest.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count),
            downloadOperationId: durableOperationId,
            downloadAuthorizationId: "download-auth-relaunch-generation-1",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-secret-token"),
            ])
        let journalDirectory = root.appendingPathComponent(
            JazzArchiveServerImportCoordinator.operationJournalDirectoryName,
            isDirectory: true)
        let journalURL = journalDirectory.appendingPathComponent("intent.json")
        let initialRoute = testServerDownloadRoute(scope: scope)
        let failedTransport = FakeArchiveServerDownloadTransport(
            grant: firstGenerationGrant,
            bytes: bytes,
            chunkSize: 1_024,
            routeBinding: initialRoute,
            authorizationFailure: .serverUpgradeRequired,
            requiredJournalURLAtAuthorization: journalURL)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: failedTransport,
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ).importReadyArchive(
                firstRequest,
                context: JazzArchiveImportContext())
            XCTFail("legacy server contract mismatch was treated as a completed import")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }
        let failedOperationIds = await failedTransport.authorizedOperationIds()
        XCTAssertEqual(failedOperationIds, [durableOperationId])
        let journalWasPresent =
            await failedTransport.journalWasPresentAtAuthorization()
        XCTAssertEqual(journalWasPresent, true)

        let journalData = try Data(contentsOf: journalURL)
        let journalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: journalData) as? [String: Any])
        XCTAssertEqual(
            Set(journalObject.keys),
            Set([
                "schemaVersion", "downloadOperationId", "authorityBinding",
                "routeBinding",
                "ingestId", "companyId", "areaId", "deviceId",
                "importTargetPath", "createdAt",
            ]))
        XCTAssertEqual(journalObject["schemaVersion"] as? Int, 2)
        XCTAssertEqual(
            journalObject["downloadOperationId"] as? String,
            durableOperationId)
        XCTAssertFalse(
            String(decoding: journalData, as: UTF8.self).contains(
            "opaque-secret-token"))
        XCTAssertFalse(
            String(decoding: journalData, as: UTF8.self).contains(
            firstGenerationGrant.downloadAuthorizationId))

        let relaunchedRequest = JazzArchiveServerDownloadRequest(
            ingestId: firstRequest.ingestId,
            scope: scope,
            downloadOperationId:
                "dop-018bcfe5-6801-7fff-bfff-ffffffffffff")
        let renewedGrant = JazzArchiveServerDownloadGrant(
            ingestId: firstRequest.ingestId,
            archiveId: firstGenerationGrant.archiveId,
            formatVersion: firstGenerationGrant.formatVersion,
            contentDigest: firstGenerationGrant.contentDigest,
            rawSha256: firstGenerationGrant.rawSha256,
            byteLength: firstGenerationGrant.byteLength,
            downloadOperationId: durableOperationId,
            downloadAuthorizationId: "download-auth-relaunch-generation-2",
            grantExpiresAt: "2099-01-02T00:00:00Z",
            requestedBy: firstGenerationGrant.requestedBy,
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/renewed-opaque-token"),
            ])
        let relaunchedTransport = FakeArchiveServerDownloadTransport(
            grant: renewedGrant,
            bytes: bytes,
            chunkSize: 733,
            routeBinding: testServerDownloadRoute(
                scope: scope,
                tokenId: "789",
                bundleId: "jdb_cccccccccccccccccccccccccccccccc",
                generation: 2,
                envelopeDigest: String(repeating: "d", count: 64)))
        XCTAssertTrue(
            initialRoute.hasSameDeliveryAuthority(
                as: relaunchedTransport.routeBinding))
        let result = try await JazzArchiveServerImportCoordinator(
            root: root,
            importer: JazzArchiveImporter(root: library),
            transport: relaunchedTransport,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        ).importReadyArchive(
            relaunchedRequest,
            context: JazzArchiveImportContext())

        let relaunchedOperationIds =
            await relaunchedTransport.authorizedOperationIds()
        XCTAssertEqual(relaunchedOperationIds, [durableOperationId])
        let receipt = try XCTUnwrap(result.provenance.receipts.last)
        XCTAssertEqual(receipt.downloadOperationId, durableOperationId)
        XCTAssertEqual(
            receipt.downloadAuthorizationId,
            renewedGrant.downloadAuthorizationId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalDirectory.path))
    }

    func testExistingIntentRetryFinishesFailedRenameDurabilityBeforeNetwork()
        async throws
    {
        let value = durabilityDownloadFixture("intent-fsync-retry")
        defer { removeTemporaryTree(value.root) }
        let activeDirectory = value.root.appendingPathComponent(
            JazzArchiveServerImportCoordinator.operationJournalDirectoryName,
            isDirectory: true)
        let document = activeDirectory.appendingPathComponent("intent.json")
        let durability = FailOnceServerDownloadDurability(
            failureDirectory: value.root)
        let firstTransport = FakeArchiveServerDownloadTransport(
            grant: value.grant,
            bytes: Data([0]),
            chunkSize: 1)

        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: value.root,
                importer: JazzArchiveImporter(root: value.library),
                transport: firstTransport,
                durability: durability.value()
            ).importReadyArchive(
                value.request,
                context: JazzArchiveImportContext())
            XCTFail("the injected post-rename root fsync failure was ignored")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .operationJournalWriteFailed)
        }
        let firstAuthorizationCalls = await firstTransport.authorizationCalls()
        XCTAssertEqual(firstAuthorizationCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))

        let retryEventOffset = durability.events().count
        let retryTransport = FakeArchiveServerDownloadTransport(
            grant: value.grant,
            bytes: Data([0]),
            chunkSize: 1,
            authorizationFailure: .serverUpgradeRequired)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: value.root,
                importer: JazzArchiveImporter(root: value.library),
                transport: retryTransport,
                durability: durability.value()
            ).importReadyArchive(
                value.request,
                context: JazzArchiveImportContext())
            XCTFail("retry unexpectedly passed the fake authorization failure")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }
        let retryAuthorizationCalls = await retryTransport.authorizationCalls()
        XCTAssertEqual(retryAuthorizationCalls, 1)
        let retryEvents = Array(durability.events().dropFirst(retryEventOffset))
        XCTAssertEqual(
            Array(retryEvents.prefix(3)),
            [
                .file(document.standardizedFileURL.path, Int16(0o400)),
                .directory(activeDirectory.standardizedFileURL.path),
                .directory(value.root.standardizedFileURL.path),
            ])
    }

    func testMatchingAbandonmentRetryResynchronizesAuditBeforeJournalRemoval()
        async throws
    {
        let value = durabilityDownloadFixture("abandonment-fsync-retry")
        defer { removeTemporaryTree(value.root) }
        let seedTransport = FakeArchiveServerDownloadTransport(
            grant: value.grant,
            bytes: Data([0]),
            chunkSize: 1,
            authorizationFailure: .serverUpgradeRequired)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: value.root,
                importer: JazzArchiveImporter(root: value.library),
                transport: seedTransport
            ).importReadyArchive(
                value.request,
                context: JazzArchiveImportContext())
            XCTFail("seed operation unexpectedly completed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }

        let activeDirectory = value.root.appendingPathComponent(
            JazzArchiveServerImportCoordinator.operationJournalDirectoryName,
            isDirectory: true)
        let history = value.root.appendingPathComponent(
            ".server-download-history",
            isDirectory: true)
        let audit = history.appendingPathComponent(
            "\(value.request.downloadOperationId).abandoned.json")
        let durability = FailOnceServerDownloadDurability(
            failureDirectory: history)
        let recovery = JazzArchiveServerDownloadRecovery(
            root: value.root,
            importTargetRoot: value.library,
            durability: durability.value())

        do {
            _ = try await recovery.abandonPendingOperation(
                downloadOperationId: value.request.downloadOperationId,
                reason: "user_confirmed_from_desktop",
                abandonedAt: "2026-07-24T08:00:00Z")
            XCTFail("the injected history-directory fsync failure was ignored")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .operationJournalWriteFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audit.path))

        let retryEventOffset = durability.events().count
        let abandonment = try await recovery.abandonPendingOperation(
            downloadOperationId: value.request.downloadOperationId,
            reason: "user_confirmed_from_desktop",
            abandonedAt: "2026-07-24T08:00:00Z")
        XCTAssertEqual(
            abandonment.downloadOperationId,
            value.request.downloadOperationId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory.path))
        let retryEvents = Array(durability.events().dropFirst(retryEventOffset))
        XCTAssertEqual(
            Array(retryEvents.prefix(3)),
            [
                .file(audit.standardizedFileURL.path, Int16(0o400)),
                .directory(history.standardizedFileURL.path),
                .directory(value.root.standardizedFileURL.path),
            ])
        let permissions =
            try FileManager.default.attributesOfItem(
            atPath: audit.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions.map { $0.intValue & 0o777 }, 0o400)
    }

    func testPendingServerDownloadCanBeInspectedAndDeliberatelyAbandonedWithAudit()
        async throws
    {
        let root = temporaryRoot("server-download-abandon")
        defer { removeTemporaryTree(root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true)
        let preservedEvidence = library.appendingPathComponent("preserved-evidence.txt")
        try Data("already imported evidence".utf8).write(to: preservedEvidence)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-permanent-404",
            scope: scope,
            downloadOperationId:
                "dop-018bcfe5-6800-7fff-bfff-ffffffffffff")
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-abandon",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque"),
            ])
        let failed = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: Data([0]),
            chunkSize: 1,
            authorizationFailure: .serverUpgradeRequired)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: failed
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("seed operation unexpectedly completed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }

        let recovery = JazzArchiveServerDownloadRecovery(
            root: root,
            importTargetRoot: library)
        let pending = try await recovery.pendingOperation()
        XCTAssertEqual(pending?.downloadOperationId, request.downloadOperationId)
        XCTAssertEqual(pending?.ingestId, request.ingestId)
        let abandonment = try await recovery.abandonPendingOperation(
            downloadOperationId: request.downloadOperationId,
            reason: "user_confirmed_from_desktop",
            abandonedAt: "2026-07-24T08:00:00Z")
        XCTAssertEqual(abandonment.downloadOperationId, request.downloadOperationId)
        XCTAssertEqual(abandonment.reason, "user_confirmed_from_desktop")
        let pendingAfterAbandonment = try await recovery.pendingOperation()
        XCTAssertNil(pendingAfterAbandonment)
        let recordedAbandonment = try await recovery.abandonment(
            downloadOperationId: request.downloadOperationId)
        XCTAssertEqual(recordedAbandonment, abandonment)
        XCTAssertEqual(
            try Data(contentsOf: preservedEvidence),
            Data("already imported evidence".utf8))

        let retryTransport = FakeArchiveServerDownloadTransport(
            grant: grant, bytes: Data([0]), chunkSize: 1)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: retryTransport
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("abandoned operation was silently resumed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .operationAbandoned)
        }
        let retryAuthorizationCalls = await retryTransport.authorizationCalls()
        XCTAssertEqual(retryAuthorizationCalls, 0)
    }

    func testServerDownloadReapsOnlySafeStaleClaimsUnderOperationLease() async throws {
        let root = temporaryRoot("server-download-stale-claims")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let stale = root.appendingPathComponent(
            ".server-download-018bcfe5-6800-7fff-bfff-ffffffffffff",
            isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try Data("partial".utf8).write(
            to: stale.appendingPathComponent(
                "ar-22222222-2222-7222-8222-222222222222.jazz-archive"))
        let protected = root.appendingPathComponent(
            ".server-download-intent-018bcfe5-6800-7fff-bfff-ffffffffffff",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: protected,
            withIntermediateDirectories: false)
        let protectedFile = protected.appendingPathComponent("do-not-delete")
        try Data("journal staging".utf8).write(to: protectedFile)

        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-stale-cleanup",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-stale",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/stale"),
            ])
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(
                    root: root.appendingPathComponent("library")),
                transport: FakeArchiveServerDownloadTransport(
                    grant: grant,
                    bytes: Data([0]),
                    chunkSize: 1,
                    authorizationFailure: .serverUpgradeRequired)
            ).importReadyArchive(request, context: JazzArchiveImportContext())
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protectedFile.path))
    }

    func testServerDownloadUnsafeStaleClaimFailsClosedWithoutFollowingSymlink()
        async throws
    {
        let root = temporaryRoot("server-download-unsafe-stale")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("must-survive", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let link = root.appendingPathComponent(
            ".server-download-018bcfe5-6800-7fff-bfff-ffffffffffff",
            isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-unsafe-stale",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-unsafe",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/unsafe"),
            ])
        let transport = FakeArchiveServerDownloadTransport(
            grant: grant, bytes: Data([0]), chunkSize: 1)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(
                    root: root.appendingPathComponent("library")),
                transport: transport
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("unsafe stale claim was traversed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .staleClaimUnsafe)
        }
        let authorizationCalls = await transport.authorizationCalls()
        XCTAssertEqual(authorizationCalls, 0)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testIndependentServerImportCoordinatorsFailClosedWhileOperationLeaseIsHeld()
        async throws
    {
        let root = temporaryRoot("server-download-operation-lock")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-operation-lock",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count),
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-operation-lock",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/lock"),
            ])
        let firstTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: bytes,
            chunkSize: 1_024,
            authorizationDelayNanoseconds: 500_000_000)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let first = Task {
            try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: firstTransport
            ).importReadyArchive(request, context: JazzArchiveImportContext())
        }
        for _ in 0..<200 {
            if await firstTransport.authorizationCalls() == 1 { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let firstAuthorizationCalls = await firstTransport.authorizationCalls()
        XCTAssertEqual(firstAuthorizationCalls, 1)

        let secondTransport = FakeArchiveServerDownloadTransport(
            grant: grant, bytes: bytes, chunkSize: 1_024)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: secondTransport
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("second coordinator acquired the active operation lease")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .operationInProgress)
        }
        let secondAuthorizationCalls = await secondTransport.authorizationCalls()
        XCTAssertEqual(secondAuthorizationCalls, 0)
        _ = try await first.value
    }

    func testServerDownloadOperationJournalRejectsAuthorityIngestAndTargetCollisions()
        async throws
    {
        let root = temporaryRoot("server-download-operation-collisions")
        defer { removeTemporaryTree(root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-bound",
            scope: scope,
            downloadOperationId:
                "dop-018bcfe5-6800-7fff-bfff-ffffffffffff")
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-bound",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
            ])
        let authorityA = "https://jazz-a.invalid/api/archive-ingests"
        let initialRoute = testServerDownloadRoute(
            endpoint: authorityA,
            scope: scope)
        let seedTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: Data([0]),
            chunkSize: 1,
            routeBinding: initialRoute,
            authorizationFailure: .writeFailed)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: seedTransport
            ).importReadyArchive(
                request,
                context: JazzArchiveImportContext())
            XCTFail("seed operation unexpectedly completed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .writeFailed)
        }

        let changedIngestRequest = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-other",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let changedScope = JazzArchiveServerScope(
            companyId: scope.companyId,
            areaId: "other-area",
            deviceId: scope.deviceId)
        let changedScopeRequest = JazzArchiveServerDownloadRequest(
            ingestId: request.ingestId,
            scope: changedScope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let attempts:
            [(
                name: String,
                request: JazzArchiveServerDownloadRequest,
                routeBinding: JazzArchiveUploadRouteBinding,
                target: URL
            )] = [
            (
                "endpoint",
                request,
                testServerDownloadRoute(
                    endpoint: "https://jazz-b.invalid/api/archive-ingests",
                    scope: scope),
                library
            ),
            (
                "ingest",
                changedIngestRequest,
                initialRoute,
                library
            ),
            (
                "target",
                request,
                initialRoute,
                root.appendingPathComponent("other-library", isDirectory: true)
            ),
            (
                "issuer",
                request,
                testServerDownloadRoute(
                    endpoint: authorityA,
                    scope: scope,
                    issuer: "https://other-issuer.invalid"),
                library
            ),
            (
                "audience",
                request,
                testServerDownloadRoute(
                    endpoint: authorityA,
                    scope: scope,
                    audience: "other-desktop"),
                library
            ),
            (
                "project",
                request,
                testServerDownloadRoute(
                    endpoint: authorityA,
                    scope: scope,
                    projectId: "999"),
                library
            ),
            (
                "stack",
                request,
                testServerDownloadRoute(
                    endpoint: authorityA,
                    scope: scope,
                    stackURL: "https://connection.other.keboola.com"),
                library
            ),
            (
                "scope",
                changedScopeRequest,
                testServerDownloadRoute(
                    endpoint: authorityA,
                    scope: changedScope),
                library
            ),
        ]
        for attempt in attempts {
            let transport = FakeArchiveServerDownloadTransport(
                grant: grant,
                bytes: Data([0]),
                chunkSize: 1,
                routeBinding: attempt.routeBinding)
            do {
                _ = try await JazzArchiveServerImportCoordinator(
                    root: root,
                    importer: JazzArchiveImporter(root: attempt.target),
                    transport: transport
                ).importReadyArchive(
                    attempt.request,
                    context: JazzArchiveImportContext())
                XCTFail("\(attempt.name) collision reached authorization")
            } catch {
                XCTAssertEqual(
                    error as? JazzArchiveServerDownloadError,
                    .operationJournalBindingConflict,
                    attempt.name)
            }
            let authorizationCalls = await transport.authorizationCalls()
            XCTAssertEqual(authorizationCalls, 0, attempt.name)
        }
    }

    func testLegacyServerDownloadJournalCanBeInspectedAndAbandonedButNotResumed()
        async throws
    {
        let root = temporaryRoot("server-download-legacy-journal")
        defer { removeTemporaryTree(root) }
        let library = root.appendingPathComponent("library", isDirectory: true)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-legacy-download",
            scope: scope,
            downloadOperationId:
                "dop-018bcfe5-6800-7fff-bfff-ffffffffffff")
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-legacy-journal",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
            ])
        let routeBinding = testServerDownloadRoute(scope: scope)
        let seedTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: Data([0]),
            chunkSize: 1,
            routeBinding: routeBinding,
            authorizationFailure: .serverUpgradeRequired)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: seedTransport
            ).importReadyArchive(
                request,
                context: JazzArchiveImportContext())
            XCTFail("seed operation unexpectedly completed")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .serverUpgradeRequired)
        }

        let journalURL = root.appendingPathComponent(
            JazzArchiveServerImportCoordinator.operationJournalDirectoryName,
            isDirectory: true
        ).appendingPathComponent("intent.json")
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: journalURL)) as? [String: Any])
        legacyObject["schemaVersion"] = 1
        legacyObject.removeValue(forKey: "routeBinding")
        try JSONSerialization.data(
            withJSONObject: legacyObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).write(to: journalURL, options: [.atomic])

        let recovery = JazzArchiveServerDownloadRecovery(
            root: root,
            importTargetRoot: library)
        let pending = try await recovery.pendingOperation()
        XCTAssertEqual(pending?.downloadOperationId, request.downloadOperationId)
        XCTAssertEqual(pending?.authorityBinding, routeBinding.ingestEndpoint)
        XCTAssertNil(pending?.routeBinding)

        let retryTransport = FakeArchiveServerDownloadTransport(
            grant: grant,
            bytes: Data([0]),
            chunkSize: 1,
            routeBinding: routeBinding)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: retryTransport
            ).importReadyArchive(
                request,
                context: JazzArchiveImportContext())
            XCTFail("unsigned legacy journal reached authorization")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .operationJournalBindingConflict)
        }
        let retryAuthorizationCalls = await retryTransport.authorizationCalls()
        XCTAssertEqual(retryAuthorizationCalls, 0)

        let abandonment = try await recovery.abandonPendingOperation(
            downloadOperationId: request.downloadOperationId,
            reason: "legacy_journal_requires_explicit_abandonment",
            abandonedAt: "2026-07-24T08:00:00Z")
        XCTAssertEqual(abandonment.schemaVersion, 1)
        XCTAssertNil(abandonment.routeBinding)
        let pendingAfterAbandonment = try await recovery.pendingOperation()
        XCTAssertNil(pendingAfterAbandonment)
        let recordedAbandonment = try await recovery.abandonment(
            downloadOperationId: request.downloadOperationId)
        XCTAssertEqual(
            recordedAbandonment,
            abandonment)
    }

    func testServerDownloadFingerprintMismatchNeverPublishesAnArchive() async throws {
        let root = temporaryRoot("server-download-mismatch")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-mismatch",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: String(repeating: "0", count: 64),
            byteLength: Int64(bytes.count),
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-mismatch",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
            ])
        let library = root.appendingPathComponent("library", isDirectory: true)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: FakeArchiveServerDownloadTransport(
                    grant: grant, bytes: bytes, chunkSize: 1_024),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("mismatched READY raw digest reached the importer")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .bodyFingerprintMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testServerDownloadLengthMismatchNeverPublishesAnArchive() async throws {
        let root = temporaryRoot("server-download-length-mismatch")
        defer { removeTemporaryTree(root) }
        let packageURL = repositoryRoot().appendingPathComponent(
            "contract/archive/container/fixtures/01-canonical-v1.jazz-archive")
        let bytes = try Data(contentsOf: packageURL)
        let scope = JazzArchiveServerScope(
            companyId: "acme", areaId: "finance", deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-ready-length-mismatch",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "653b1ed188997c985a4b09cf940034babdb7ab901a73fc591d6aa9257888ab81",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count) + 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-length-mismatch",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
            ])
        let library = root.appendingPathComponent("library", isDirectory: true)
        do {
            _ = try await JazzArchiveServerImportCoordinator(
                root: root,
                importer: JazzArchiveImporter(root: library),
                transport: FakeArchiveServerDownloadTransport(
                    grant: grant, bytes: bytes, chunkSize: 1_024),
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ).importReadyArchive(request, context: JazzArchiveImportContext())
            XCTFail("mismatched READY byte length reached the importer")
        } catch {
            XCTAssertEqual(
                error as? JazzArchiveServerDownloadError,
                .bodyFingerprintMismatch)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testImportsCanonicalDesktopCoachAndMeetingCaptureSources() async throws {
        let root = temporaryRoot("source-neutral-fixtures")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let importer = JazzArchiveImporter(
            root: root.appendingPathComponent("library", isDirectory: true))
        let fixtures = [
            (
                name: "01-minimal-desktop",
                archiveId: "ar-11111111-1111-7111-8111-111111111111",
                captureId: "cap-11111111-1111-7111-8111-111111111111",
                recordCount: 4,
                labelCount: 0,
                artifactCount: 1
            ),
            (
                name: "03-capture-coach",
                archiveId: "ar-33333333-3333-7333-8333-333333333333",
                captureId: "cap-33333333-3333-7333-8333-333333333333",
                recordCount: 16,
                labelCount: 1,
                artifactCount: 0
            ),
            (
                name: "04-meeting-screen-share",
                archiveId: "ar-44444444-4444-7444-8444-444444444441",
                captureId: "cap-44444444-4444-7444-8444-444444444441",
                recordCount: 13,
                labelCount: 1,
                artifactCount: 3
            ),
        ]

        for fixture in fixtures {
            let fixtureRoot = repositoryRoot()
                .appendingPathComponent(
                    "contract/archive/fixtures/\(fixture.name)",
                    isDirectory: true)
            let packageURL = root.appendingPathComponent(
                "\(fixture.name).jazz-archive")
            try makeStoredZIP(
                try regularFixtureEntries(
                at: fixtureRoot,
                    excludingTopLevelDirectories: ["sync"])
            ).write(to: packageURL)

            let result = try await importer.importArchive(at: packageURL)

            XCTAssertEqual(result.snapshot.manifest.archiveId, fixture.archiveId)
            let records = try result.snapshot.records(
                captureId: fixture.captureId)
            XCTAssertEqual(records.count, fixture.recordCount)
            if fixture.name == "01-minimal-desktop" {
                let capability = try XCTUnwrap(
                    records.first {
                        $0.recordType
                            == ArchiveRecord<JazzCaptureCapabilityObservation>
                            .captureCapabilityRecordType
                    })
            XCTAssertEqual(
                    try capability.captureCapabilityObservationRecord().payload,
                    JazzCaptureCapabilityObservation(
                        capability: .accessibilityContext,
                        authorizationStatus: .granted,
                        availability: .available,
                        transition: .initial,
                        reason: .permissionGranted,
                        observedAt: "2026-07-22T08:00:30Z"))
            }
            XCTAssertEqual(
                try result.snapshot.labels(captureId: fixture.captureId).count,
                fixture.labelCount)
            let artifacts = try result.snapshot.artifacts(
                captureId: fixture.captureId)
            XCTAssertEqual(artifacts.count, fixture.artifactCount)
            if fixture.name == "01-minimal-desktop" {
                let screenshot = try XCTUnwrap(
                    artifacts.first { $0.kind == "screenshot" })
                XCTAssertEqual(
                    screenshot.captureInterval,
                    JazzArchiveArtifactCaptureInterval(
                        startedAt: "2026-07-22T08:00:10.000Z",
                        endedAt: "2026-07-22T08:00:10.125Z"))
                XCTAssertEqual(
                    screenshot.quality.reasons,
                    [
                        JazzArchiveScreenshotEvidenceV1.temporalIntervalReason,
                        JazzArchiveScreenshotEvidenceV1.displayFallbackReason,
                    ])
                XCTAssertEqual(screenshot.quality.timingErrorMillis, 125)
                XCTAssertEqual(
                    try JazzArchiveScreenshotEvidenceV1.decode(
                        from: screenshot.extensions),
                    JazzArchiveScreenshotEvidenceV1(
                        requestStartedAt: "2026-07-22T08:00:10.000Z",
                        frameCompletedAt: "2026-07-22T08:00:10.125Z",
                        monotonicDurationMillis: 125,
                        scope: .display(
                            displayId: 7,
                            excludedApplicationBundleIds: [
                                "com.example.password-manager"
                            ])))
                let screenshotBytes = try Data(
                    contentsOf: result.snapshot.directoryURL
                        .appendingPathComponent(screenshot.content.path))
                let imageSource = try XCTUnwrap(
                    CGImageSourceCreateWithData(
                        screenshotBytes as CFData,
                        nil))
                XCTAssertEqual(CGImageSourceGetCount(imageSource), 1)
                let image = try XCTUnwrap(
                    CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                XCTAssertEqual(image.width, 2)
                XCTAssertEqual(image.height, 2)
            }
        }
    }

    private struct PortableFixture {
        let packageURL: URL
        let archiveId: String
        let captureId: String
        let artifactId: String
        let artifactBytes: Data
    }

    private func makePortablePackage(
        root: URL,
        archiveId: String = Identifiers.newArchiveId(),
        finalEventType: EventType = .navigate
    ) async throws -> PortableFixture {
        let originId = Identifiers.newOriginId()
        let sessionId = Identifiers.newSessionId()
        let captureId = Identifiers.newCaptureId()
        let streamId = Identifiers.newStreamId()
        let actorId = Identifiers.newActorId()
        let sourceId = Identifiers.newSourceId()
        let artifactId = Identifiers.newArtifactId()
        let producer = JazzArchiveProducer(name: "Importer test", version: "1")
        let manifest = JazzArchiveManifest(
            archiveId: archiveId,
            originId: originId,
            createdAt: startedAt,
            producer: producer,
            actors: [
                JazzArchiveActor(
                actorId: actorId,
                kind: .human,
                identityStatus: .identified,
                displayName: "Recorder",
                    provenance: JazzArchiveProvenance(factClass: .declared, sources: []))
            ],
            sources: [
                JazzArchiveSource(
                sourceId: sourceId,
                kind: "macos.capture-controller",
                actorId: actorId,
                producer: producer,
                    provenance: JazzArchiveProvenance(factClass: .observed, sources: []))
            ],
            sessions: [
                JazzArchiveSessionRef(
                captureId: captureId,
                    legacySessionId: sessionId)
            ])
        let session = JazzArchiveSession(
            captureId: captureId,
            legacySessionId: sessionId,
            archiveId: archiveId,
            streamIds: [streamId],
            startedAt: startedAt,
            recorderActorId: actorId,
            sourceIds: [sourceId],
            capturePolicy: JazzArchiveCapturePolicy(
                policyVersion: "test-consent",
                consentedAt: startedAt,
                modalities: [.pointer, .screenshots],
                excludedApplications: [],
                businessDataCapture: false),
            quality: JazzArchiveQuality(status: .complete))
        let store = JazzArchiveDraftStore(root: root)
        _ = try await store.create(manifest: manifest, session: session)

        let artifactBytes = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let artifactDigest = JazzArchiveDigest.sha256Hex(artifactBytes)
        let artifact = JazzArchiveArtifact(
            artifactId: artifactId,
            captureId: captureId,
            kind: "screenshot",
            content: JazzArchiveArtifactContent(
                path: "blobs/sha256/\(artifactDigest.prefix(2))/\(artifactDigest)",
                mediaType: "image/png",
                byteLength: Int64(artifactBytes.count),
                sha256: artifactDigest),
            sourceRefs: [JazzArchiveSourceRef(sourceId: sourceId, role: "screen_capture")],
            actorRefs: [
                JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                    method: "test")
            ],
            captureInterval: testScreenshotCaptureInterval(at: startedAt),
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [sourceId]),
            quality: testScreenshotQuality(),
            privacy: JazzArchivePrivacy(
                status: .captured,
                policyVersion: "test-consent"),
            extensions: testScreenshotEvidence(at: startedAt).extensions)
        _ = try await store.ingestArtifact(
            archiveId: archiveId,
            captureId: captureId,
            artifact: artifact,
            bytes: artifactBytes)
        let records = [
            activityRecord(
                sessionId: sessionId,
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                sequence: 0,
                timestamp: startedAt,
                type: .click,
                artifactId: artifactId),
            activityRecord(
                sessionId: sessionId,
                originId: originId,
                captureId: captureId,
                streamId: streamId,
                sourceId: sourceId,
                actorId: actorId,
                sequence: 2,
                timestamp: "2026-07-23T10:00:02.000Z",
                type: finalEventType,
                artifactId: nil),
        ]
        _ = try await store.append(
            archiveId: archiveId,
            captureId: captureId,
            records: records)
        _ = try await store.end(
            archiveId: archiveId,
            captureId: captureId,
            endedAt: "2026-07-23T10:00:03.000Z",
            artifactDigests: [artifactId: artifactDigest],
            gapReason: .captureLoss)
        let finalizer = JazzArchiveFinalizer(root: root)
        let finalized = try await finalizer.finalize(
            archiveId: archiveId,
            snapshotAt: "2026-07-23T10:01:00.000Z")
        let packageURL = root.appendingPathComponent(
            "\(UUID().uuidString).jazz-archive")
        _ = try await finalizer.export(finalized, to: packageURL)
        return PortableFixture(
            packageURL: packageURL,
            archiveId: archiveId,
            captureId: captureId,
            artifactId: artifactId,
            artifactBytes: artifactBytes)
    }

    private func activityRecord(
        sessionId: String,
        originId: String,
        captureId: String,
        streamId: String,
        sourceId: String,
        actorId: String,
        sequence: Int,
        timestamp: String,
        type: EventType,
        artifactId: String?
    ) -> ArchiveRecord<ActivityEvent> {
        ArchiveRecord(
            event: ActivityEvent(
                sessionId: sessionId,
                eventId: Identifiers.eventId(sessionId: sessionId, sequence: sequence),
                sequence: sequence,
                timestamp: timestamp,
                eventType: type.rawValue,
                url: "app://com.example.finance",
                application: ActivityApplicationIdentity(
                    namespace: "macos.bundle-id",
                    value: "com.example.finance",
                    name: "Finance")),
            originId: originId,
            captureId: captureId,
            streamId: streamId,
            streamSequence: sequence,
            sourceRefs: [JazzArchiveSourceRef(sourceId: sourceId, role: "trigger")],
            actorRefs: [
                JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                    method: "test")
            ],
            artifactRefs: artifactId.map {
                [JazzArchiveArtifactRef(artifactId: $0, role: "screenshot")]
            } ?? [],
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(status: .captured, policyVersion: "test-consent"))
    }

    private enum ExpectedRejection {
        case unsafe
        case duplicate
        case unsupported
    }

    private struct TestZIPEntry {
        let name: String
        let data: Data
        let externalAttributes: UInt32

        init(
            name: String,
            data: Data,
            externalAttributes: UInt32 = UInt32(0o100644 << 16)
        ) {
            self.name = name
            self.data = data
            self.externalAttributes = externalAttributes
        }
    }

    private func standardEntries(extra: [TestZIPEntry] = []) -> [TestZIPEntry] {
        [
            TestZIPEntry(name: "inventory.json", data: Data("{}".utf8)),
            TestZIPEntry(name: "manifest.json", data: Data("{}".utf8)),
        ] + extra
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func regularFixtureEntries(
        at root: URL,
        excludingTopLevelDirectories excluded: Set<String>
    ) throws -> [TestZIPEntry] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            throw JazzArchiveImportError.invalidArchive("fixture cannot be enumerated")
        }
        var entries: [TestZIPEntry] = []
        while let relative = enumerator.nextObject() as? String {
            if let first = relative.split(separator: "/").first,
                excluded.contains(String(first))
            {
                enumerator.skipDescendants()
                continue
            }
            let url = root.appendingPathComponent(relative)
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw JazzArchiveImportError.unsafeEntry(relative)
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw JazzArchiveImportError.unsafeEntry(relative)
            }
            entries.append(
                TestZIPEntry(
                name: relative,
                data: try Data(contentsOf: url)))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private func makeStoredZIP(
        _ sourceEntries: [TestZIPEntry],
        method: UInt16 = 0
    ) -> Data {
        let entries = sourceEntries.sorted { $0.name < $1.name }
        var output = Data()
        var central: [(TestZIPEntry, UInt32, UInt32)] = []
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = testCRC32(entry.data)
            let offset = UInt32(output.count)
            output.appendTestLE(UInt32(0x0403_4b50))
            output.appendTestLE(UInt16(20))
            output.appendTestLE(UInt16(0x0800))
            output.appendTestLE(method)
            output.appendTestLE(UInt16(0))
            output.appendTestLE(UInt16(0x0021))
            output.appendTestLE(crc)
            output.appendTestLE(UInt32(entry.data.count))
            output.appendTestLE(UInt32(entry.data.count))
            output.appendTestLE(UInt16(name.count))
            output.appendTestLE(UInt16(0))
            output.append(name)
            output.append(entry.data)
            central.append((entry, crc, offset))
        }
        let centralOffset = UInt32(output.count)
        for (entry, crc, offset) in central {
            let name = Data(entry.name.utf8)
            output.appendTestLE(UInt32(0x0201_4b50))
            output.appendTestLE(UInt16(0x0314))
            output.appendTestLE(UInt16(20))
            output.appendTestLE(UInt16(0x0800))
            output.appendTestLE(method)
            output.appendTestLE(UInt16(0))
            output.appendTestLE(UInt16(0x0021))
            output.appendTestLE(crc)
            output.appendTestLE(UInt32(entry.data.count))
            output.appendTestLE(UInt32(entry.data.count))
            output.appendTestLE(UInt16(name.count))
            output.appendTestLE(UInt16(0))
            output.appendTestLE(UInt16(0))
            output.appendTestLE(UInt16(0))
            output.appendTestLE(UInt16(0))
            output.appendTestLE(entry.externalAttributes)
            output.appendTestLE(offset)
            output.append(name)
        }
        let centralSize = UInt32(output.count) - centralOffset
        output.appendTestLE(UInt32(0x0605_4b50))
        output.appendTestLE(UInt16(0))
        output.appendTestLE(UInt16(0))
        output.appendTestLE(UInt16(entries.count))
        output.appendTestLE(UInt16(entries.count))
        output.appendTestLE(centralSize)
        output.appendTestLE(centralOffset)
        output.appendTestLE(UInt16(0))
        return output
    }

    private func testCRC32(_ data: Data) -> UInt32 {
        var value = UInt32.max
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0..<8 {
                value =
                    (value & 1) == 1
                    ? 0xedb8_8320 ^ (value >> 1)
                    : value >> 1
            }
        }
        return value ^ UInt32.max
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "jazz-importer-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    private func durabilityDownloadFixture(
        _ suffix: String
    ) -> (
        root: URL,
        library: URL,
        request: JazzArchiveServerDownloadRequest,
        grant: JazzArchiveServerDownloadGrant
    ) {
        let root = temporaryRoot(suffix)
        let library = root.appendingPathComponent("library", isDirectory: true)
        let scope = JazzArchiveServerScope(
            companyId: "acme",
            areaId: "finance",
            deviceId: "reader-device-2")
        let request = JazzArchiveServerDownloadRequest(
            ingestId: "ingest-\(suffix)",
            scope: scope,
            downloadOperationId: Identifiers.newDownloadOperationId())
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest: String(repeating: "0", count: 64),
            rawSha256: String(repeating: "1", count: 64),
            byteLength: 1,
            downloadOperationId: request.downloadOperationId,
            downloadAuthorizationId: "download-auth-\(suffix)",
            grantExpiresAt: "2099-01-01T00:00:00Z",
            requestedBy: JazzArchiveServerDownloadPrincipal(
                principalId: "bob@example.com",
                tenantId: "tenant-acme",
                companyId: scope.companyId,
                areaId: scope.areaId,
                deviceId: scope.deviceId,
                basis: "authenticated_control_plane"),
            download: [
                "transport": .string("http-get/v1"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque"),
            ])
        return (root, library, request, grant)
    }

    private func removeTemporaryTree(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        var directories = [root]
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        {
            while let url = enumerator.nextObject() as? URL {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    directories.append(url)
                }
            }
        }
        for directory in directories {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path)
        }
        try? FileManager.default.removeItem(at: root)
    }
}

final class TestArchiveFilesystemLeaseProvider:
    @unchecked Sendable, JazzArchiveFilesystemLeaseProvider
{
    static let shared = TestArchiveFilesystemLeaseProvider()

    private let lock = NSLock()
    private var heldRoots: Set<String> = []

    func acquire(
        root: URL,
        fileManager: FileManager
    ) throws -> any JazzArchiveFilesystemLease {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let path = root.standardizedFileURL.path
        lock.lock()
        let acquired = heldRoots.insert(path).inserted
        lock.unlock()
        guard acquired else {
            throw JazzArchiveFilesystemLeaseError.inProgress
        }
        return TestArchiveFilesystemLease(provider: self, path: path)
    }

    fileprivate func release(path: String) {
        lock.lock()
        heldRoots.remove(path)
        lock.unlock()
    }
}

private final class TestArchiveFilesystemLease:
    @unchecked Sendable, JazzArchiveFilesystemLease
{
    private let provider: TestArchiveFilesystemLeaseProvider
    private let path: String
    private let lock = NSLock()
    private var isReleased = false

    init(provider: TestArchiveFilesystemLeaseProvider, path: String) {
        self.provider = provider
        self.path = path
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        provider.release(path: path)
    }

    deinit { release() }
}

private final class FailOnceServerDownloadDurability: @unchecked Sendable {
    enum Event: Equatable {
        case file(String, Int16?)
        case directory(String)
    }

    private let lock = NSLock()
    private let failureDirectoryPath: String
    private var didFail = false
    private var recordedEvents: [Event] = []

    init(failureDirectory: URL) {
        self.failureDirectoryPath = failureDirectory.standardizedFileURL.path
    }

    func value() -> JazzArchiveFilesystemDurability {
        let system = foundationTestFilesystemDurability()
        return JazzArchiveFilesystemDurability(
            synchronizeRegularFile: { [self] file, permissions in
                lock.lock()
                recordedEvents.append(
                    .file(file.standardizedFileURL.path, permissions))
                lock.unlock()
                try system.synchronizeRegularFile(
                    file,
                    permissions: permissions)
            },
            synchronizeDirectory: { [self] directory in
                let path = directory.standardizedFileURL.path
                lock.lock()
                recordedEvents.append(.directory(path))
                let shouldFail = path == failureDirectoryPath && !didFail
                if shouldFail { didFail = true }
                lock.unlock()
                if shouldFail {
                    throw JazzArchiveServerDownloadError.operationJournalWriteFailed
                }
                try system.synchronizeDirectory(directory)
            })
    }

    func events() -> [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private actor FakeArchiveServerDownloadTransport: JazzArchiveServerDownloadTransport {
    nonisolated let routeBinding: JazzArchiveUploadRouteBinding
    private let grant: JazzArchiveServerDownloadGrant
    private let bytes: Data
    private let chunkSize: Int
    private let authorizationFailure: JazzArchiveServerDownloadError?
    private let requiredJournalURLAtAuthorization: URL?
    private let authorizationDelayNanoseconds: UInt64
    private var authorizeCount = 0
    private var bodyCount = 0
    private var operationIds: [String] = []
    private var observedJournalAtAuthorization: Bool?

    init(
        grant: JazzArchiveServerDownloadGrant,
        bytes: Data,
        chunkSize: Int,
        authorityBinding: String = "https://jazz.invalid/api/archive-ingests",
        routeBinding: JazzArchiveUploadRouteBinding? = nil,
        authorizationFailure: JazzArchiveServerDownloadError? = nil,
        requiredJournalURLAtAuthorization: URL? = nil,
        authorizationDelayNanoseconds: UInt64 = 0
    ) {
        self.routeBinding =
            routeBinding
            ?? testServerDownloadRoute(
                endpoint: authorityBinding,
                scope: JazzArchiveServerScope(
                    companyId: grant.requestedBy.companyId,
                    areaId: grant.requestedBy.areaId,
                    deviceId: grant.requestedBy.deviceId))
        self.grant = grant
        self.bytes = bytes
        self.chunkSize = chunkSize
        self.authorizationFailure = authorizationFailure
        self.requiredJournalURLAtAuthorization = requiredJournalURLAtAuthorization
        self.authorizationDelayNanoseconds = authorizationDelayNanoseconds
    }

    func authorizationCalls() -> Int { authorizeCount }
    func bodyCalls() -> Int { bodyCount }
    func authorizedOperationIds() -> [String] { operationIds }
    func journalWasPresentAtAuthorization() -> Bool? {
        observedJournalAtAuthorization
    }

    func authorize(
        _ request: JazzArchiveServerDownloadRequest
    ) async throws -> JazzArchiveServerDownloadGrant {
        authorizeCount += 1
        operationIds.append(request.downloadOperationId)
        if let requiredJournalURLAtAuthorization {
            let journalData = try? Data(contentsOf: requiredJournalURLAtAuthorization)
            observedJournalAtAuthorization =
                journalData.map {
                String(decoding: $0, as: UTF8.self)
                    .contains(request.downloadOperationId)
            } ?? false
            guard observedJournalAtAuthorization == true else {
                throw JazzArchiveServerDownloadError.operationJournalWriteFailed
            }
        }
        if authorizationDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: authorizationDelayNanoseconds)
        }
        if let authorizationFailure { throw authorizationFailure }
        return grant
    }

    func openBody(
        for grant: JazzArchiveServerDownloadGrant
    ) async throws -> any JazzArchiveServerDownloadBody {
        bodyCount += 1
        return FakeArchiveServerDownloadBody(bytes: bytes, chunkSize: chunkSize)
    }
}

private func testServerDownloadRoute(
    endpoint: String = "https://jazz.invalid/api/archive-ingests",
    scope: JazzArchiveServerScope,
    issuer: String = "https://issuer.invalid",
    audience: String = "jazz-desktop",
    projectId: String = "123",
    stackURL: String = "https://connection.example.keboola.com",
    tokenId: String = "456",
    bundleId: String = "jdb_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    generation: Int = 1,
    envelopeDigest: String = String(repeating: "b", count: 64)
) -> JazzArchiveUploadRouteBinding {
    try! JazzArchiveUploadRouteBinding(
        ingestEndpoint: endpoint,
        stackURL: stackURL,
        projectId: projectId,
        tokenId: tokenId,
        scope: JazzArchiveUploadScope(
            companyId: scope.companyId,
            areaId: scope.areaId,
            deviceId: scope.deviceId),
        signedAuthority: JazzArchiveSignedEnrollmentAuthority(
            issuer: issuer,
            audience: audience,
            bundleId: bundleId,
            generation: generation,
            envelopeDigest: envelopeDigest))
}

private actor FakeArchiveServerDownloadBody: JazzArchiveServerDownloadBody {
    private let bytes: Data
    private let chunkSize: Int
    private var offset = 0

    init(bytes: Data, chunkSize: Int) {
        self.bytes = bytes
        self.chunkSize = max(1, chunkSize)
    }

    func nextChunk() async throws -> Data? {
        guard offset < bytes.count else { return nil }
        let end = min(bytes.count, offset + chunkSize)
        defer { offset = end }
        return bytes.subdata(in: offset..<end)
    }
}

extension Data {
    fileprivate mutating func appendTestLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    fileprivate func testU16(_ offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    fileprivate func testU32(_ offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }

    fileprivate mutating func setTestU16(_ offset: Int, _ value: UInt16) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    fileprivate mutating func setTestU32(_ offset: Int, _ value: UInt32) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
