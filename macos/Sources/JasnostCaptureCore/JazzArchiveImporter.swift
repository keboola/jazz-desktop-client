import Foundation

public enum JazzArchiveImportAcquisition: String, Codable, Equatable, Sendable {
    case userSelectedFile = "user_selected_file"
    case jazzServerDownload = "jazz_server_download"
}

/// Non-canonical identity of the person and installation performing a local import. This is an
/// acquisition receipt only; it must never be copied into the immutable captured-by manifest.
public struct JazzArchiveImportContext: Equatable, Sendable {
    public let importedBy: JazzArchiveExternalIdentity?
    public let importingOriginId: String?
    public let importingSourceId: String?
    public let importingDevice: JazzArchiveExternalIdentity?
    public let acquisition: JazzArchiveImportAcquisition

    public init(
        importedBy: JazzArchiveExternalIdentity? = nil,
        importingOriginId: String? = nil,
        importingSourceId: String? = nil,
        importingDevice: JazzArchiveExternalIdentity? = nil,
        acquisition: JazzArchiveImportAcquisition = .userSelectedFile
    ) {
        self.importedBy = importedBy
        self.importingOriginId = importingOriginId
        self.importingSourceId = importingSourceId
        self.importingDevice = importingDevice
        self.acquisition = acquisition
    }
}

/// One append-only local acquisition fact. Re-importing the same exact package creates another
/// receipt instead of replacing the original importer attribution.
public struct JazzArchiveImportReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let receiptId: String
    public let packageId: String
    public let archiveId: String
    public let packageSHA256: String
    public let packageByteLength: Int64
    public let importedAt: String
    public let importedBy: JazzArchiveExternalIdentity?
    public let importingOriginId: String?
    public let importingSourceId: String?
    public let importingDevice: JazzArchiveExternalIdentity?
    public let acquisition: JazzArchiveImportAcquisition
    public let originalFileName: String?

    fileprivate init(
        identity: JazzArchivePackageIdentityDocument,
        receiptId: String,
        importedAt: String,
        context: JazzArchiveImportContext,
        originalFileName: String?
    ) {
        self.schemaVersion = 1
        self.receiptId = receiptId
        self.packageId = identity.packageId
        self.archiveId = identity.archiveId
        self.packageSHA256 = identity.packageSHA256
        self.packageByteLength = identity.packageByteLength
        self.importedAt = importedAt
        self.importedBy = context.importedBy
        self.importingOriginId = context.importingOriginId
        self.importingSourceId = context.importingSourceId
        self.importingDevice = context.importingDevice
        self.acquisition = context.acquisition
        self.originalFileName = originalFileName
    }

    fileprivate func validate(identity: JazzArchivePackageIdentityDocument) throws {
        guard schemaVersion == 1,
            Self.isUUIDv7(receiptId, prefix: "imr"),
            packageId == identity.packageId,
            archiveId == identity.archiveId,
            packageSHA256 == identity.packageSHA256,
            packageByteLength == identity.packageByteLength,
            Timestamps.parse(importedAt) != nil
        else { throw JazzArchiveImportError.invalidArchive("import receipt") }
        try Self.validateExternalIdentity(importedBy, field: "importedBy")
        try Self.validateExternalIdentity(importingDevice, field: "importingDevice")
        if let importingOriginId {
            guard Self.isUUIDv7(importingOriginId, prefix: "origin") else {
                throw JazzArchiveImportError.invalidArchive("importingOriginId")
            }
        }
        if let importingSourceId {
            guard Self.isUUIDv7(importingSourceId, prefix: "src") else {
                throw JazzArchiveImportError.invalidArchive("importingSourceId")
            }
        }
        if let originalFileName {
            guard !originalFileName.isEmpty,
                originalFileName.utf8.count <= 1_024,
                !originalFileName.contains("/"), !originalFileName.contains("\\")
            else { throw JazzArchiveImportError.invalidArchive("originalFileName") }
        }
    }

    private static func validateExternalIdentity(
        _ identity: JazzArchiveExternalIdentity?,
        field: String
    ) throws {
        guard let identity else { return }
        let namespace = identity.namespace.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let value = identity.value.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard !namespace.isEmpty, namespace.utf8.count <= 128,
            !value.isEmpty, value.utf8.count <= 4_096
        else { throw JazzArchiveImportError.invalidArchive(field) }
    }

    fileprivate static func isUUIDv7(_ value: String, prefix: String) -> Bool {
        let marker = "\(prefix)-"
        guard value.hasPrefix(marker) else { return false }
        let raw = String(value.dropFirst(marker.count))
        guard let uuid = UUID(uuidString: raw),
            uuid.uuidString.lowercased() == raw
        else { return false }
        let characters = Array(raw)
        return characters.count == 36
            && characters[14] == "7"
            && "89ab".contains(characters[19])
    }
}

