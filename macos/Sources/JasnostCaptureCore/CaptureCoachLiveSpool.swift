import Foundation

public enum CaptureCoachLiveMessageAcknowledgementStatus:
  String, Codable, CaseIterable, Equatable, Sendable
{
  case stored
  case exactDuplicate = "exact_duplicate"
  case stale
  case incomparable
  case finalBarrier = "final_barrier"
}

public enum CaptureCoachLiveReceiptAcknowledgementStatus:
  String, Codable, CaseIterable, Equatable, Sendable
{
  case stored
  case exactDuplicate = "exact_duplicate"
}

public protocol CaptureCoachLivePersistedAcknowledgement:
  Codable, Equatable, Sendable
{
  var acknowledgedIdentifier: String { get }
  var contentDigest: String { get }
  func validate() throws
}

extension CaptureCoachLivePersistedAcknowledgement {
  public static func decodeCanonical(_ data: Data) throws -> Self {
    let value: Self
    do {
      value = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try value.validate()
    guard try JazzArchiveCanonicalJSON.encode(value) == data else {
      throw CaptureCoachLiveContractError.nonCanonicalJSON
    }
    return value
  }
}

public struct CaptureCoachLiveMessageAcknowledgement:
  CaptureCoachLivePersistedAcknowledgement
{
  public var documentType: String
  public var schemaVersion: Int
  public var messageId: String
  public var contentDigest: String
  public var status: CaptureCoachLiveMessageAcknowledgementStatus

  public init(
    messageId: String,
    contentDigest: String,
    status: CaptureCoachLiveMessageAcknowledgementStatus
  ) {
    documentType = "message_ack"
    schemaVersion = 1
    self.messageId = messageId
    self.contentDigest = contentDigest
    self.status = status
  }

  public var acknowledgedIdentifier: String { messageId }

  public func validate() throws {
    guard documentType == "message_ack", schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try CaptureCoachLiveValidation.uuidV7(messageId, prefix: "ccm")
    try CaptureCoachLiveValidation.sha256(
      contentDigest, field: "message_ack.contentDigest")
  }
}

public struct CaptureCoachLiveReceiptAcknowledgement:
  CaptureCoachLivePersistedAcknowledgement
{
  public var documentType: String
  public var schemaVersion: Int
  public var receiptId: String
  public var contentDigest: String
  public var status: CaptureCoachLiveReceiptAcknowledgementStatus

  public init(
    receiptId: String,
    contentDigest: String,
    status: CaptureCoachLiveReceiptAcknowledgementStatus
  ) {
    documentType = "receipt_ack"
    schemaVersion = 1
    self.receiptId = receiptId
    self.contentDigest = contentDigest
    self.status = status
  }

  public var acknowledgedIdentifier: String { receiptId }

  public func validate() throws {
    guard documentType == "receipt_ack", schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try CaptureCoachLiveValidation.uuidV7(receiptId, prefix: "ccr")
    try CaptureCoachLiveValidation.sha256(
      contentDigest, field: "receipt_ack.contentDigest")
  }
}

/// One strict receipt union gives prompt and scope-control actions a single global `ccr-*`
/// collision fence and one durable delivery queue.
public enum CaptureCoachLiveReceiptDocument: Equatable, Sendable {
  case prompt(CaptureCoachLivePromptReceipt)
  case scopeControl(CaptureCoachLiveScopeControlReceipt)
}

/// Bounded delivery fairness: control receipts go first, then alternate with evidence messages
/// while both queues are non-empty. A sustained PCM backlog can therefore never starve prompt
/// resolution, and an unusual receipt burst cannot permanently starve canonical evidence.
public struct CaptureCoachLiveDeliveryFairnessGate: Sendable {
  public enum Queue: Equatable, Sendable {
    case message
    case receipt
  }

  private var nextWhenBoth: Queue = .receipt

  public init() {}

