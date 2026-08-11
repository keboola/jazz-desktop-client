import Foundation

public struct JazzArchiveDeliveryEntry: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var archiveId: String
    public var captureId: String
    public var artifactId: String
    public var legacySessionId: String
    public var kind: String
    public var mediaType: String
    public var fileName: String
    public var tags: [String]
    public var labelId: String?
    public var label: String?
    public var queuedAt: String

    public init(
        schemaVersion: Int = 1,
        archiveId: String,
        captureId: String,
        artifactId: String,
        legacySessionId: String,
        kind: String,
        mediaType: String,
        fileName: String,
        tags: [String],
        labelId: String? = nil,
        label: String? = nil,
        queuedAt: String = Timestamps.iso8601()
    ) {
        self.schemaVersion = schemaVersion
        self.archiveId = archiveId
        self.captureId = captureId
        self.artifactId = artifactId
        self.legacySessionId = legacySessionId
        self.kind = kind
        self.mediaType = mediaType
        self.fileName = fileName
        self.tags = tags
        self.labelId = labelId
        self.label = label
        self.queuedAt = queuedAt
    }
}

public struct JazzArchiveDeliveryReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entry: JazzArchiveDeliveryEntry
    public var remoteFileId: String
    public var deliveredAt: String

    public init(
        schemaVersion: Int = 1,
        entry: JazzArchiveDeliveryEntry,
        remoteFileId: String,
        deliveredAt: String
    ) {
        self.schemaVersion = schemaVersion
        self.entry = entry
        self.remoteFileId = remoteFileId
        self.deliveredAt = deliveredAt
    }
}

public enum JazzArchiveDeliveryQueueError: Error, Equatable {
    case invalidEntry(String)
    case conflict(String)
    case missing(String)
}

/// Mutable, transport-specific state outside canonical archive inventory. Entries point at bytes
/// already owned by the archive; uploaders may retry forever without copying or deleting evidence.
public actor JazzArchiveDeliveryQueue {
    public nonisolated let root: URL

    private let fileManager: FileManager
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    @discardableResult
    public func enqueue(_ entry: JazzArchiveDeliveryEntry) throws -> Bool {
        try Self.validate(entry)
        try fileManager.createDirectory(at: pendingRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: deliveredRoot, withIntermediateDirectories: true)
        let bytes = try Self.encoder.encode(entry)
        let pending = pendingURL(entry.artifactId)
        let delivered = deliveredURL(entry.artifactId)
        if fileManager.fileExists(atPath: delivered.path) {
            let receipt = try Self.decoder.decode(
                JazzArchiveDeliveryReceipt.self, from: Data(contentsOf: delivered))
            guard receipt.entry == entry else {
                throw JazzArchiveDeliveryQueueError.conflict(entry.artifactId)
            }
            return false
        }
        if fileManager.fileExists(atPath: pending.path) {
            guard try Data(contentsOf: pending) == bytes else {
                throw JazzArchiveDeliveryQueueError.conflict(entry.artifactId)
            }
            return false
        }
        if try !writeOnce(bytes, to: pending) {
            guard try Data(contentsOf: pending) == bytes else {
                throw JazzArchiveDeliveryQueueError.conflict(entry.artifactId)
            }
            return false
        }
        return true
    }

    public func pending() -> [JazzArchiveDeliveryEntry] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: pendingRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0),
                let entry = try? Self.decoder.decode(JazzArchiveDeliveryEntry.self, from: data),
                (try? Self.validate(entry)) != nil
            else { return nil }
            return entry
        }.sorted { ($0.queuedAt, $0.artifactId) < ($1.queuedAt, $1.artifactId) }
    }

    @discardableResult
    public func markDelivered(
        artifactId: String,
        remoteFileId: String,
        deliveredAt: String = Timestamps.iso8601()
    ) throws -> JazzArchiveDeliveryReceipt {
        guard !remoteFileId.isEmpty, Timestamps.parse(deliveredAt) != nil else {
            throw JazzArchiveDeliveryQueueError.invalidEntry(artifactId)
        }
        let pending = pendingURL(artifactId)
        if fileManager.fileExists(atPath: deliveredURL(artifactId).path) {
            let existing = try Self.decoder.decode(
                JazzArchiveDeliveryReceipt.self,
                from: Data(contentsOf: deliveredURL(artifactId)))
            guard existing.remoteFileId == remoteFileId else {
                throw JazzArchiveDeliveryQueueError.conflict(artifactId)
            }
            return existing
        }
        guard fileManager.fileExists(atPath: pending.path) else {
            throw JazzArchiveDeliveryQueueError.missing(artifactId)
        }
        let entry = try Self.decoder.decode(
            JazzArchiveDeliveryEntry.self, from: Data(contentsOf: pending))
        let receipt = JazzArchiveDeliveryReceipt(
            entry: entry, remoteFileId: remoteFileId, deliveredAt: deliveredAt)
        try fileManager.createDirectory(at: deliveredRoot, withIntermediateDirectories: true)
        let receiptBytes = try Self.encoder.encode(receipt)
        if try !writeOnce(receiptBytes, to: deliveredURL(artifactId)) {
            let existing = try Self.decoder.decode(
                JazzArchiveDeliveryReceipt.self,
                from: Data(contentsOf: deliveredURL(artifactId)))
            guard existing == receipt else {
                throw JazzArchiveDeliveryQueueError.conflict(artifactId)
            }
        }
        try fileManager.removeItem(at: pending)
        return receipt
    }

    public func receipt(artifactId: String) -> JazzArchiveDeliveryReceipt? {
        try? Self.decoder.decode(
            JazzArchiveDeliveryReceipt.self,
            from: Data(contentsOf: deliveredURL(artifactId)))
    }

    private var pendingRoot: URL { root.appendingPathComponent("pending", isDirectory: true) }
    private var deliveredRoot: URL { root.appendingPathComponent("delivered", isDirectory: true) }
    private func pendingURL(_ id: String) -> URL { pendingRoot.appendingPathComponent("\(id).json") }
    private func deliveredURL(_ id: String) -> URL {
        deliveredRoot.appendingPathComponent("\(id).json")
    }

    /// Publish fully-written bytes without ever replacing an existing queue item. A hard link is
    /// atomic on the local volume, so a crash can leave at worst an unreferenced hidden temp file.
    private func writeOnce(_ data: Data, to destination: URL) throws -> Bool {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.linkItem(at: temporary, to: destination)
            return true
        } catch where fileManager.fileExists(atPath: destination.path) {
            return false
        }
    }

    private static func validate(_ entry: JazzArchiveDeliveryEntry) throws {
        guard entry.schemaVersion == 1,
            entry.archiveId.hasPrefix("ar-"),
            entry.captureId.hasPrefix("cap-"),
            entry.artifactId.hasPrefix("art-"),
            entry.legacySessionId.hasPrefix("s-"),
            !entry.kind.isEmpty,
            entry.mediaType.contains("/"),
            !entry.fileName.isEmpty,
            !entry.tags.isEmpty,
            Set(entry.tags).count == entry.tags.count,
            Timestamps.parse(entry.queuedAt) != nil
        else { throw JazzArchiveDeliveryQueueError.invalidEntry(entry.artifactId) }
    }
}