/// Stable package identity plus append-only, non-canonical import receipts.
public struct JazzArchivePackageProvenance: Equatable, Sendable {
    public let schemaVersion: Int
    public let packageId: String
    public let archiveId: String
    public let contentDigest: String
    public let packageSHA256: String
    public let packageByteLength: Int64
    public let receipts: [JazzArchiveImportReceipt]

    fileprivate init(
        identity: JazzArchivePackageIdentityDocument,
        receipts: [JazzArchiveImportReceipt]
    ) {
        self.schemaVersion = identity.schemaVersion
        self.packageId = identity.packageId
        self.archiveId = identity.archiveId
        self.contentDigest = identity.contentDigest
        self.packageSHA256 = identity.packageSHA256
        self.packageByteLength = identity.packageByteLength
        self.receipts = receipts
    }

    public var packageFingerprint: JazzArchiveFileFingerprint {
        JazzArchiveFileFingerprint(
            sha256: packageSHA256, byteLength: packageByteLength)
    }

    public static func packageId(sha256: String) -> String {
        "jap-sha256-\(sha256)"
    }

    public var importedAt: String { receipts[0].importedAt }
    public var importedBy: JazzArchiveExternalIdentity? { receipts[0].importedBy }
    public var importingOriginId: String? { receipts[0].importingOriginId }
    public var importingSourceId: String? { receipts[0].importingSourceId }
    public var importingDevice: JazzArchiveExternalIdentity? { receipts[0].importingDevice }
    public var acquisition: JazzArchiveImportAcquisition { receipts[0].acquisition }
    public var originalFileName: String? { receipts[0].originalFileName }
}

fileprivate struct JazzArchivePackageIdentityDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let packageId: String
    let archiveId: String
    let contentDigest: String
    let packageSHA256: String
    let packageByteLength: Int64
    let initialReceiptId: String

    init(
        archiveId: String,
        contentDigest: String,
        packageFingerprint: JazzArchiveFileFingerprint,
        initialReceiptId: String
    ) {
        self.schemaVersion = 1
        self.packageId = JazzArchivePackageProvenance.packageId(
            sha256: packageFingerprint.sha256)
        self.archiveId = archiveId
        self.contentDigest = contentDigest
        self.packageSHA256 = packageFingerprint.sha256
        self.packageByteLength = packageFingerprint.byteLength
        self.initialReceiptId = initialReceiptId
    }

    var packageFingerprint: JazzArchiveFileFingerprint {
        JazzArchiveFileFingerprint(
            sha256: packageSHA256, byteLength: packageByteLength)
    }

    func validate(manifest: JazzArchiveManifest) throws {
        guard schemaVersion == 1,
            packageId == JazzArchivePackageProvenance.packageId(sha256: packageSHA256),
            archiveId == manifest.archiveId,
            contentDigest == manifest.contentDigest,
            packageByteLength > 0,
            packageSHA256.count == 64,
            packageSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
            JazzArchiveImportReceipt.isUUIDv7(initialReceiptId, prefix: "imr")
        else { throw JazzArchiveImportError.invalidArchive("package provenance") }
    }
}

public enum JazzArchiveImportDisposition: String, Codable, Equatable, Sendable {
    case imported
    case alreadyPresent
}

public struct JazzArchiveImportResult: Sendable {
    public let disposition: JazzArchiveImportDisposition
    public let snapshot: JazzArchiveFinalizedSnapshot
    public let provenance: JazzArchivePackageProvenance
    public let packageURL: URL
}

