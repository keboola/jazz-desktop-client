import Foundation

public struct CaptureCoachLiveProjectionIntent: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var promptId: String
  public var promptDigest: String
  public var prompt: CaptureCoachLivePrompt
  public var receiptId: String
  public var clientRecordedAt: String
  public var contentDigest: String

  public init(
    prompt: CaptureCoachLivePrompt,
    receiptId: String = Identifiers.newCoachLiveReceiptId(),
    clientRecordedAt: String = Timestamps.iso8601()
  ) throws {
    schemaVersion = 1
    promptId = prompt.promptId
    promptDigest = prompt.contentDigest
    self.prompt = prompt
    self.receiptId = receiptId
    self.clientRecordedAt = clientRecordedAt
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public func validate() throws {
    guard schemaVersion == 1, Timestamps.parse(clientRecordedAt) != nil else {
      throw CaptureCoachLiveContractError.invalidField("projectionIntent")
    }
    try CaptureCoachLiveValidation.uuidV7(promptId, prefix: "prompt")
    try CaptureCoachLiveValidation.sha256(
      promptDigest, field: "projectionIntent.promptDigest")
    try prompt.validate()
    guard prompt.promptId == promptId, prompt.contentDigest == promptDigest else {
      throw CaptureCoachLiveContractError.invalidField("projectionIntent.prompt")
    }
    try CaptureCoachLiveValidation.uuidV7(receiptId, prefix: "ccr")
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  private struct DigestMaterial: Codable {
    var schemaVersion: Int
    var promptId: String
    var promptDigest: String
    var prompt: CaptureCoachLivePrompt
    var receiptId: String
    var clientRecordedAt: String
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      schemaVersion: schemaVersion,
      promptId: promptId,
      promptDigest: promptDigest,
      prompt: prompt,
      receiptId: receiptId,
      clientRecordedAt: clientRecordedAt)
  }
}