  public mutating func next(
    hasMessage: Bool,
    hasReceipt: Bool
  ) -> Queue? {
    switch (hasMessage, hasReceipt) {
    case (true, true):
      let selected = nextWhenBoth
      nextWhenBoth = selected == .receipt ? .message : .receipt
      return selected
    case (true, false): return .message
    case (false, true): return .receipt
    case (false, false): return nil
    }
  }
}

extension CaptureCoachLiveReceiptDocument: CaptureCoachLiveSpoolDocument {
  private enum CodingKeys: String, CodingKey { case promptId }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.promptId) {
      self = .prompt(try CaptureCoachLivePromptReceipt(from: decoder))
    } else {
      self = .scopeControl(try CaptureCoachLiveScopeControlReceipt(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .prompt(let value): try value.encode(to: encoder)
    case .scopeControl(let value): try value.encode(to: encoder)
    }
  }

  public var spoolIdentifier: String {
    switch self {
    case .prompt(let value): value.receiptId
    case .scopeControl(let value): value.receiptId
    }
  }

  public var contentDigest: String {
    switch self {
    case .prompt(let value): value.contentDigest
    case .scopeControl(let value): value.contentDigest
    }
  }

  public func validate() throws {
    switch self {
    case .prompt(let value): try value.validate()
    case .scopeControl(let value): try value.validate()
    }
  }
}

public enum CaptureCoachLiveSpoolError: Error, Equatable, CustomStringConvertible {
  case invalidRoot
  case identifierCollision(String)
  case acknowledgementMismatch(String)
  case corruptEntry(String)

  public var description: String {
    switch self {
    case .invalidRoot:
      "Invalid Capture Coach spool root"
    case .identifierCollision(let identifier):
      "Capture Coach spool identity collision: \(identifier)"
    case .acknowledgementMismatch(let identifier):
      "Capture Coach acknowledgement does not bind pending bytes: \(identifier)"
    case .corruptEntry(let path):
      "Corrupt Capture Coach spool entry: \(path)"
    }
  }
}

public struct CaptureCoachLivePendingItem<Document>: Equatable, Sendable
where Document: CaptureCoachLiveSpoolDocument {
  public var document: Document
  public var canonicalData: Data

  public init(document: Document, canonicalData: Data) {
    self.document = document
    self.canonicalData = canonicalData
  }
}

/// Compact write-once identity fence retained after a terminal ACK. Full exact bytes live only
/// while pending; SHA-256, length, and the document's own content digest preserve collision and
/// ACK binding without duplicating large PCM payloads for the lifetime of the installation.
public struct CaptureCoachLiveIdentityTombstone: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var identifier: String
  public var rawSha256: String
  public var byteLength: Int
  public var contentDigest: String

  public init<Document>(
    document: Document,
    canonicalData: Data
  ) where Document: CaptureCoachLiveSpoolDocument {
    schemaVersion = 1
    identifier = document.spoolIdentifier
    rawSha256 = JazzArchiveDigest.sha256Hex(canonicalData)
    byteLength = canonicalData.count
    contentDigest = document.contentDigest
  }

  public func validate() throws {
    guard schemaVersion == 1, byteLength > 0 else {
      throw CaptureCoachLiveSpoolError.corruptEntry(identifier)
    }
    try CaptureCoachLiveValidation.sha256(
      rawSha256, field: "identityTombstone.rawSha256")
    try CaptureCoachLiveValidation.sha256(
      contentDigest, field: "identityTombstone.contentDigest")
  }
}