/// Trust boundary for cross-user `.jazz-archive` files. The source is copied and fingerprinted
/// before parsing; the exact package and its non-canonical provenance are durably published before
/// one final rename makes the verified immutable snapshot visible to LocalIndex.
public actor JazzArchiveImporter {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private let limits: JazzArchiveImportLimits

    public init(
        root: URL,
        fileManager: FileManager = .default,
        limits: JazzArchiveImportLimits = JazzArchiveImportLimits()
    ) {
        self.root = root
        self.fileManager = fileManager
        self.limits = limits
    }

    public func importArchive(
        at sourceURL: URL,
        importedAt: String = Timestamps.iso8601(),
        context: JazzArchiveImportContext = JazzArchiveImportContext(),
        expectedPackageFingerprint: JazzArchiveFileFingerprint? = nil,
        expectedArchiveId: String? = nil,
        expectedContentDigest: String? = nil
    ) throws -> JazzArchiveImportResult {
        try limits.validate()
        guard Timestamps.parse(importedAt) != nil else {
            throw JazzArchiveImportError.invalidArchive("importedAt")
        }
        let sourceValues: URLResourceValues
        do {
            sourceValues = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw JazzArchiveImportError.sourceNotRegularFile
        }
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true,
            let sourceSize = sourceValues.fileSize, sourceSize > 0
        else {
            throw JazzArchiveImportError.sourceNotRegularFile
        }
        guard Int64(sourceSize) <= limits.maxArchiveBytes else {
            throw JazzArchiveImportError.archiveTooLarge
        }

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let staging = root.appendingPathComponent(
            ".archive-import-\(Identifiers.newUUIDv7().uuidString.lowercased())",
            isDirectory: true)
        try fileManager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        var keepStaging = true
        defer {
            if keepStaging {
                makeWritableForRemoval(staging)
                try? fileManager.removeItem(at: staging)
            }
        }

        let packageCopy = staging.appendingPathComponent("package.jazz-archive")
        let copiedFingerprint = try copySelectedPackage(
            sourceURL, to: packageCopy, maximumBytes: limits.maxArchiveBytes)
        if let expectedPackageFingerprint, copiedFingerprint != expectedPackageFingerprint {
            throw JazzArchiveImportError.integrityMismatch(
                "download grant package fingerprint")
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o400))],
            ofItemAtPath: packageCopy.path)

        let snapshotStage = staging.appendingPathComponent("snapshot", isDirectory: true)
        try fileManager.createDirectory(
            at: snapshotStage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let extractedFingerprints = try DeterministicJazzArchiveZIP32Reader(
            packageURL: packageCopy,
            limits: limits,
            fileManager: fileManager
        ).extract(to: snapshotStage)
        guard try JazzArchiveFileIO.fingerprint(packageCopy) == copiedFingerprint else {
            throw JazzArchiveImportError.integrityMismatch("package changed during verification")
        }

        let snapshot = try JazzArchiveSnapshotVerifier.verify(
            directory: snapshotStage,
            expectedArchiveId: nil,
            limits: limits,
            fileManager: fileManager)
        guard snapshot.fileFingerprints == extractedFingerprints,
            let contentDigest = snapshot.manifest.contentDigest
        else { throw JazzArchiveImportError.integrityMismatch("extracted snapshot") }
        if let expectedArchiveId, snapshot.manifest.archiveId != expectedArchiveId {
            throw JazzArchiveImportError.integrityMismatch("download grant archiveId")
        }
        if let expectedContentDigest, contentDigest != expectedContentDigest {
            throw JazzArchiveImportError.integrityMismatch("download grant contentDigest")
        }

        let archiveId = snapshot.manifest.archiveId
        let finalized = finalizedDirectory(archiveId)
        let draft = draftDirectory(archiveId)
        if fileManager.fileExists(atPath: draft.path),
            !fileManager.fileExists(atPath: finalized.path)
        {
            throw JazzArchiveImportError.archiveConflict(archiveId)
        }

        var existingSnapshot: JazzArchiveFinalizedSnapshot?
        if fileManager.fileExists(atPath: finalized.path) {
            existingSnapshot = try JazzArchiveSnapshotVerifier.verify(
                directory: finalized,
                expectedArchiveId: archiveId,
                limits: limits,
                fileManager: fileManager)
            guard existingSnapshot?.manifest.contentDigest == contentDigest,
                existingSnapshot?.fileFingerprints == snapshot.fileFingerprints
            else { throw JazzArchiveImportError.archiveConflict(archiveId) }
        }

        let receiptId = Identifiers.newImportReceiptId()
        let identity = JazzArchivePackageIdentityDocument(
            archiveId: archiveId,
            contentDigest: contentDigest,
            packageFingerprint: copiedFingerprint,
            initialReceiptId: receiptId)
        try identity.validate(manifest: snapshot.manifest)
        let receipt = JazzArchiveImportReceipt(
            identity: identity,
            receiptId: receiptId,
            importedAt: importedAt,
            context: context,
            originalFileName: sourceURL.lastPathComponent)
        try receipt.validate(identity: identity)

        let packageStage = staging.appendingPathComponent("package-store", isDirectory: true)
        try fileManager.createDirectory(
            at: packageStage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let stagedPackage = packageStage.appendingPathComponent("package.jazz-archive")
        try fileManager.moveItem(at: packageCopy, to: stagedPackage)
        let identityData = try JazzArchiveCanonicalJSON.encode(identity)
        guard identityData.count <= 1_048_576 else {
            throw JazzArchiveImportError.entryLimitExceeded("package provenance")
        }
        try identityData.write(
            to: packageStage.appendingPathComponent("provenance.json"),
            options: .atomic)
        let stagedReceipts = packageStage.appendingPathComponent(
            "receipts", isDirectory: true)
        try fileManager.createDirectory(
            at: stagedReceipts,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let receiptData = try JazzArchiveCanonicalJSON.encode(receipt)
        guard receiptData.count <= 1_048_576 else {
            throw JazzArchiveImportError.entryLimitExceeded("import receipt")
        }
        try receiptData.write(
            to: stagedReceipts.appendingPathComponent("\(receipt.receiptId).json"),
            options: .atomic)

        let packageDestination = packageDirectory(archiveId)
        let storedProvenance = try publishPackage(
            staging: packageStage,
            destination: packageDestination,
            expected: identity,
            receipt: receipt,
            manifest: snapshot.manifest)

        let disposition: JazzArchiveImportDisposition
        let publishedSnapshot: JazzArchiveFinalizedSnapshot
        if let existingSnapshot {
            try makeImmutable(finalized)
            disposition = .alreadyPresent
            publishedSnapshot = existingSnapshot
        } else {
            do {
                try fileManager.moveItem(at: snapshotStage, to: finalized)
            } catch {
                guard fileManager.fileExists(atPath: finalized.path) else {
                    throw JazzArchiveImportError.publishFailed(
                        "snapshot \(archiveId): \(error)")
                }
                let concurrent = try JazzArchiveSnapshotVerifier.verify(
                    directory: finalized,
                    expectedArchiveId: archiveId,
                    limits: limits,
                    fileManager: fileManager)
                guard concurrent.manifest.contentDigest == contentDigest,
                    concurrent.fileFingerprints == snapshot.fileFingerprints
                else { throw JazzArchiveImportError.archiveConflict(archiveId) }
            }
            try makeImmutable(finalized)
            disposition = .imported
            publishedSnapshot = try JazzArchiveSnapshotVerifier.verify(
                directory: finalized,
                expectedArchiveId: archiveId,
                limits: limits,
                fileManager: fileManager)
        }

        keepStaging = false
        makeWritableForRemoval(staging)
        try? fileManager.removeItem(at: staging)
        return JazzArchiveImportResult(
            disposition: disposition,
            snapshot: publishedSnapshot,
            provenance: storedProvenance,
            packageURL: packageDestination.appendingPathComponent("package.jazz-archive"))
    }

    public func provenance(archiveId: String) throws -> JazzArchivePackageProvenance? {
        let directory = packageDirectory(archiveId)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        let manifest = try JazzArchiveSnapshotVerifier.verify(
            directory: finalizedDirectory(archiveId),
            expectedArchiveId: archiveId,
            limits: limits,
            fileManager: fileManager).manifest
        return try verifyPackageDirectory(directory, manifest: manifest)
    }

    private func publishPackage(
        staging: URL,
        destination: URL,
        expected: JazzArchivePackageIdentityDocument,
        receipt: JazzArchiveImportReceipt,
        manifest: JazzArchiveManifest
    ) throws -> JazzArchivePackageProvenance {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        if fileManager.fileExists(atPath: destination.path) {
            let stored = try verifyPackageDirectory(destination, manifest: manifest)
            guard packageIdentity(stored, matches: expected) else {
                throw JazzArchiveImportError.archiveConflict(expected.archiveId)
            }
            try appendReceipt(
                from: stagedReceiptURL(staging, receiptId: receipt.receiptId),
                receipt: receipt,
                to: destination)
            return try verifyPackageDirectory(destination, manifest: manifest)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            guard fileManager.fileExists(atPath: destination.path) else {
                throw JazzArchiveImportError.publishFailed(
                    "package \(expected.archiveId): \(error)")
            }
            let stored = try verifyPackageDirectory(destination, manifest: manifest)
            guard packageIdentity(stored, matches: expected) else {
                throw JazzArchiveImportError.archiveConflict(expected.archiveId)
            }
            try appendReceipt(
                from: stagedReceiptURL(staging, receiptId: receipt.receiptId),
                receipt: receipt,
                to: destination)
            return try verifyPackageDirectory(destination, manifest: manifest)
        }
        try makeImmutable(destination)
        return try verifyPackageDirectory(destination, manifest: manifest)
    }

    private func verifyPackageDirectory(
        _ directory: URL,
        manifest: JazzArchiveManifest
    ) throws -> JazzArchivePackageProvenance {
        let values = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
        }
        let expectedNames = Set(["package.jazz-archive", "provenance.json", "receipts"])
        let names = try Set(fileManager.contentsOfDirectory(atPath: directory.path))
        guard names == expectedNames else {
            throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
        }
        let packageURL = directory.appendingPathComponent("package.jazz-archive")
        let provenanceURL = directory.appendingPathComponent("provenance.json")
        for url in [packageURL, provenanceURL] {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
            }
        }
        let data = try Data(contentsOf: provenanceURL)
        let identity = try JSONDecoder().decode(
            JazzArchivePackageIdentityDocument.self, from: data)
        guard try JazzArchiveCanonicalJSON.encode(identity) == data else {
            throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
        }
        try identity.validate(manifest: manifest)
        guard try JazzArchiveFileIO.fingerprint(packageURL)
            == identity.packageFingerprint
        else { throw JazzArchiveImportError.archiveConflict(manifest.archiveId) }

        let receiptsURL = directory.appendingPathComponent("receipts", isDirectory: true)
        let receiptDirectoryValues = try receiptsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard receiptDirectoryValues.isDirectory == true,
            receiptDirectoryValues.isSymbolicLink != true
        else { throw JazzArchiveImportError.archiveConflict(manifest.archiveId) }
        let receiptURLs = try fileManager.contentsOfDirectory(
            at: receiptsURL,
            includingPropertiesForKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ],
            options: [])
        guard !receiptURLs.isEmpty, receiptURLs.count <= limits.maxEntries else {
            throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
        }
        var receipts: [JazzArchiveImportReceipt] = []
        for url in receiptURLs {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard url.pathExtension == "json",
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                Int64(values.fileSize ?? Int.max)
                    <= min(1_048_576, limits.maxJSONEntryBytes)
            else { throw JazzArchiveImportError.archiveConflict(manifest.archiveId) }
            let receiptData = try Data(contentsOf: url)
            let receipt = try JSONDecoder().decode(
                JazzArchiveImportReceipt.self, from: receiptData)
            guard url.deletingPathExtension().lastPathComponent == receipt.receiptId,
                try JazzArchiveCanonicalJSON.encode(receipt) == receiptData
            else { throw JazzArchiveImportError.archiveConflict(manifest.archiveId) }
            try receipt.validate(identity: identity)
            receipts.append(receipt)
        }
        guard Set(receipts.map(\.receiptId)).count == receipts.count else {
            throw JazzArchiveImportError.archiveConflict(manifest.archiveId)
        }
        guard let initial = receipts.first(where: {
            $0.receiptId == identity.initialReceiptId
        }) else { throw JazzArchiveImportError.archiveConflict(manifest.archiveId) }
        let ordered = [initial] + receipts.filter {
            $0.receiptId != identity.initialReceiptId
        }.sorted { $0.receiptId < $1.receiptId }
        return JazzArchivePackageProvenance(identity: identity, receipts: ordered)
    }

    private func appendReceipt(
        from source: URL,
        receipt: JazzArchiveImportReceipt,
        to packageDirectory: URL
    ) throws {
        let receipts = packageDirectory.appendingPathComponent("receipts", isDirectory: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: receipts.path)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o500))],
                ofItemAtPath: receipts.path)
        }
        let destination = receipts.appendingPathComponent("\(receipt.receiptId).json")
        let expectedData = try JazzArchiveCanonicalJSON.encode(receipt)
        if fileManager.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == expectedData else {
                throw JazzArchiveImportError.archiveConflict(receipt.archiveId)
            }
            return
        }
        do {
            try fileManager.linkItem(at: source, to: destination)
        } catch {
            guard fileManager.fileExists(atPath: destination.path),
                try Data(contentsOf: destination) == expectedData
            else {
                throw JazzArchiveImportError.publishFailed(
                    "receipt \(receipt.receiptId): \(error)")
            }
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o400))],
            ofItemAtPath: destination.path)
    }

    private func stagedReceiptURL(_ staging: URL, receiptId: String) -> URL {
        staging.appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent("\(receiptId).json")
    }

    private func packageIdentity(
        _ provenance: JazzArchivePackageProvenance,
        matches identity: JazzArchivePackageIdentityDocument
    ) -> Bool {
        provenance.packageId == identity.packageId
            && provenance.archiveId == identity.archiveId
            && provenance.contentDigest == identity.contentDigest
            && provenance.packageFingerprint == identity.packageFingerprint
    }

    private func copySelectedPackage(
        _ source: URL,
        to destination: URL,
        maximumBytes: Int64
    ) throws -> JazzArchiveFileFingerprint {
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        else { throw JazzArchiveImportError.publishFailed("package staging file") }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hasher = JazzArchiveSHA256()
        var byteLength: Int64 = 0
        do {
            while true {
                let chunk = try input.read(
                    upToCount: JazzArchiveFileIO.chunkSize) ?? Data()
                if chunk.isEmpty { break }
                let (nextLength, overflow) = byteLength.addingReportingOverflow(
                    Int64(chunk.count))
                guard !overflow, nextLength <= maximumBytes else {
                    throw JazzArchiveImportError.archiveTooLarge
                }
                byteLength = nextLength
                hasher.update(chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        guard byteLength > 0 else {
            throw JazzArchiveImportError.sourceNotRegularFile
        }
        return JazzArchiveFileFingerprint(
            sha256: hasher.finalizeHex(), byteLength: byteLength)
    }

    private func makeImmutable(_ directory: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false })
        else { throw JazzArchiveImportError.publishFailed(directory.lastPathComponent) }
        var directories: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw JazzArchiveImportError.unsafeEntry(url.lastPathComponent)
            }
            if values.isDirectory == true {
                directories.append(url)
            } else {
                try fileManager.setAttributes(
                    [.posixPermissions: NSNumber(value: Int16(0o400))],
                    ofItemAtPath: url.path)
            }
        }
        for url in directories.reversed() {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o500))],
                ofItemAtPath: url.path)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o500))],
            ofItemAtPath: directory.path)
    }

    private func makeWritableForRemoval(_ directory: URL) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [])
        else { return }
        var directories = [directory]
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
            }
        }
        for url in directories {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: url.path)
        }
    }

    private func finalizedDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent(
            "\(archiveId).jazz-archive.finalized", isDirectory: true)
    }

    private func draftDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent(
            "\(archiveId).jazz-archive.draft", isDirectory: true)
    }

    private func packageDirectory(_ archiveId: String) -> URL {
        root.appendingPathComponent(".archive-packages", isDirectory: true)
            .appendingPathComponent(archiveId, isDirectory: true)
    }
}

