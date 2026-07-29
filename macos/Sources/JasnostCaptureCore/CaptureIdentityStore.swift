import Foundation

public struct CaptureInstallationIdentity: Codable, Equatable, Sendable {
    public let originId: String
    public let createdAt: String

    public init(originId: String, createdAt: String) {
        self.originId = originId
        self.createdAt = createdAt
    }
}

public struct CaptureSourceIdentity: Codable, Equatable, Sendable {
    public let sourceId: String
    public let kind: String
    public let createdAt: String

    public init(sourceId: String, kind: String, createdAt: String) {
        self.sourceId = sourceId
        self.kind = kind
        self.createdAt = createdAt
    }
}

public struct CaptureActorIdentity: Codable, Equatable, Sendable {
    public let actorId: String
    public let namespace: String
    public let value: String
    public var displayName: String?
    public let createdAt: String
    public var updatedAt: String?

    public init(
        actorId: String,
        namespace: String,
        value: String,
        displayName: String? = nil,
        createdAt: String,
        updatedAt: String? = nil
    ) {
        self.actorId = actorId
        self.namespace = namespace
        self.value = value
        self.displayName = displayName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CaptureIdentitySnapshot: Equatable, Sendable {
    public let installation: CaptureInstallationIdentity
    public let sources: [CaptureSourceIdentity]
    public let actors: [CaptureActorIdentity]
}

public enum CaptureIdentityStoreError: Error, Equatable, CustomStringConvertible {
    case corrupt(String)
    case invalidField(String)
    case identityCollision(String)

    public var description: String {
        switch self {
        case let .corrupt(detail): return "Corrupt capture identity store: \(detail)"
        case let .invalidField(field): return "Invalid capture identity field: \(field)"
        case let .identityCollision(id): return "Capture identity collision: \(id)"
        }
    }
}

/// Durable, non-secret identity registry for one installed capture client.
///
/// `originId` identifies the installation/producer origin and is minted exactly once. Source IDs
/// are stable per capture adapter kind; actor IDs are stable per namespaced external human identity.
/// None of these claims authorize server access. The server still binds an archive to the
/// authenticated tenant and records the uploader separately.
public actor CaptureIdentityStore {
    private struct Document: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var installation: CaptureInstallationIdentity
        var sources: [CaptureSourceIdentity]
        var actors: [CaptureActorIdentity]
    }

    public nonisolated let root: URL

    private static let schemaVersion = 1
    private static let directoryName = ".capture-identity"
    private static let filename = "identity.json"
    private static let tokenPattern = try! NSRegularExpression(
        pattern: "^[a-z][a-z0-9._-]*$", options: [])
    private static let uuidV7Pattern = try! NSRegularExpression(
        pattern: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
        options: [])
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    private let fileManager: FileManager
    private let durability: JazzArchiveFilesystemDurability
    private let leaseProvider: any CaptureIdentityStoreLeaseProvider

    public init(
        root: URL,
        durability: JazzArchiveFilesystemDurability,
        fileManager: FileManager = .default,
        leaseProvider: any CaptureIdentityStoreLeaseProvider
    ) {
        self.root = root
        self.fileManager = fileManager
        self.durability = durability
        self.leaseProvider = leaseProvider
    }

    /// Load the existing installation identity or claim it exactly once under the same
    /// cross-process lease used by every registry mutation. A corrupt file is surfaced and is
    /// never replaced with a new origin.
    public func loadOrCreate(createdAt: String = Timestamps.iso8601()) throws
        -> CaptureIdentitySnapshot
    {
        try withLease {
            Self.snapshot(try loadOrCreateWhileLeased(createdAt: createdAt))
        }
    }

    /// Stable source identity for one producer adapter, e.g. `macos.native` or `meeting.share`.
    public func source(
        kind: String,
        createdAt: String = Timestamps.iso8601()
    ) throws -> CaptureSourceIdentity {
        try Self.token(kind, field: "source.kind")
        return try withLease {
            var document = try loadOrCreateWhileLeased(createdAt: createdAt)
            if let existing = document.sources.first(where: { $0.kind == kind }) {
                return existing
            }
            try Self.timestamp(createdAt, field: "source.createdAt")
            let source = CaptureSourceIdentity(
                sourceId: Identifiers.newSourceId(), kind: kind, createdAt: createdAt)
            document.sources.append(source)
            document.sources.sort { ($0.kind, $0.sourceId) < ($1.kind, $1.sourceId) }
            try installWhileLeased(document)
            return source
        }
    }

    /// Stable local actor claim for a namespaced external identity. Recorder, performer and
    /// narrator selection remains a per-capture decision; this method only resolves identities.
    public func actor(
        namespace: String,
        value: String,
        displayName: String? = nil,
        at timestamp: String = Timestamps.iso8601()
    ) throws -> CaptureActorIdentity {
        try Self.nonempty(namespace, field: "actor.namespace")
        try Self.nonempty(value, field: "actor.value")
        if let displayName { try Self.nonempty(displayName, field: "actor.displayName") }
        return try withLease {
            var document = try loadOrCreateWhileLeased(createdAt: timestamp)
            if let index = document.actors.firstIndex(where: {
                $0.namespace == namespace && $0.value == value
            }) {
                if let displayName, displayName != document.actors[index].displayName {
                    try Self.timestamp(timestamp, field: "actor.updatedAt")
                    document.actors[index].displayName = displayName
                    document.actors[index].updatedAt = timestamp
                    try installWhileLeased(document)
                }
                return document.actors[index]
            }
            try Self.timestamp(timestamp, field: "actor.createdAt")
            let actor = CaptureActorIdentity(
                actorId: Identifiers.newActorId(),
                namespace: namespace,
                value: value,
                displayName: displayName,
                createdAt: timestamp)
            document.actors.append(actor)
            document.actors.sort {
                ($0.namespace, $0.value, $0.actorId) < ($1.namespace, $1.value, $1.actorId)
            }
            try installWhileLeased(document)
            return actor
        }
    }

    public func snapshot() throws -> CaptureIdentitySnapshot {
        try withLease {
            Self.snapshot(try loadOrCreateWhileLeased())
        }
    }

    private func withLease<T>(_ operation: () throws -> T) throws -> T {
        let lease = try leaseProvider.acquire(root: root, fileManager: fileManager)
        defer { lease.release() }
        return try operation()
    }

    /// Must only be called while holding `leaseProvider`'s lease. Existing state is always
    /// reloaded under the lease so an earlier read cannot overwrite another process' mutation.
    private func loadOrCreateWhileLeased(createdAt: String = Timestamps.iso8601()) throws
        -> Document
    {
        if fileManager.fileExists(atPath: identityDirectory.path) {
            return try load()
        }

        try Self.timestamp(createdAt, field: "installation.createdAt")
        let created = Document(
            schemaVersion: Self.schemaVersion,
            installation: CaptureInstallationIdentity(
                originId: Identifiers.newOriginId(), createdAt: createdAt),
            sources: [],
            actors: [])
        try Self.validate(created)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            // The directory itself is the exclusive identity claim. If the process dies before
            // publishing identity.json, the next launch surfaces a corrupt/incomplete claim and
            // never mints a second origin over it.
            try fileManager.createDirectory(
                at: identityDirectory, withIntermediateDirectories: false)
        } catch {
            if fileManager.fileExists(atPath: identityDirectory.path) {
                return try load()
            }
            throw error
        }
        try Self.encoder.encode(created).write(to: identityURL, options: .atomic)
        try synchronizeIdentityDocument()
        return created
    }