/// One durable exact-byte queue per document family. Enqueue is write-once by logical id.
/// Relaunch reads the same RFC 8785 bytes; retries never re-encode them. Only a strict terminal
/// persisted acknowledgement with the exact id and digest replaces it with a compact tombstone.
public actor CaptureCoachLiveExactByteSpool<Document>
where Document: CaptureCoachLiveSpoolDocument {
  private static var historyMarkerName: String {
    ".capture-coach-tombstones-v1"
  }
  private static var historyMarkerData: Data {
    Data("capture-coach-live-tombstones-v1\n".utf8)
  }

  private let fileManager: FileManager
  private let root: URL
  private let pendingRoot: URL
  private let acknowledgedRoot: URL
  private let globalCollisionRoot: URL?
  private let preserveLegacyAcknowledgedDocumentsForRecovery: Bool
  private let durability: JazzArchiveFilesystemDurability
  private var historyCompacted = false

  public init(
    root: URL,
    globalCollisionRoot: URL? = nil,
    preserveLegacyAcknowledgedDocumentsForRecovery: Bool = false,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) throws {
    guard root.isFileURL else { throw CaptureCoachLiveSpoolError.invalidRoot }
    if let globalCollisionRoot, !globalCollisionRoot.isFileURL {
      throw CaptureCoachLiveSpoolError.invalidRoot
    }
    self.root = root
    self.fileManager = fileManager
    self.globalCollisionRoot = globalCollisionRoot
    self.preserveLegacyAcknowledgedDocumentsForRecovery =
      preserveLegacyAcknowledgedDocumentsForRecovery
    self.durability = durability
    pendingRoot = root.appendingPathComponent("pending", isDirectory: true)
    acknowledgedRoot = root.appendingPathComponent(
      "acknowledged", isDirectory: true)
    try fileManager.createDirectory(
      at: pendingRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: acknowledgedRoot, withIntermediateDirectories: true)
    if let globalCollisionRoot {
      try fileManager.createDirectory(
        at: globalCollisionRoot, withIntermediateDirectories: true)
    }
    try durability.synchronizeDirectory(pendingRoot)
    try durability.synchronizeDirectory(acknowledgedRoot)
    try durability.synchronizeDirectory(root)
    try durability.synchronizeDirectory(root.deletingLastPathComponent())
    if let globalCollisionRoot {
      try durability.synchronizeDirectory(globalCollisionRoot)
      try durability.synchronizeDirectory(globalCollisionRoot.deletingLastPathComponent())
      try durability.synchronizeDirectory(
        globalCollisionRoot.deletingLastPathComponent().deletingLastPathComponent())
    }
  }

  @discardableResult
  public func enqueue(_ document: Document) throws -> CaptureCoachLivePendingItem<Document> {
    try ensureHistoryCompacted()
    let data = try document.canonicalData()
    let identifier = document.spoolIdentifier
    try Self.validatePathComponent(identifier)
    try assertGlobalIdentity(data, identifier: identifier)
    let pending = url(in: pendingRoot, identifier: identifier)
    let acknowledged = url(in: acknowledgedRoot, identifier: identifier)

    if fileManager.fileExists(atPath: acknowledged.path) {
      let tombstone = try readTombstone(
        at: acknowledged, expectedIdentifier: identifier)
      guard tombstone == CaptureCoachLiveIdentityTombstone(
        document: document, canonicalData: data)
      else {
        throw CaptureCoachLiveSpoolError.identifierCollision(identifier)
      }
      try durability.synchronizeRegularFile(
        acknowledged, permissions: Int16(0o600))
      try durability.synchronizeDirectory(acknowledgedRoot)
      try durability.synchronizeDirectory(root)
      return CaptureCoachLivePendingItem(document: document, canonicalData: data)
    }
    if fileManager.fileExists(atPath: pending.path) {
      guard try Data(contentsOf: pending) == data else {
        throw CaptureCoachLiveSpoolError.identifierCollision(identifier)
      }
      try durability.synchronizeRegularFile(
        pending, permissions: Int16(0o600))
      try durability.synchronizeDirectory(pendingRoot)
      try durability.synchronizeDirectory(root)
      return CaptureCoachLivePendingItem(document: document, canonicalData: data)
    }
    try publish(data, at: pending)
    return CaptureCoachLivePendingItem(document: document, canonicalData: data)
  }

  public func pendingItems() throws -> [CaptureCoachLivePendingItem<Document>] {
    try ensureHistoryCompacted()
    let pending = try items(in: pendingRoot)
    var deliverable: [CaptureCoachLivePendingItem<Document>] = []
    for item in pending {
      let acknowledged = url(
        in: acknowledgedRoot, identifier: item.document.spoolIdentifier)
      guard fileManager.fileExists(atPath: acknowledged.path) else {
        deliverable.append(item)
        continue
      }
      let expected = CaptureCoachLiveIdentityTombstone(
        document: item.document, canonicalData: item.canonicalData)
      guard
        try readTombstone(
          at: acknowledged,
          expectedIdentifier: item.document.spoolIdentifier) == expected
      else {
        throw CaptureCoachLiveSpoolError.identifierCollision(
          item.document.spoolIdentifier)
      }
      try fileManager.removeItem(
        at: url(
          in: pendingRoot,
          identifier: item.document.spoolIdentifier))
      try durability.synchronizeDirectory(pendingRoot)
      try durability.synchronizeDirectory(root)
    }
    return deliverable
  }

  /// Phase one of the legacy message-queue upgrade. Full acknowledged documents remain untouched
  /// until their capture-scoped recovery head has been durably written, so a crash during migration
  /// cannot erase the only copy of an acknowledged watermark.
  public func legacyAcknowledgedDocuments()
    throws -> [CaptureCoachLivePendingItem<Document>]
  {
    try ensureHistoryCompacted()
    if try historyIsMarked(in: acknowledgedRoot) { return [] }
    let entries = try fileManager.contentsOfDirectory(
      at: acknowledgedRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var legacy: [CaptureCoachLivePendingItem<Document>] = []
    for url in entries {
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      if let item = try legacyAcknowledgedItemIfPresent(at: url) {
        legacy.append(item)
      }
    }
    return legacy
  }

  /// Phase two of the legacy upgrade, called only after the caller has fsynced the replacement
  /// recovery head. Other captures' legacy documents remain intact until their own heads are safe.
  public func compactLegacyAcknowledgedDocuments(
    identifiers: Set<String>
  ) throws {
    try ensureHistoryCompacted()
    guard !(try historyIsMarked(in: acknowledgedRoot)) else { return }
    for identifier in identifiers.sorted() {
      try Self.validatePathComponent(identifier)
      let destination = url(
        in: acknowledgedRoot, identifier: identifier)
      guard fileManager.fileExists(atPath: destination.path),
        let item = try legacyAcknowledgedItemIfPresent(at: destination)
      else { continue }
      guard item.document.spoolIdentifier == identifier else {
        throw CaptureCoachLiveSpoolError.corruptEntry(destination.path)
      }
      try replaceWithTombstone(
        CaptureCoachLiveIdentityTombstone(
          document: item.document,
          canonicalData: item.canonicalData),
        at: destination)
    }

    let entries = try fileManager.contentsOfDirectory(
      at: acknowledgedRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    for entry in entries {
      let values = try entry.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        entry.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(entry.path) }
      if try legacyAcknowledgedItemIfPresent(at: entry) != nil {
        return
      }
    }
    try publishHistoryMarker(in: acknowledgedRoot)
  }

  private func items(
    in directory: URL
  ) throws -> [CaptureCoachLivePendingItem<Document>] {
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    return try entries.map { url in
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      let data = try Data(contentsOf: url)
      let document = try Document.decodeCanonical(data)
      guard
        url.deletingPathExtension().lastPathComponent
          == document.spoolIdentifier
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      return CaptureCoachLivePendingItem(
        document: document, canonicalData: data)
    }
  }

  public func pendingCount() throws -> Int {
    try pendingItems().count
  }

  /// Network failures, 204/409, malformed JSON, an echo mismatch, and any non-terminal response
  /// must never call this method. All protocol ACK statuses represented by the two strict ACK
  /// types are terminal persisted outcomes.
  public func acknowledge<A>(_ acknowledgement: A) throws
  where A: CaptureCoachLivePersistedAcknowledgement {
    try ensureHistoryCompacted()
    try acknowledgement.validate()
    let identifier = acknowledgement.acknowledgedIdentifier
    try Self.validatePathComponent(identifier)
    let pending = url(in: pendingRoot, identifier: identifier)
    let acknowledged = url(in: acknowledgedRoot, identifier: identifier)

    if fileManager.fileExists(atPath: acknowledged.path) {
      let tombstone = try readTombstone(
        at: acknowledged, expectedIdentifier: identifier)
      guard tombstone.contentDigest == acknowledgement.contentDigest
      else {
        throw CaptureCoachLiveSpoolError.acknowledgementMismatch(identifier)
      }
      try durability.synchronizeRegularFile(
        acknowledged, permissions: Int16(0o600))
      try durability.synchronizeDirectory(acknowledgedRoot)
      try durability.synchronizeDirectory(root)
      return
    }
    guard fileManager.fileExists(atPath: pending.path) else {
      throw CaptureCoachLiveSpoolError.acknowledgementMismatch(identifier)
    }
    let data = try Data(contentsOf: pending)
    let document = try Document.decodeCanonical(data)
    guard document.spoolIdentifier == identifier,
      document.contentDigest == acknowledgement.contentDigest
    else {
      throw CaptureCoachLiveSpoolError.acknowledgementMismatch(identifier)
    }
    let tombstone = CaptureCoachLiveIdentityTombstone(
      document: document, canonicalData: data)
    try publish(
      try JazzArchiveCanonicalJSON.encode(tombstone),
      at: acknowledged)
    try fileManager.removeItem(at: pending)
    try durability.synchronizeDirectory(pendingRoot)
    try durability.synchronizeDirectory(acknowledgedRoot)
    try durability.synchronizeDirectory(root)
  }

  private func publish(_ data: Data, at destination: URL) throws {
    let temporary = root.appendingPathComponent(
      ".publish-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer {
      if keepTemporary { try? fileManager.removeItem(at: temporary) }
    }
    guard
      fileManager.createFile(
        atPath: temporary.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
    try durability.synchronizeRegularFile(
      temporary, permissions: Int16(0o600))
    try fileManager.moveItem(at: temporary, to: destination)
    keepTemporary = false
    try durability.synchronizeRegularFile(
      destination, permissions: Int16(0o600))
    try durability.synchronizeDirectory(destination.deletingLastPathComponent())
    try durability.synchronizeDirectory(root)
  }

  private func assertGlobalIdentity(_ data: Data, identifier: String) throws {
    guard let globalCollisionRoot else { return }
    let destination = url(in: globalCollisionRoot, identifier: identifier)
    let document = try Document.decodeCanonical(data)
    let tombstone = CaptureCoachLiveIdentityTombstone(
      document: document, canonicalData: data)
    if fileManager.fileExists(atPath: destination.path) {
      guard
        try readTombstone(
          at: destination, expectedIdentifier: identifier) == tombstone
      else {
        throw CaptureCoachLiveSpoolError.identifierCollision(identifier)
      }
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(globalCollisionRoot)
      return
    }
    let temporary = globalCollisionRoot.appendingPathComponent(
      ".identity-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer {
      if keepTemporary { try? fileManager.removeItem(at: temporary) }
    }
    guard
      fileManager.createFile(
        atPath: temporary.path,
        contents: try JazzArchiveCanonicalJSON.encode(tombstone),
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
    try durability.synchronizeRegularFile(
      temporary, permissions: Int16(0o600))
    do {
      try fileManager.moveItem(at: temporary, to: destination)
      keepTemporary = false
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(globalCollisionRoot)
      try durability.synchronizeDirectory(
        globalCollisionRoot.deletingLastPathComponent())
      try durability.synchronizeDirectory(
        globalCollisionRoot.deletingLastPathComponent().deletingLastPathComponent())
    } catch {
      if fileManager.fileExists(atPath: destination.path),
        try readTombstone(
          at: destination, expectedIdentifier: identifier) == tombstone
      {
        try durability.synchronizeRegularFile(
          destination, permissions: Int16(0o600))
        try durability.synchronizeDirectory(globalCollisionRoot)
        return
      }
      throw error
    }
  }

  private func readTombstone(
    at url: URL,
    expectedIdentifier: String
  ) throws -> CaptureCoachLiveIdentityTombstone {
    let data = try Data(contentsOf: url)
    var tombstone: CaptureCoachLiveIdentityTombstone
    do {
      tombstone = try JSONDecoder().decode(
        CaptureCoachLiveIdentityTombstone.self, from: data)
      try tombstone.validate()
      guard try JazzArchiveCanonicalJSON.encode(tombstone) == data else {
        throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
      }
    } catch let error as CaptureCoachLiveSpoolError {
      throw error
    } catch {
      let legacy = try Document.decodeCanonical(data)
      tombstone = CaptureCoachLiveIdentityTombstone(
        document: legacy, canonicalData: data)
      try replaceWithTombstone(tombstone, at: url)
    }
    guard tombstone.identifier == expectedIdentifier else {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    return tombstone
  }

  private func compactLegacyDocuments(in directory: URL) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    for url in entries {
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      _ = try readTombstone(
        at: url,
        expectedIdentifier: url.deletingPathExtension().lastPathComponent)
    }
  }

  private func ensureHistoryCompacted() throws {
    guard !historyCompacted else { return }
    if !preserveLegacyAcknowledgedDocumentsForRecovery {
      try compactHistoryAndMark(in: acknowledgedRoot)
    }
    if let globalCollisionRoot {
      try compactHistoryAndMark(in: globalCollisionRoot)
    }
    historyCompacted = true
  }

  private func compactHistoryAndMark(in directory: URL) throws {
    guard !(try historyIsMarked(in: directory)) else { return }
    try compactLegacyDocuments(in: directory)
    try publishHistoryMarker(in: directory)
  }

  private func historyIsMarked(in directory: URL) throws -> Bool {
    let marker = directory.appendingPathComponent(Self.historyMarkerName)
    guard fileManager.fileExists(atPath: marker.path) else { return false }
    let values = try marker.resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true,
      values.isSymbolicLink != true,
      try Data(contentsOf: marker) == Self.historyMarkerData
    else { throw CaptureCoachLiveSpoolError.corruptEntry(marker.path) }
    return true
  }

  private func publishHistoryMarker(in directory: URL) throws {
    if try historyIsMarked(in: directory) { return }
    let destination = directory.appendingPathComponent(
      Self.historyMarkerName)
    let temporary = directory.appendingPathComponent(
      ".history-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer {
      if keepTemporary { try? fileManager.removeItem(at: temporary) }
    }
    guard fileManager.createFile(
      atPath: temporary.path,
      contents: Self.historyMarkerData,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
    try durability.synchronizeRegularFile(
      temporary, permissions: Int16(0o600))
    do {
      try fileManager.moveItem(at: temporary, to: destination)
      keepTemporary = false
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(directory)
    } catch {
      if try historyIsMarked(in: directory) {
        return
      }
      throw error
    }
  }

  private func legacyAcknowledgedItemIfPresent(
    at url: URL
  ) throws -> CaptureCoachLivePendingItem<Document>? {
    let data = try Data(contentsOf: url)
    if let tombstone = try? JSONDecoder().decode(
      CaptureCoachLiveIdentityTombstone.self, from: data)
    {
      try tombstone.validate()
      guard try JazzArchiveCanonicalJSON.encode(tombstone) == data,
        tombstone.identifier
          == url.deletingPathExtension().lastPathComponent
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      return nil
    }
    let document: Document
    do {
      document = try Document.decodeCanonical(data)
    } catch {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    guard document.spoolIdentifier
      == url.deletingPathExtension().lastPathComponent
    else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
    return CaptureCoachLivePendingItem(
      document: document, canonicalData: data)
  }

  private func replaceWithTombstone(
    _ tombstone: CaptureCoachLiveIdentityTombstone,
    at destination: URL
  ) throws {
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(
        ".compact-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer {
      if keepTemporary { try? fileManager.removeItem(at: temporary) }
    }
    guard fileManager.createFile(
      atPath: temporary.path,
      contents: try JazzArchiveCanonicalJSON.encode(tombstone),
      attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else { throw CaptureCoachLiveSpoolError.invalidRoot }
    try durability.synchronizeRegularFile(
      temporary, permissions: Int16(0o600))
    _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
    keepTemporary = false
    try durability.synchronizeRegularFile(
      destination, permissions: Int16(0o600))
    try durability.synchronizeDirectory(destination.deletingLastPathComponent())
  }

  private func url(in directory: URL, identifier: String) -> URL {
    directory.appendingPathComponent(identifier + ".json", isDirectory: false)
  }

  private static func validatePathComponent(_ value: String) throws {
    guard !value.isEmpty, value.count <= 160,
      value.range(
        of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#,
        options: .regularExpression) != nil
    else { throw CaptureCoachLiveSpoolError.corruptEntry(value) }
  }
}

public protocol CaptureCoachLivePromptReceiptEnqueuing: Sendable {
  func enqueuePromptReceipt(_ receipt: CaptureCoachLivePromptReceipt) async throws
}

extension CaptureCoachLiveExactByteSpool: CaptureCoachLivePromptReceiptEnqueuing
where Document == CaptureCoachLivePromptReceipt {
  public func enqueuePromptReceipt(_ receipt: CaptureCoachLivePromptReceipt) async throws {
    _ = try enqueue(receipt)
  }
}

public actor CaptureCoachLiveReceiptUnionSink: CaptureCoachLivePromptReceiptEnqueuing {
  private let spool: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>

  public init(
    spool: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>
  ) {
    self.spool = spool
  }

  public func enqueuePromptReceipt(_ receipt: CaptureCoachLivePromptReceipt) async throws {
    _ = try await spool.enqueue(.prompt(receipt))
  }
}