private struct DeterministicJazzArchiveZIP32Reader {
    private struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt32
        let localOffset: UInt32
    }

    private let packageURL: URL
    private let limits: JazzArchiveImportLimits
    private let fileManager: FileManager

    init(packageURL: URL, limits: JazzArchiveImportLimits, fileManager: FileManager) {
        self.packageURL = packageURL
        self.limits = limits
        self.fileManager = fileManager
    }

    func extract(to directory: URL) throws -> [String: JazzArchiveFileFingerprint] {
        let handle = try FileHandle(forReadingFrom: packageURL)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > 0, length <= UInt64(limits.maxArchiveBytes) else {
            throw JazzArchiveImportError.archiveTooLarge
        }
        let (entries, centralOffset) = try inspectCentralDirectory(
            handle: handle, length: length)

        var cursor: UInt64 = 0
        var fingerprints: [String: JazzArchiveFileFingerprint] = [:]
        for entry in entries {
            guard UInt64(entry.localOffset) == cursor else {
                throw JazzArchiveImportError.malformedZIP("non-contiguous local entries")
            }
            let header = try readExact(handle, offset: cursor, count: 30)
            guard header.u32(0) == 0x0403_4b50 else {
                throw JazzArchiveImportError.malformedZIP("local header signature")
            }
            try validateCommonHeader(
                version: header.u16(4),
                flags: header.u16(6),
                method: header.u16(8),
                modifiedTime: header.u16(10),
                modifiedDate: header.u16(12),
                crc32: header.u32(14),
                compressedSize: header.u32(18),
                expandedSize: header.u32(22),
                expected: entry,
                context: entry.name)
            let nameLength = Int(header.u16(26))
            let extraLength = header.u16(28)
            guard nameLength == entry.name.utf8.count, extraLength == 0 else {
                throw JazzArchiveImportError.unsupportedZIPFeature(
                    "local extra or filename mismatch")
            }
            let nameData = try readExact(handle, offset: cursor + 30, count: nameLength)
            guard String(data: nameData, encoding: .utf8) == entry.name else {
                throw JazzArchiveImportError.malformedZIP("local/central filename mismatch")
            }
            let dataOffset = try adding(cursor, UInt64(30 + nameLength))
            let dataEnd = try adding(dataOffset, UInt64(entry.size))
            guard dataEnd <= centralOffset else {
                throw JazzArchiveImportError.malformedZIP("entry overlaps central directory")
            }
            let target = directory.appendingPathComponent(entry.name)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            guard fileManager.createFile(
                atPath: target.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
            else { throw JazzArchiveImportError.duplicateEntry(entry.name) }
            let output = try FileHandle(forWritingTo: target)
            var hasher = JazzArchiveSHA256()
            var crc = JazzArchiveCRC32()
            var remaining = Int64(entry.size)
            do {
                try handle.seek(toOffset: dataOffset)
                while remaining > 0 {
                    let count = min(JazzArchiveFileIO.chunkSize, Int(remaining))
                    let chunk = try handle.read(upToCount: count) ?? Data()
                    guard chunk.count == count else {
                        throw JazzArchiveImportError.malformedZIP("truncated \(entry.name)")
                    }
                    try output.write(contentsOf: chunk)
                    hasher.update(chunk)
                    crc.update(chunk)
                    remaining -= Int64(chunk.count)
                }
                try output.synchronize()
                try output.close()
            } catch {
                try? output.close()
                throw error
            }
            guard crc.finalize() == entry.crc32 else {
                throw JazzArchiveImportError.integrityMismatch("CRC32 \(entry.name)")
            }
            let fingerprint = JazzArchiveFileFingerprint(
                sha256: hasher.finalizeHex(), byteLength: Int64(entry.size))
            fingerprints[entry.name] = fingerprint
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o400))],
                ofItemAtPath: target.path)
            cursor = dataEnd
        }
        guard cursor == centralOffset else {
            throw JazzArchiveImportError.malformedZIP("orphan local bytes")
        }
        return fingerprints
    }

    private func inspectCentralDirectory(
        handle: FileHandle,
        length: UInt64
    ) throws -> ([Entry], UInt64) {
        guard length >= 22 else {
            throw JazzArchiveImportError.malformedZIP("missing EOCD")
        }
        let eocd = try readExact(handle, offset: length - 22, count: 22)
        guard eocd.u32(0) == 0x0605_4b50 else {
            throw JazzArchiveImportError.malformedZIP("EOCD signature")
        }
        guard eocd.u16(4) == 0, eocd.u16(6) == 0,
            eocd.u16(8) == eocd.u16(10), eocd.u16(20) == 0
        else { throw JazzArchiveImportError.unsupportedZIPFeature("multi-disk or comment") }
        let count = Int(eocd.u16(10))
        let centralSize = eocd.u32(12)
        let centralOffset32 = eocd.u32(16)
        guard count < Int(UInt16.max),
            centralSize < UInt32.max, centralOffset32 < UInt32.max
        else { throw JazzArchiveImportError.unsupportedZIPFeature("ZIP64") }
        guard count <= limits.maxEntries else {
            throw JazzArchiveImportError.entryLimitExceeded("entry count")
        }
        let centralOffset = UInt64(centralOffset32)
        let centralEnd = try adding(centralOffset, UInt64(centralSize))
        guard centralEnd == length - 22 else {
            throw JazzArchiveImportError.malformedZIP("central directory boundary")
        }

        var cursor = centralOffset
        var entries: [Entry] = []
        var exactNames = Set<String>()
        var collisionKeys = Set<String>()
        var previousName: String?
        var total: Int64 = 0
        var structured: Int64 = 0
        for _ in 0..<count {
            guard try adding(cursor, 46) <= centralEnd else {
                throw JazzArchiveImportError.malformedZIP("truncated central header")
            }
            let header = try readExact(handle, offset: cursor, count: 46)
            guard header.u32(0) == 0x0201_4b50,
                header.u16(4) == 0x0314,
                header.u16(6) == 20,
                header.u16(8) == 0x0800,
                header.u16(10) == 0,
                header.u16(12) == 0,
                header.u16(14) == 0x0021
            else { throw JazzArchiveImportError.unsupportedZIPFeature("central header profile") }
            let crc32 = header.u32(16)
            let compressedSize = header.u32(20)
            let expandedSize = header.u32(24)
            let nameLength = Int(header.u16(28))
            let extraLength = header.u16(30)
            let commentLength = header.u16(32)
            let diskStart = header.u16(34)
            let internalAttributes = header.u16(36)
            let externalAttributes = header.u32(38)
            let localOffset = header.u32(42)
            guard compressedSize < UInt32.max, expandedSize < UInt32.max,
                localOffset < UInt32.max
            else { throw JazzArchiveImportError.unsupportedZIPFeature("ZIP64 sentinel") }
            guard compressedSize == expandedSize,
                Int64(expandedSize) <= limits.maxEntryBytes
            else { throw JazzArchiveImportError.entryLimitExceeded("entry bytes") }
            guard nameLength > 0, nameLength <= limits.maxPathBytes,
                extraLength == 0, commentLength == 0, diskStart == 0,
                internalAttributes == 0,
                externalAttributes == UInt32(0o100644 << 16)
            else {
                throw JazzArchiveImportError.unsupportedZIPFeature(
                    "entry metadata, extra, comment, or type")
            }
            let nameOffset = try adding(cursor, 46)
            let nameData = try readExact(handle, offset: nameOffset, count: nameLength)
            guard let name = String(data: nameData, encoding: .utf8),
                name.utf8.count == nameLength
            else { throw JazzArchiveImportError.unsafeEntry("invalid UTF-8") }
            try JazzArchivePortablePath.validate(name, maxBytes: limits.maxPathBytes)
            guard exactNames.insert(name).inserted else {
                throw JazzArchiveImportError.duplicateEntry(name)
            }
            let collision = JazzArchivePortablePath.collisionKey(name)
            guard collisionKeys.insert(collision).inserted else {
                throw JazzArchiveImportError.duplicateEntry(name)
            }
            if let previousName, !(previousName < name) {
                throw JazzArchiveImportError.malformedZIP("entry order")
            }
            previousName = name
            total = try boundedAdd(
                total, Int64(expandedSize), limit: limits.maxTotalExpandedBytes)
            if name.hasSuffix(".json") || name.hasSuffix(".ndjson") {
                structured = try boundedAdd(
                    structured,
                    Int64(expandedSize),
                    limit: limits.maxTotalStructuredBytes)
                if name.hasSuffix(".json"),
                    Int64(expandedSize) > limits.maxJSONEntryBytes
                {
                    throw JazzArchiveImportError.entryLimitExceeded(name)
                }
            }
            entries.append(Entry(
                name: name,
                crc32: crc32,
                size: expandedSize,
                localOffset: localOffset))
            cursor = try adding(nameOffset, UInt64(nameLength))
        }
        guard cursor == centralEnd else {
            throw JazzArchiveImportError.malformedZIP("central directory size")
        }
        guard Set(entries.map(\.name)).isSuperset(of: ["manifest.json", "inventory.json"]) else {
            throw JazzArchiveImportError.invalidArchive("missing manifest or inventory")
        }
        return (entries, centralOffset)
    }

    private func validateCommonHeader(
        version: UInt16,
        flags: UInt16,
        method: UInt16,
        modifiedTime: UInt16,
        modifiedDate: UInt16,
        crc32: UInt32,
        compressedSize: UInt32,
        expandedSize: UInt32,
        expected: Entry,
        context: String
    ) throws {
        guard version == 20, flags == 0x0800, method == 0,
            modifiedTime == 0, modifiedDate == 0x0021,
            crc32 == expected.crc32,
            compressedSize == expected.size,
            expandedSize == expected.size
        else {
            throw JazzArchiveImportError.unsupportedZIPFeature(
                "local header profile \(context)")
        }
    }

    private func readExact(
        _ handle: FileHandle,
        offset: UInt64,
        count: Int
    ) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else {
            throw JazzArchiveImportError.malformedZIP("truncated package")
        }
        return data
    }

    private func adding(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw JazzArchiveImportError.malformedZIP("integer overflow") }
        return value
    }

    private func boundedAdd(_ left: Int64, _ right: Int64, limit: Int64) throws -> Int64 {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow, value <= limit else {
            throw JazzArchiveImportError.entryLimitExceeded("total bytes")
        }
        return value
    }
}

private struct JazzArchiveCRC32 {
    private var value = UInt32.max

    mutating func update(_ data: Data) {
        for byte in data {
            let index = Int((value ^ UInt32(byte)) & 0xff)
            value = Self.table[index] ^ (value >> 8)
        }
    }

    func finalize() -> UInt32 { value ^ UInt32.max }

    private static let table: [UInt32] = (0..<256).map { input in
        var crc = UInt32(input)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? 0xedb8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[index(startIndex, offsetBy: offset)])
            | UInt16(self[index(startIndex, offsetBy: offset + 1)]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[index(startIndex, offsetBy: offset)])
            | UInt32(self[index(startIndex, offsetBy: offset + 1)]) << 8
            | UInt32(self[index(startIndex, offsetBy: offset + 2)]) << 16
            | UInt32(self[index(startIndex, offsetBy: offset + 3)]) << 24
    }
}