/// Write-once local intent. It is committed before coordinator projection, closing the crash window
/// between canonical journal append and receipt-spool enqueue. Relaunch therefore reconstructs the
/// same receipt id and client timestamp instead of inventing a second logical receipt.
public actor CaptureCoachLiveProjectionIntentStore {
  private struct PresentationConfirmation:
    Codable, Equatable, Sendable
  {
    var schemaVersion: Int
    var promptId: String
    var confirmedAt: String

    func validate() throws {
      guard schemaVersion == 1, Timestamps.parse(confirmedAt) != nil else {
        throw CaptureCoachLiveContractError.invalidField(
          "presentationConfirmation")
      }
      try CaptureCoachLiveValidation.uuidV7(promptId, prefix: "prompt")
    }
  }
  private let root: URL
  private let fileManager: FileManager
  private let durability: JazzArchiveFilesystemDurability

  public init(
    root: URL,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) throws {
    guard root.isFileURL else { throw CaptureCoachLiveSpoolError.invalidRoot }
    self.root = root
    self.fileManager = fileManager
    self.durability = durability
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try durability.synchronizeDirectory(root)
    try durability.synchronizeDirectory(root.deletingLastPathComponent())
    try durability.synchronizeDirectory(
      root.deletingLastPathComponent().deletingLastPathComponent())
    try durability.synchronizeDirectory(
      root.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent())
  }

  public func prepare(
    prompt: CaptureCoachLivePrompt,
    at date: Date = Date()
  ) throws -> CaptureCoachLiveProjectionIntent {
    try prompt.validate()
    let destination = root.appendingPathComponent(prompt.promptId + ".json")
    if fileManager.fileExists(atPath: destination.path) {
      let data = try Data(contentsOf: destination)
      let intent: CaptureCoachLiveProjectionIntent
      do {
        intent = try JSONDecoder().decode(
          CaptureCoachLiveProjectionIntent.self, from: data)
      } catch {
        throw CaptureCoachLiveSpoolError.corruptEntry(destination.path)
      }
      try intent.validate()
      guard try JazzArchiveCanonicalJSON.encode(intent) == data,
        intent.promptId == prompt.promptId,
        intent.promptDigest == prompt.contentDigest
      else {
        throw CaptureCoachLiveSpoolError.identifierCollision(prompt.promptId)
      }
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(root)
      return intent
    }

    let intent = try CaptureCoachLiveProjectionIntent(
      prompt: prompt, clientRecordedAt: Timestamps.iso8601(date))
    let data = try JazzArchiveCanonicalJSON.encode(intent)
    let temporary = root.appendingPathComponent(
      ".intent-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }
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
    try durability.synchronizeDirectory(root)
    return intent
  }

  public func allIntents() throws -> [CaptureCoachLiveProjectionIntent] {
    try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true,
        url.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      let data = try Data(contentsOf: url)
      let intent: CaptureCoachLiveProjectionIntent
      do {
        intent = try JSONDecoder().decode(
          CaptureCoachLiveProjectionIntent.self, from: data)
      } catch {
        throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
      }
      try intent.validate()
      guard try JazzArchiveCanonicalJSON.encode(intent) == data else {
        throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
      }
      return intent
    }
  }

  /// Write-once confirmation sampled only after the real UI callback returns. It precedes `shown`
  /// in the durability order so a lost receipt can reproduce the exact envelope timestamp. If a
  /// crash occurs before `shown`, recovery still conservatively suppresses and never redisplays.
  public func confirmPresentation(
    promptId: String,
    at date: Date
  ) throws -> String {
    let proposed = PresentationConfirmation(
      schemaVersion: 1,
      promptId: promptId,
      confirmedAt: Timestamps.iso8601(date))
    try proposed.validate()
    let destination = confirmationURL(promptId)
    if fileManager.fileExists(atPath: destination.path) {
      return try readConfirmation(at: destination).confirmedAt
    }
    let data = try JazzArchiveCanonicalJSON.encode(proposed)
    let temporary = root.appendingPathComponent(
      ".presentation-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }
    guard fileManager.createFile(
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
    try durability.synchronizeDirectory(root)
    return proposed.confirmedAt
  }

  public func presentationConfirmedAt(promptId: String) throws -> String? {
    let destination = confirmationURL(promptId)
    guard fileManager.fileExists(atPath: destination.path) else { return nil }
    return try readConfirmation(at: destination).confirmedAt
  }

  private func confirmationURL(_ promptId: String) -> URL {
    root.appendingPathComponent(".presented-\(promptId).json")
  }

  private func readConfirmation(
    at url: URL
  ) throws -> PresentationConfirmation {
    let data = try Data(contentsOf: url)
    let value: PresentationConfirmation
    do {
      value = try JSONDecoder().decode(
        PresentationConfirmation.self, from: data)
    } catch {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    try value.validate()
    guard try JazzArchiveCanonicalJSON.encode(value) == data else {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    return value
  }
}

public struct CaptureCoachLiveProjectionResult: Equatable, Sendable {
  public var decision: CaptureCoachPromptDecision
  public var receipt: CaptureCoachLivePromptReceipt

  public init(
    decision: CaptureCoachPromptDecision,
    receipt: CaptureCoachLivePromptReceipt
  ) {
    self.decision = decision
    self.receipt = receipt
  }
}

public struct CaptureCoachLivePresentationTicket: Equatable, Sendable {
  public var prompt: CaptureCoachLivePrompt
  fileprivate var intent: CaptureCoachLiveProjectionIntent

  fileprivate init(
    prompt: CaptureCoachLivePrompt,
    intent: CaptureCoachLiveProjectionIntent
  ) {
    self.prompt = prompt
    self.intent = intent
  }
}

public enum CaptureCoachLivePresentationAdmission: Equatable, Sendable {
  case present(CaptureCoachLivePresentationTicket)
  case terminal(CaptureCoachLiveProjectionResult)
}

/// Actor-owned admission state extracted as a pure value so the executable runtime's reentrant
/// poll behavior is regression-testable without linking AppKit or URLSession test machinery.
public struct CaptureCoachLivePromptPollAdmissionGate: Sendable {
  private var inFlightGenerations: Set<UInt64> = []

  public init() {}

  public mutating func begin(generation: UInt64) -> Bool {
    inFlightGenerations.insert(generation).inserted
  }

  public mutating func end(generation: UInt64) {
    inFlightGenerations.remove(generation)
  }

  public static func shouldPresent(
    _ result: CaptureCoachLiveProjectionResult
  ) -> Bool {
    !result.decision.recordedInteractions.isEmpty
  }
}

/// Deterministic bridge from an authenticated strict-JCS server prompt to canonical local
/// interactions and an exact-byte receipt. It owns no network or UI APIs.
public actor CaptureCoachLivePromptProjector {
  private let coordinator: CaptureCoachCoordinator
  private let intents: CaptureCoachLiveProjectionIntentStore
  private let receipts: any CaptureCoachLivePromptReceiptEnqueuing

  public init(
    coordinator: CaptureCoachCoordinator,
    intents: CaptureCoachLiveProjectionIntentStore,
    receipts: any CaptureCoachLivePromptReceiptEnqueuing
  ) {
    self.coordinator = coordinator
    self.intents = intents
    self.receipts = receipts
  }

  public func project(
    _ prompt: CaptureCoachLivePrompt,
    at date: Date = Date()
  ) async throws -> CaptureCoachLiveProjectionResult {
    switch try await beginPresentation(prompt, at: date) {
    case .present(let ticket):
      return try await confirmPresented(ticket, at: date)
    case .terminal(let result):
      return result
    }
  }

  /// Durably records receipt of a prompt and returns a single presentation ticket. No `shown`
  /// interaction or receipt exists until `confirmPresented` is called after the real UI boundary.
  public func beginPresentation(
    _ prompt: CaptureCoachLivePrompt,
    at date: Date = Date()
  ) async throws -> CaptureCoachLivePresentationAdmission {
    try prompt.validate()
    let intent = try await intents.prepare(prompt: prompt, at: date)
    if let decision = try await coordinator.beginPresentation(
      prompt.domainPrompt, at: date)
    {
      let receiptRecordedAt: String?
      if decision.disposition == .shown {
        receiptRecordedAt =
          try await intents.presentationConfirmedAt(
            promptId: prompt.promptId)
      } else {
        receiptRecordedAt = nil
      }
      return .terminal(
        try await finish(
          prompt: prompt,
          intent: intent,
          decision: decision,
          clientRecordedAt: receiptRecordedAt))
    }
    return .present(
      CaptureCoachLivePresentationTicket(prompt: prompt, intent: intent))
  }

  public func confirmPresented(
    _ ticket: CaptureCoachLivePresentationTicket,
    at date: Date = Date()
  ) async throws -> CaptureCoachLiveProjectionResult {
    let confirmedAt = try await intents.confirmPresentation(
      promptId: ticket.prompt.promptId, at: date)
    guard let confirmedDate = Timestamps.parse(confirmedAt) else {
      throw CaptureCoachLiveContractError.invalidField(
        "presentationConfirmation.confirmedAt")
    }
    let decision = try await coordinator.confirmPresentation(
      promptId: ticket.prompt.promptId, at: confirmedDate)
    return try await finish(
      prompt: ticket.prompt,
      intent: ticket.intent,
      decision: decision,
      clientRecordedAt: confirmedAt)
  }

  public func recoverInterrupted(
    _ prompt: CaptureCoachLivePrompt
  ) async throws -> CaptureCoachLiveProjectionResult {
    try prompt.validate()
    let intent = try await intents.prepare(prompt: prompt)
    guard let recordedAt = Timestamps.parse(intent.clientRecordedAt) else {
      throw CaptureCoachLiveContractError.invalidField(
        "projectionIntent.clientRecordedAt")
    }
    let decision = try await coordinator.recoverInterruptedPrompt(
      prompt.domainPrompt, at: recordedAt)
    let receiptRecordedAt: String
    if decision.disposition == .shown {
      // Pre-two-phase intents have no confirmation sidecar; their original timestamp remains the
      // only byte-stable recovery value. New presentations always take the first branch.
      receiptRecordedAt =
        try await intents.presentationConfirmedAt(promptId: prompt.promptId)
        ?? intent.clientRecordedAt
    } else {
      receiptRecordedAt = intent.clientRecordedAt
    }
    return try await finish(
      prompt: prompt,
      intent: intent,
      decision: decision,
      clientRecordedAt: receiptRecordedAt)
  }

  private func finish(
    prompt: CaptureCoachLivePrompt,
    intent: CaptureCoachLiveProjectionIntent,
    decision: CaptureCoachPromptDecision,
    clientRecordedAt: String? = nil
  ) async throws -> CaptureCoachLiveProjectionResult {
    let action: CaptureCoachLivePromptReceiptAction
    let reason: CaptureCoachDispositionReason?
    let types: [CaptureCoachInteractionType]
    switch decision.disposition {
    case .shown:
      action = .shown
      reason = nil
      types = [.received, .shown]
    case .suppressed(let value):
      action = .suppressed
      reason = value
      types =
        value == .interruptedCapture
          && decision.canonicalInteractionIds.count == 2
        ? [.received, .suppressed] : [.suppressed]
    }
    guard decision.canonicalInteractionIds.count == types.count else {
      throw CaptureCoachCoordinatorError.corruptHistory(
        "prompt \(prompt.promptId) has incomplete disposition evidence")
    }
    let references = zip(decision.canonicalInteractionIds, types).map {
      CaptureCoachLiveCanonicalInteractionRef(
        interactionId: $0.0, interactionType: $0.1)
    }
    let receipt = try CaptureCoachLivePromptReceipt(
      receiptId: intent.receiptId,
      scope: prompt.scope,
      prompt: prompt,
      action: action,
      suppressionReason: reason,
      canonicalInteractions: references,
      occurredAt: decision.dispositionOccurredAt,
      clientRecordedAt: clientRecordedAt ?? intent.clientRecordedAt)
    try await receipts.enqueuePromptReceipt(receipt)
    return CaptureCoachLiveProjectionResult(
      decision: decision, receipt: receipt)
  }
}

public struct CaptureCoachLiveActionProjectionIntent: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var interactionId: String
  public var interactionType: CaptureCoachInteractionType
  public var receiptId: String
  public var clientRecordedAt: String
  public var prompt: CaptureCoachLivePrompt?
  public var scope: CaptureCoachLiveScope?
  public var captureId: String?
  public var labelId: String?
  public var inputWatermark: CaptureCoachInputWatermark?
  public var contentDigest: String

  public init(
    prompt: CaptureCoachLivePrompt,
    interactionType: CaptureCoachInteractionType,
    interactionId: String = Identifiers.newCoachInteractionId(),
    receiptId: String = Identifiers.newCoachLiveReceiptId(),
    at date: Date = Date()
  ) throws {
    schemaVersion = 1
    self.interactionId = interactionId
    self.interactionType = interactionType
    self.receiptId = receiptId
    clientRecordedAt = Timestamps.iso8601(date)
    self.prompt = prompt
    scope = nil
    captureId = nil
    labelId = nil
    inputWatermark = nil
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public init(
    scope: CaptureCoachLiveScope,
    captureId: String,
    labelId: String,
    inputWatermark: CaptureCoachInputWatermark,
    interactionType: CaptureCoachInteractionType,
    interactionId: String = Identifiers.newCoachInteractionId(),
    receiptId: String = Identifiers.newCoachLiveReceiptId(),
    at date: Date = Date()
  ) throws {
    schemaVersion = 1
    self.interactionId = interactionId
    self.interactionType = interactionType
    self.receiptId = receiptId
    clientRecordedAt = Timestamps.iso8601(date)
    prompt = nil
    self.scope = scope
    self.captureId = captureId
    self.labelId = labelId
    self.inputWatermark = inputWatermark
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public func validate() throws {
    guard schemaVersion == 1, Timestamps.parse(clientRecordedAt) != nil else {
      throw CaptureCoachLiveContractError.invalidField("actionProjectionIntent")
    }
    try CaptureCoachLiveValidation.uuidV7(interactionId, prefix: "coach")
    try CaptureCoachLiveValidation.uuidV7(receiptId, prefix: "ccr")
    switch interactionType {
    case .answered, .dismissed:
      guard let prompt, scope == nil, captureId == nil, labelId == nil,
        inputWatermark == nil
      else {
        throw CaptureCoachLiveContractError.invalidField(
          "actionProjectionIntent.prompt")
      }
      try prompt.validate()
    case .muted, .resumed, .finishAnyway:
      guard prompt == nil, let scope, let captureId, let labelId,
        let inputWatermark
      else {
        throw CaptureCoachLiveContractError.invalidField(
          "actionProjectionIntent.scope")
      }
      try scope.validate()
      try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
      try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
      try inputWatermark.validate()
      guard inputWatermark.schemaVersion == 2,
        inputWatermark.captureId == captureId
      else {
        throw CaptureCoachLiveContractError.invalidField(
          "actionProjectionIntent.watermark")
      }
    default:
      throw CaptureCoachLiveContractError.invalidField(
        "actionProjectionIntent.interactionType")
    }
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  private struct DigestMaterial: Codable {
    var schemaVersion: Int
    var interactionId: String
    var interactionType: CaptureCoachInteractionType
    var receiptId: String
    var clientRecordedAt: String
    var prompt: CaptureCoachLivePrompt?
    var scope: CaptureCoachLiveScope?
    var captureId: String?
    var labelId: String?
    var inputWatermark: CaptureCoachInputWatermark?
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      schemaVersion: schemaVersion,
      interactionId: interactionId,
      interactionType: interactionType,
      receiptId: receiptId,
      clientRecordedAt: clientRecordedAt,
      prompt: prompt,
      scope: scope,
      captureId: captureId,
      labelId: labelId,
      inputWatermark: inputWatermark)
  }
}

public struct CaptureCoachLiveActionRecoveryBinding: Codable, Equatable, Sendable {
  public var archiveId: String
  public var captureId: String

  public init(archiveId: String, captureId: String) throws {
    self.archiveId = archiveId
    self.captureId = captureId
    try validate()
  }

  public func validate() throws {
    try CaptureCoachLiveValidation.uuidV7(archiveId, prefix: "ar")
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
  }
}

private struct CaptureCoachLiveActionRecoveryMarker:
  Codable, Equatable, Sendable
{
  var schemaVersion: Int
  var binding: CaptureCoachLiveActionRecoveryBinding
  var contentDigest: String

  init(binding: CaptureCoachLiveActionRecoveryBinding) throws {
    schemaVersion = 1
    self.binding = binding
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  func validate() throws {
    guard schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.invalidField(
        "actionRecoveryMarker.schemaVersion")
    }
    try binding.validate()
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  private struct DigestMaterial: Codable {
    var schemaVersion: Int
    var binding: CaptureCoachLiveActionRecoveryBinding
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(schemaVersion: schemaVersion, binding: binding)
  }
}

public actor CaptureCoachLiveActionProjectionIntentStore {
  private let root: URL
  private let fileManager: FileManager
  private let durability: JazzArchiveFilesystemDurability
  private let recoveryBinding: CaptureCoachLiveActionRecoveryBinding?
  private let markerURL: URL
  private let committedURL: URL
  private let projectedRoot: URL
  private let interactionRoot: URL
  private let recoveryIndexRoot: URL

  public init(
    root: URL,
    recoveryBinding: CaptureCoachLiveActionRecoveryBinding? = nil,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) throws {
    guard root.isFileURL else { throw CaptureCoachLiveSpoolError.invalidRoot }
    self.root = root
    self.fileManager = fileManager
    self.durability = durability
    self.recoveryBinding = recoveryBinding
    markerURL = root.appendingPathComponent("recovery-needed.json")
    committedURL = root.appendingPathComponent("capture-committed.json")
    projectedRoot = root.appendingPathComponent("projected", isDirectory: true)
    interactionRoot = root.appendingPathComponent(
      "canonical-interactions", isDirectory: true)
    let captureRoot = root.deletingLastPathComponent()
    let capturesRoot = captureRoot.deletingLastPathComponent()
    if capturesRoot.lastPathComponent == "captures" {
      recoveryIndexRoot =
        capturesRoot.deletingLastPathComponent()
        .appendingPathComponent("action-recovery-index", isDirectory: true)
    } else {
      // Standalone Foundation tests and embedders never write above their supplied root.
      recoveryIndexRoot = root.appendingPathComponent(
        ".action-recovery-index", isDirectory: true)
    }
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: projectedRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: interactionRoot, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: recoveryIndexRoot, withIntermediateDirectories: true)
    try durability.synchronizeDirectory(projectedRoot)
    try durability.synchronizeDirectory(interactionRoot)
    try durability.synchronizeDirectory(recoveryIndexRoot)
    try durability.synchronizeDirectory(root)
    try durability.synchronizeDirectory(root.deletingLastPathComponent())
    try durability.synchronizeDirectory(
      root.deletingLastPathComponent().deletingLastPathComponent())
    try durability.synchronizeDirectory(
      root.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent())
  }

  @discardableResult
  public func prepare(
    _ proposed: CaptureCoachLiveActionProjectionIntent
  ) throws -> CaptureCoachLiveActionProjectionIntent {
    try proposed.validate()
    try ensureRecoveryMarker()
    let destination = url(proposed.interactionId)
    if fileManager.fileExists(atPath: destination.path) {
      let existing = try decode(destination)
      guard existing == proposed else {
        throw CaptureCoachLiveSpoolError.identifierCollision(
          proposed.interactionId)
      }
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      try durability.synchronizeDirectory(root)
      return existing
    }
    let data = try JazzArchiveCanonicalJSON.encode(proposed)
    let temporary = root.appendingPathComponent(
      ".intent-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }
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
    try durability.synchronizeDirectory(root)
    return proposed
  }

  public func intent(
    for interactionId: String
  ) throws -> CaptureCoachLiveActionProjectionIntent? {
    let location = url(interactionId)
    guard fileManager.fileExists(atPath: location.path) else { return nil }
    return try decode(location)
  }

  public func recoveryBindingIfNeeded()
    throws -> CaptureCoachLiveActionRecoveryBinding?
  {
    guard fileManager.fileExists(atPath: markerURL.path) else { return nil }
    return try readRecoveryMarker(at: markerURL).binding
  }

  public func indexedRecoveryBinding()
    throws -> CaptureCoachLiveActionRecoveryBinding?
  {
    let recoveryIndexURL = try resolvedRecoveryIndexURL()
    guard fileManager.fileExists(atPath: recoveryIndexURL.path) else {
      return nil
    }
    return try readRecoveryMarker(at: recoveryIndexURL).binding
  }

  public func restoreLocalMarkerFromIndex() throws {
    guard let binding = try indexedRecoveryBinding() else { return }
    let marker = try CaptureCoachLiveActionRecoveryMarker(binding: binding)
    if !fileManager.fileExists(atPath: markerURL.path) {
      try publishCanonical(
        try JazzArchiveCanonicalJSON.encode(marker), at: markerURL)
    }
  }

  /// Saves the exact canonical interaction beside its intent before receipt projection. This makes
  /// finalized-archive recovery bounded to unresolved markers and avoids reopening a whole
  /// immutable archive merely to reconstruct a small receipt reference.
  public func recordCanonicalInteraction(
    _ interaction: CaptureCoachInteraction
  ) throws {
    try interaction.validate()
    guard let intent = try intent(for: interaction.interactionId),
      intent.interactionType == interaction.interactionType,
      intent.clientRecordedAt == interaction.occurredAt
    else {
      throw CaptureCoachLiveSpoolError.identifierCollision(
        interaction.interactionId)
    }
    try publishCanonical(
      try JazzArchiveCanonicalJSON.encode(interaction),
      at: interactionURL(interaction.interactionId))
  }

  public func recoveredCanonicalInteractions()
    throws -> [CaptureCoachInteraction]
  {
    let unresolved = try unresolvedIntents()
    return try unresolved.compactMap { intent in
      let location = interactionURL(intent.interactionId)
      guard fileManager.fileExists(atPath: location.path) else { return nil }
      let data = try Data(contentsOf: location)
      let interaction: CaptureCoachInteraction
      do {
        interaction = try JSONDecoder().decode(
          CaptureCoachInteraction.self, from: data)
      } catch {
        throw CaptureCoachLiveSpoolError.corruptEntry(location.path)
      }
      try interaction.validate()
      guard try JazzArchiveCanonicalJSON.encode(interaction) == data,
        interaction.interactionId == intent.interactionId,
        interaction.interactionType == intent.interactionType,
        interaction.occurredAt == intent.clientRecordedAt
      else { throw CaptureCoachLiveSpoolError.corruptEntry(location.path) }
      return interaction
    }
  }

  public func unresolvedInteractionIds() throws -> Set<String> {
    Set(try unresolvedIntents().map(\.interactionId))
  }

  /// Called only after the exact receipt bytes are durable. Per-intent completion is published
  /// first; the capture marker is retired last and directory-fsynced. Every crash cut therefore
  /// either repeats an idempotent enqueue or leaves no unresolved intent.
  public func markProjected(_ interactionId: String) throws {
    guard try intent(for: interactionId) != nil else {
      throw CaptureCoachLiveSpoolError.corruptEntry(interactionId)
    }
    try publishCanonical(
      Data("capture-coach-action-projected-v1\n".utf8),
      at: projectedURL(interactionId))
    try finishRetirementIfEligible()
  }

  /// The caller invokes this only after the canonical local CaptureCommit is durable. The recovery
  /// root marker is therefore never retired merely because advisory receipt bytes were enqueued.
  public func markCaptureCommitted() throws {
    let resolvedBinding: CaptureCoachLiveActionRecoveryBinding?
    if let recoveryBinding {
      resolvedBinding = recoveryBinding
    } else {
      resolvedBinding = try recoveryBindingIfNeeded()
    }
    guard let recoveryBinding = resolvedBinding else { return }
    let marker = try CaptureCoachLiveActionRecoveryMarker(
      binding: recoveryBinding)
    try publishCanonical(
      try JazzArchiveCanonicalJSON.encode(marker), at: committedURL)
    try finishRetirementIfEligible()
  }

  public func resumeRetirementIfEligible() throws {
    try finishRetirementIfEligible()
  }

  private func finishRetirementIfEligible() throws {
    guard fileManager.fileExists(atPath: markerURL.path) else { return }
    let localMarker = try readRecoveryMarker(at: markerURL)
    let recoveryIndexURL = recoveryIndexURL(for: localMarker.binding)
    guard fileManager.fileExists(atPath: committedURL.path),
      fileManager.fileExists(atPath: recoveryIndexURL.path),
      try Data(contentsOf: committedURL) == Data(contentsOf: markerURL),
      try Data(contentsOf: recoveryIndexURL) == Data(contentsOf: markerURL),
      try unresolvedIntents().isEmpty
    else { return }
    if fileManager.fileExists(atPath: markerURL.path) {
      try fileManager.removeItem(at: markerURL)
      try durability.synchronizeDirectory(root)
      try durability.synchronizeDirectory(root.deletingLastPathComponent())
    }
    if fileManager.fileExists(atPath: recoveryIndexURL.path) {
      try fileManager.removeItem(at: recoveryIndexURL)
      try durability.synchronizeDirectory(recoveryIndexRoot)
      try durability.synchronizeDirectory(
        recoveryIndexRoot.deletingLastPathComponent())
    }
  }

  private func ensureRecoveryMarker() throws {
    guard let recoveryBinding else { return }
    let recoveryIndexURL = recoveryIndexURL(for: recoveryBinding)
    let marker = try CaptureCoachLiveActionRecoveryMarker(
      binding: recoveryBinding)
    try publishCanonical(
      try JazzArchiveCanonicalJSON.encode(marker), at: recoveryIndexURL)
    if fileManager.fileExists(atPath: markerURL.path) {
      guard try recoveryBindingIfNeeded() == recoveryBinding else {
        throw CaptureCoachLiveSpoolError.identifierCollision(
          recoveryBinding.captureId)
      }
      return
    }
    try publishCanonical(
      try JazzArchiveCanonicalJSON.encode(marker), at: markerURL)
  }

  private func readRecoveryMarker(
    at url: URL
  ) throws -> CaptureCoachLiveActionRecoveryMarker {
    let data = try Data(contentsOf: url)
    let marker: CaptureCoachLiveActionRecoveryMarker
    do {
      marker = try JSONDecoder().decode(
        CaptureCoachLiveActionRecoveryMarker.self, from: data)
    } catch {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    try marker.validate()
    guard try JazzArchiveCanonicalJSON.encode(marker) == data else {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    return marker
  }

  private func resolvedRecoveryIndexURL() throws -> URL {
    if let recoveryBinding {
      return recoveryIndexURL(for: recoveryBinding)
    }
    if fileManager.fileExists(atPath: markerURL.path) {
      return recoveryIndexURL(
        for: try readRecoveryMarker(at: markerURL).binding)
    }
    return recoveryIndexURL(
      captureId: root.deletingLastPathComponent().lastPathComponent)
  }

  private func recoveryIndexURL(
    for binding: CaptureCoachLiveActionRecoveryBinding
  ) -> URL {
    recoveryIndexURL(captureId: binding.captureId)
  }

  private func recoveryIndexURL(captureId: String) -> URL {
    recoveryIndexRoot.appendingPathComponent(captureId + ".json")
  }

  private func allIntents() throws -> [CaptureCoachLiveActionProjectionIntent] {
    let entries = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    return try entries.compactMap { entry in
      guard entry.pathExtension == "json",
        entry.lastPathComponent.hasPrefix("coach-")
      else { return nil }
      return try decode(entry)
    }
  }

  private func unresolvedIntents()
    throws -> [CaptureCoachLiveActionProjectionIntent]
  {
    try allIntents().filter {
      !fileManager.fileExists(atPath: projectedURL($0.interactionId).path)
    }
  }

  private func projectedURL(_ interactionId: String) -> URL {
    projectedRoot.appendingPathComponent(interactionId + ".done")
  }

  private func interactionURL(_ interactionId: String) -> URL {
    interactionRoot.appendingPathComponent(interactionId + ".json")
  }

  private func publishCanonical(_ data: Data, at destination: URL) throws {
    if fileManager.fileExists(atPath: destination.path) {
      guard try Data(contentsOf: destination) == data else {
        throw CaptureCoachLiveSpoolError.identifierCollision(
          destination.deletingPathExtension().lastPathComponent)
      }
      try durability.synchronizeRegularFile(
        destination, permissions: Int16(0o600))
      return
    }
    let temporary = root.appendingPathComponent(
      ".recovery-\(Identifiers.newUUIDv7().uuidString.lowercased())")
    var keepTemporary = true
    defer { if keepTemporary { try? fileManager.removeItem(at: temporary) } }
    guard fileManager.createFile(
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

  private func decode(_ url: URL) throws -> CaptureCoachLiveActionProjectionIntent {
    let data = try Data(contentsOf: url)
    let value: CaptureCoachLiveActionProjectionIntent
    do {
      value = try JSONDecoder().decode(
        CaptureCoachLiveActionProjectionIntent.self, from: data)
    } catch {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    try value.validate()
    guard try JazzArchiveCanonicalJSON.encode(value) == data else {
      throw CaptureCoachLiveSpoolError.corruptEntry(url.path)
    }
    return value
  }

  private func url(_ interactionId: String) -> URL {
    root.appendingPathComponent(interactionId + ".json")
  }
}

/// Projects post-display user/control actions from precommitted intents. Recovery may replay every
/// canonical interaction; missing intents are ignored (local-baseline actions), while matching
/// live intents enqueue exactly one globally collision-fenced receipt.
public actor CaptureCoachLiveActionReceiptProjector {
  private let intents: CaptureCoachLiveActionProjectionIntentStore
  private let receipts: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>

  public init(
    intents: CaptureCoachLiveActionProjectionIntentStore,
    receipts: CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>
  ) {
    self.intents = intents
    self.receipts = receipts
  }

  public func project(_ interaction: CaptureCoachInteraction) async throws {
    guard
      let intent = try await intents.intent(
        for: interaction.interactionId)
    else { return }
    guard interaction.interactionId == intent.interactionId,
      interaction.interactionType == intent.interactionType,
      interaction.occurredAt == intent.clientRecordedAt
    else {
      throw CaptureCoachLiveSpoolError.identifierCollision(
        interaction.interactionId)
    }
    try await intents.recordCanonicalInteraction(interaction)
    switch intent.interactionType {
    case .answered, .dismissed:
      let prompt = try require(intent.prompt, "prompt")
      guard interaction.promptId == prompt.promptId,
        interaction.labelId == prompt.labelId,
        interaction.assessmentRef == prompt.assessmentRef,
        interaction.inputWatermark == prompt.inputWatermark
      else {
        throw CaptureCoachLiveContractError.invalidField(
          "action receipt prompt context")
      }
      let action: CaptureCoachLivePromptReceiptAction =
        intent.interactionType == .answered ? .answered : .dismissed
      let receipt = try CaptureCoachLivePromptReceipt(
        receiptId: intent.receiptId,
        scope: prompt.scope,
        prompt: prompt,
        action: action,
        canonicalInteractions: [
          CaptureCoachLiveCanonicalInteractionRef(
            interactionId: interaction.interactionId,
            interactionType: interaction.interactionType)
        ],
        occurredAt: interaction.occurredAt,
        clientRecordedAt: intent.clientRecordedAt)
      _ = try await receipts.enqueue(.prompt(receipt))
    case .muted, .resumed, .finishAnyway:
      let scope = try require(intent.scope, "scope")
      let captureId = try require(intent.captureId, "captureId")
      let labelId = try require(intent.labelId, "labelId")
      let watermark = try require(intent.inputWatermark, "inputWatermark")
      let action: CaptureCoachLiveScopeControlAction
      switch intent.interactionType {
      case .muted: action = .muted
      case .resumed: action = .resumed
      case .finishAnyway: action = .finishAnyway
      default: fatalError("validated above")
      }
      let receipt = try CaptureCoachLiveScopeControlReceipt(
        receiptId: intent.receiptId,
        scope: scope,
        captureId: captureId,
        labelId: labelId,
        inputWatermark: watermark,
        action: action,
        canonicalInteraction: CaptureCoachLiveCanonicalInteractionRef(
          interactionId: interaction.interactionId,
          interactionType: interaction.interactionType),
        occurredAt: interaction.occurredAt,
        clientRecordedAt: intent.clientRecordedAt)
      _ = try await receipts.enqueue(.scopeControl(receipt))
    default:
      throw CaptureCoachLiveContractError.invalidField(
        "action receipt interactionType")
    }
    try await intents.markProjected(interaction.interactionId)
  }

  public func recover(_ interactions: [CaptureCoachInteraction]) async throws {
    for interaction in interactions {
      try await project(interaction)
    }
  }

  private func require<Value>(_ value: Value?, _ field: String) throws -> Value {
    guard let value else {
      throw CaptureCoachLiveContractError.invalidField(
        "actionProjectionIntent.\(field)")
    }
    return value
  }
}