    /// Must only be called while holding `leaseProvider`'s lease.
    private func installWhileLeased(_ document: Document) throws {
        try Self.validate(document)
        let data = try Self.encoder.encode(document)
        try data.write(to: identityURL, options: .atomic)
        try synchronizeIdentityDocument()
    }

    private func load() throws -> Document {
        do {
            let document = try Self.decoder.decode(
                Document.self, from: Data(contentsOf: identityURL))
            try Self.validate(document)
            // A prior process may have published these exact bytes and then failed before its
            // filesystem barrier. Re-synchronizing under the registry lease turns retry into the
            // same durable identity instead of minting or overwriting anything.
            try synchronizeIdentityDocument()
            return document
        } catch let error as CaptureIdentityStoreError {
            throw error
        } catch let error as JazzArchiveFilesystemDurabilityError {
            throw error
        } catch {
            throw CaptureIdentityStoreError.corrupt(error.localizedDescription)
        }
    }

    private var identityDirectory: URL {
        root.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private var identityURL: URL { identityDirectory.appendingPathComponent(Self.filename) }

    private func synchronizeIdentityDocument() throws {
        try durability.synchronizeRegularFile(
            identityURL, permissions: Int16(0o600))
        try durability.synchronizeDirectory(identityDirectory)
        try durability.synchronizeDirectory(root)
        try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }

    private static func snapshot(_ document: Document) -> CaptureIdentitySnapshot {
        CaptureIdentitySnapshot(
            installation: document.installation,
            sources: document.sources,
            actors: document.actors)
    }

    private static func validate(_ document: Document) throws {
        guard document.schemaVersion == schemaVersion else {
            throw CaptureIdentityStoreError.corrupt(
                "unsupported schema version \(document.schemaVersion)")
        }
        try prefixedUUIDv7(document.installation.originId, prefix: "origin")
        try timestamp(document.installation.createdAt, field: "installation.createdAt")
        guard Set(document.sources.map(\.sourceId)).count == document.sources.count,
            Set(document.sources.map(\.kind)).count == document.sources.count
        else { throw CaptureIdentityStoreError.corrupt("duplicate source identity") }
        for source in document.sources {
            try prefixedUUIDv7(source.sourceId, prefix: "src")
            try token(source.kind, field: "source.kind")
            try timestamp(source.createdAt, field: "source.createdAt")
        }
        guard Set(document.actors.map(\.actorId)).count == document.actors.count,
            Set(document.actors.map { "\($0.namespace)\u{0}\($0.value)" }).count
                == document.actors.count
        else { throw CaptureIdentityStoreError.corrupt("duplicate actor identity") }
        for actor in document.actors {
            try prefixedUUIDv7(actor.actorId, prefix: "actor")
            try nonempty(actor.namespace, field: "actor.namespace")
            try nonempty(actor.value, field: "actor.value")
            if let displayName = actor.displayName {
                try nonempty(displayName, field: "actor.displayName")
            }
            try timestamp(actor.createdAt, field: "actor.createdAt")
            if let updatedAt = actor.updatedAt {
                try timestamp(updatedAt, field: "actor.updatedAt")
            }
        }
    }

    private static func prefixedUUIDv7(_ value: String, prefix: String) throws {
        let expectedPrefix = "\(prefix)-"
        guard value.hasPrefix(expectedPrefix) else {
            throw CaptureIdentityStoreError.corrupt("invalid \(prefix) identity")
        }
        let uuid = String(value.dropFirst(expectedPrefix.count))
        let range = NSRange(uuid.startIndex..<uuid.endIndex, in: uuid)
        guard uuidV7Pattern.firstMatch(in: uuid, options: [], range: range) != nil else {
            throw CaptureIdentityStoreError.corrupt("invalid \(prefix) UUIDv7")
        }
    }

    private static func token(_ value: String, field: String) throws {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard tokenPattern.firstMatch(in: value, options: [], range: range) != nil else {
            throw CaptureIdentityStoreError.invalidField(field)
        }
    }

    private static func nonempty(_ value: String, field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureIdentityStoreError.invalidField(field)
        }
    }

    private static func timestamp(_ value: String, field: String) throws {
        guard Timestamps.parse(value) != nil else {
            throw CaptureIdentityStoreError.invalidField(field)
        }
    }
}
