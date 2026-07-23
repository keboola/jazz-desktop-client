import Foundation
import XCTest

@testable import JasnostCaptureCore

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
        XCTAssertEqual(first.provenance.packageId,
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
        XCTAssertTrue(first.snapshot.inventory.entries.contains {
            $0.path.hasSuffix("/records.ndjson")
        })
        XCTAssertFalse(first.snapshot.inventory.entries.contains {
            $0.path.contains("/records/")
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedRoot
            .appendingPathComponent("\(fixture.archiveId).jazz-archive.draft").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedRoot
            .appendingPathComponent(
                "\(fixture.archiveId).jazz-archive.finalized", isDirectory: true).path))

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
            root: importedRoot).build(
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
            acquisition: .jazzServerDownload)
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
                .unsafe),
            (
                "exact duplicate",
                standardEntries(extra: [
                    TestZIPEntry(name: "same.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "same.json", data: Data("{}".utf8)),
                ]),
                .duplicate),
            (
                "case alias",
                standardEntries(extra: [
                    TestZIPEntry(name: "A.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "a.json", data: Data("{}".utf8)),
                ]),
                .duplicate),
            (
                "NFC alias",
                standardEntries(extra: [
                    TestZIPEntry(name: "café.json", data: Data("{}".utf8)),
                    TestZIPEntry(name: "cafe\u{301}.json", data: Data("{}".utf8)),
                ]),
                .unsafe),
            (
                "symlink",
                standardEntries(extra: [
                    TestZIPEntry(
                        name: "link.json",
                        data: Data("target".utf8),
                        externalAttributes: UInt32(0o120777 << 16))
                ]),
                .unsupported),
        ]

        for (name, entries, expected) in cases {
            let root = temporaryRoot("malicious-\(name)")
            defer { removeTemporaryTree(root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let package = root.appendingPathComponent("attack.jazz-archive")
            try makeStoredZIP(entries).write(to: package)
            do {
                _ = try await JazzArchiveImporter(
                    root: root.appendingPathComponent("library")).importArchive(at: package)
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
                root: root.appendingPathComponent("library")).importArchive(at: package)
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
                    root: root.appendingPathComponent("library")).importArchive(at: package)
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedRoot
            .appendingPathComponent(
                "\(fixture.archiveId).jazz-archive.finalized", isDirectory: true).path))
    }

    func testRejectsEntryCountBeforeExtraction() async throws {
        let root = temporaryRoot("limit")
        defer { removeTemporaryTree(root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("too-many.jazz-archive")
        try makeStoredZIP(standardEntries(extra: [
            TestZIPEntry(name: "third.json", data: Data("{}".utf8))
        ])).write(to: package)
        let limits = JazzArchiveImportLimits(maxEntries: 2)

        do {
            _ = try await JazzArchiveImporter(
                root: root.appendingPathComponent("library"),
                limits: limits).importArchive(at: package)
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
        XCTAssertEqual(try result.snapshot.records(captureId: captureId).count, 6)
        XCTAssertEqual(try result.snapshot.labels(captureId: captureId).count, 1)
        XCTAssertEqual(try result.snapshot.artifacts(captureId: captureId).count, 1)
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
            root: libraryRoot).build(
                archiveId: archiveId,
                captureId: captureId)
        XCTAssertEqual(playback.captureId, captureId)
        XCTAssertTrue(playback.entries.contains {
            $0.artifact?.artifactId == artifactId
        })

        let spoolRoot = importedRoot.appendingPathComponent(
            "event-spool", isDirectory: true)
        try FileManager.default.createDirectory(
            at: spoolRoot, withIntermediateDirectories: true)
        let summaries = await JazzArchiveLocalIndex(
            root: libraryRoot,
            eventSpool: EventSpool(root: spoolRoot)).sessions()
        XCTAssertTrue(summaries.first?.labels.contains(
            "Book the monthly orders") == true)
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
            ingestId: "ingest-ready-1", scope: scope)
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "209fe827aa292e683e5fd510f3d8db9b0489a6c780d6a6009ab4b29d1f0931cb",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count),
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
                "transport": .string("test-direct-download"),
                "method": .string("GET"),
                "url": .string("https://download.invalid/opaque-token"),
                "futureProviderField": .object(["kept": .bool(true)]),
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
        XCTAssertEqual(try Data(contentsOf: result.packageURL), bytes)
        let authorizationCalls = await transport.authorizationCalls()
        let bodyCalls = await transport.bodyCalls()
        XCTAssertEqual(authorizationCalls, 1)
        XCTAssertEqual(bodyCalls, 1)
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
            ingestId: "ingest-ready-mismatch", scope: scope)
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "209fe827aa292e683e5fd510f3d8db9b0489a6c780d6a6009ab4b29d1f0931cb",
            rawSha256: String(repeating: "0", count: 64),
            byteLength: Int64(bytes.count),
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
                "transport": .string("test-direct-download"),
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
            ingestId: "ingest-ready-length-mismatch", scope: scope)
        let grant = JazzArchiveServerDownloadGrant(
            ingestId: request.ingestId,
            archiveId: "ar-22222222-2222-7222-8222-222222222222",
            formatVersion: 1,
            contentDigest:
                "209fe827aa292e683e5fd510f3d8db9b0489a6c780d6a6009ab4b29d1f0931cb",
            rawSha256: JazzArchiveDigest.sha256Hex(bytes),
            byteLength: Int64(bytes.count) + 1,
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
                "transport": .string("test-direct-download"),
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
                recordCount: 2,
                labelCount: 0,
                artifactCount: 0
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
                recordCount: 5,
                labelCount: 0,
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
            try makeStoredZIP(try regularFixtureEntries(
                at: fixtureRoot,
                excludingTopLevelDirectories: ["sync"])).write(to: packageURL)

            let result = try await importer.importArchive(at: packageURL)

            XCTAssertEqual(result.snapshot.manifest.archiveId, fixture.archiveId)
            XCTAssertEqual(
                try result.snapshot.records(captureId: fixture.captureId).count,
                fixture.recordCount)
            XCTAssertEqual(
                try result.snapshot.labels(captureId: fixture.captureId).count,
                fixture.labelCount)
            XCTAssertEqual(
                try result.snapshot.artifacts(captureId: fixture.captureId).count,
                fixture.artifactCount)
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
            actors: [JazzArchiveActor(
                actorId: actorId,
                kind: .human,
                identityStatus: .identified,
                displayName: "Recorder",
                provenance: JazzArchiveProvenance(factClass: .declared, sources: []))],
            sources: [JazzArchiveSource(
                sourceId: sourceId,
                kind: "macos.capture-controller",
                actorId: actorId,
                producer: producer,
                provenance: JazzArchiveProvenance(factClass: .observed, sources: []))],
            sessions: [JazzArchiveSessionRef(
                captureId: captureId,
                legacySessionId: sessionId)])
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

        let artifactBytes = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
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
            actorRefs: [JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                method: "test")],
            captureInterval: JazzArchiveArtifactCaptureInterval(startedAt: startedAt),
            provenance: JazzArchiveProvenance(factClass: .observed, sources: [sourceId]),
            quality: JazzArchiveQuality(status: .complete),
            privacy: JazzArchivePrivacy(status: .captured, policyVersion: "test-consent"))
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
            actorRefs: [JazzArchiveActorRef(
                actorId: actorId,
                role: "performer",
                basis: .observed,
                method: "test")],
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
            entries.append(TestZIPEntry(
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
                value = (value & 1) == 1
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

private actor FakeArchiveServerDownloadTransport: JazzArchiveServerDownloadTransport {
    private let grant: JazzArchiveServerDownloadGrant
    private let bytes: Data
    private let chunkSize: Int
    private var authorizeCount = 0
    private var bodyCount = 0

    init(grant: JazzArchiveServerDownloadGrant, bytes: Data, chunkSize: Int) {
        self.grant = grant
        self.bytes = bytes
        self.chunkSize = chunkSize
    }

    func authorizationCalls() -> Int { authorizeCount }
    func bodyCalls() -> Int { bodyCount }

    func authorize(
        _ request: JazzArchiveServerDownloadRequest
    ) async throws -> JazzArchiveServerDownloadGrant {
        authorizeCount += 1
        return grant
    }

    func openBody(
        for grant: JazzArchiveServerDownloadGrant
    ) async throws -> any JazzArchiveServerDownloadBody {
        bodyCount += 1
        return FakeArchiveServerDownloadBody(bytes: bytes, chunkSize: chunkSize)
    }
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

private extension Data {
    mutating func appendTestLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func testU16(_ offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func testU32(_ offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }

    mutating func setTestU16(_ offset: Int, _ value: UInt16) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    mutating func setTestU32(_ offset: Int, _ value: UInt32) {
        self[offset] = UInt8(truncatingIfNeeded: value)
        self[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        self[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        self[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
