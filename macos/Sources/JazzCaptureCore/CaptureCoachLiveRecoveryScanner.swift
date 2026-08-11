import Foundation

/// Repairs the append-before-receipt crash window for interrupted captures. It discovers every
/// route partition locally, replays only canonical coach interactions into matching write-once
/// intents, and never needs a credential or network connection.
public enum CaptureCoachLiveRecoveryScanner {
  public struct ActionRecoveryScanResult: Equatable, Sendable {
    public var unresolvedCaptureMarkers: Int
    public var canonicalArchiveReads: Int

    public init(
      unresolvedCaptureMarkers: Int = 0,
      canonicalArchiveReads: Int = 0
    ) {
      self.unresolvedCaptureMarkers = unresolvedCaptureMarkers
      self.canonicalArchiveReads = canonicalArchiveReads
    }
  }
  /// Repairs every prompt-intent crash state while the interrupted draft is still mutable:
  /// intent-only and received-only become truthful interrupted suppressions; a completed shown
  /// decision merely reconstructs its exact receipt.
  public static func recoverPromptReceipts(
    liveRoot: URL,
    archiveRoot: URL,
    archiveId: String,
    captureId: String,
    journal: CaptureJournal,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) async throws {
    let store = JazzArchiveDraftStore(
      root: archiveRoot, durability: durability, fileManager: fileManager)
    let manifest = try await store.manifest(archiveId: archiveId)
    let session = try await store.session(
      archiveId: archiveId, captureId: captureId)
    let partitions = liveRoot.appendingPathComponent(
      "partitions", isDirectory: true)
    guard fileManager.fileExists(atPath: partitions.path) else { return }

    for partition in try safeDirectories(
      at: partitions, fileManager: fileManager)
    {
      let intentRoot =
        partition
        .appendingPathComponent("captures", isDirectory: true)
        .appendingPathComponent(captureId, isDirectory: true)
        .appendingPathComponent("prompt-intents", isDirectory: true)
      guard fileManager.fileExists(atPath: intentRoot.path) else { continue }
      let intentStore = try CaptureCoachLiveProjectionIntentStore(
        root: intentRoot,
        durability: durability,
        fileManager: fileManager)
      let intents = try await intentStore.allIntents().sorted {
        ($0.clientRecordedAt, $0.promptId)
          < ($1.clientRecordedAt, $1.promptId)
      }
      guard !intents.isEmpty else { continue }

      let records = try await store.allRecords(
        archiveId: archiveId, captureId: captureId)
      let interactions = try records.compactMap {
        record -> CaptureCoachInteraction? in
        guard
          record.recordType
            == ArchiveRecord<CaptureCoachInteraction>.coachRecordType
        else { return nil }
        return try record.coachInteractionRecord().payload
      }
      let writer = CaptureCoachJournalWriter(
        journal: journal,
        context: try recoveryRecordContext(
          manifest: manifest, session: session, records: records))
      let coordinator = try CaptureCoachCoordinator(
        captureId: captureId,
        recorder: writer,
        recoveredInteractions: interactions)
      let receipts = try CaptureCoachLiveExactByteSpool<
        CaptureCoachLiveReceiptDocument
      >(
        root: partition.appendingPathComponent(
          "receipts", isDirectory: true),
        globalCollisionRoot:
          liveRoot
          .appendingPathComponent("identity", isDirectory: true)
          .appendingPathComponent("receipts", isDirectory: true),
        durability: durability,
        fileManager: fileManager)
      let projector = CaptureCoachLivePromptProjector(
        coordinator: coordinator,
        intents: intentStore,
        receipts: CaptureCoachLiveReceiptUnionSink(spool: receipts))
      for intent in intents {
        _ = try await projector.recoverInterrupted(intent.prompt)
      }
    }
  }

  public static func recoverActionReceipts(
    liveRoot: URL,
    archiveRoot: URL,
    archiveId: String,
    captureId: String,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) async throws {
    let store = JazzArchiveDraftStore(
      root: archiveRoot, durability: durability, fileManager: fileManager)
    let records = try await store.allRecords(
      archiveId: archiveId, captureId: captureId)
    let interactions = try records.compactMap { record -> CaptureCoachInteraction? in
      guard record.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType else {
        return nil
      }
      return try record.coachInteractionRecord().payload
    }
    guard !interactions.isEmpty else { return }

    let partitions = liveRoot.appendingPathComponent("partitions", isDirectory: true)
    guard fileManager.fileExists(atPath: partitions.path) else { return }
    for partition in try fileManager.contentsOfDirectory(
      at: partitions,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles])
    {
      let values = try partition.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else {
        continue
      }
      let captureRoot =
        partition
        .appendingPathComponent("captures", isDirectory: true)
        .appendingPathComponent(captureId, isDirectory: true)
      let intentRoot = captureRoot.appendingPathComponent(
        "action-intents", isDirectory: true)
      guard fileManager.fileExists(atPath: intentRoot.path) else { continue }
      let receipts = try CaptureCoachLiveExactByteSpool<CaptureCoachLiveReceiptDocument>(
        root: partition.appendingPathComponent("receipts", isDirectory: true),
        globalCollisionRoot:
          liveRoot
          .appendingPathComponent("identity", isDirectory: true)
          .appendingPathComponent("receipts", isDirectory: true),
        durability: durability,
        fileManager: fileManager)
      let projector = CaptureCoachLiveActionReceiptProjector(
        intents: try CaptureCoachLiveActionProjectionIntentStore(
          root: intentRoot,
          durability: durability,
          fileManager: fileManager),
        receipts: receipts)
      try await projector.recover(interactions)
    }
  }

  /// Retires an action-recovery root only after the caller has durably committed the canonical
  /// capture. Per-intent receipt completion was published earlier; either ordering crash simply
  /// leaves the root marker for the next idempotent sweep.
  public static func markActionCaptureCommitted(
    liveRoot: URL,
    captureId: String,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) async throws {
    let partitions = liveRoot.appendingPathComponent(
      "partitions", isDirectory: true)
    guard fileManager.fileExists(atPath: partitions.path) else { return }
    for partition in try safeDirectories(
      at: partitions, fileManager: fileManager)
    {
      let intentRoot =
        partition
        .appendingPathComponent("captures", isDirectory: true)
        .appendingPathComponent(captureId, isDirectory: true)
        .appendingPathComponent("action-intents", isDirectory: true)
      guard fileManager.fileExists(atPath: intentRoot.path) else { continue }
      let store = try CaptureCoachLiveActionProjectionIntentStore(
        root: intentRoot, durability: durability, fileManager: fileManager)
      if try await store.recoveryBindingIfNeeded() != nil {
        try await store.markCaptureCommitted()
      }
    }
  }

  /// Intent-driven relaunch sweep over the bounded per-partition recovery index. A committed draft
  /// remains addressable by exact archive/capture identity even after it disappears from
  /// `recoverableArchiveIds()`; finalized archive snapshots are never searched.
  public static func recoverAllActionReceipts(
    liveRoot: URL,
    archiveRoot: URL,
    durability: JazzArchiveFilesystemDurability,
    fileManager: FileManager = .default
  ) async throws -> ActionRecoveryScanResult {
    var result = ActionRecoveryScanResult()
    let partitionsRoot = liveRoot.appendingPathComponent(
      "partitions", isDirectory: true)
    guard fileManager.fileExists(atPath: partitionsRoot.path) else {
      return result
    }
    let draftStore = JazzArchiveDraftStore(
      root: archiveRoot, durability: durability, fileManager: fileManager)

    for partition in try safeDirectories(
      at: partitionsRoot, fileManager: fileManager)
    {
      let recoveryIndex = partition.appendingPathComponent(
        "action-recovery-index", isDirectory: true)
      guard fileManager.fileExists(atPath: recoveryIndex.path) else { continue }
      for indexedMarker in try safeJSONFiles(
        at: recoveryIndex, fileManager: fileManager)
      {
        let captureId = indexedMarker.deletingPathExtension().lastPathComponent
        try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
        let intentRoot =
          partition
          .appendingPathComponent("captures", isDirectory: true)
          .appendingPathComponent(captureId, isDirectory: true)
          .appendingPathComponent(
          "action-intents", isDirectory: true)
        guard fileManager.fileExists(atPath: intentRoot.path) else {
          throw CaptureCoachLiveSpoolError.corruptEntry(intentRoot.path)
        }
        let intentStore = try CaptureCoachLiveActionProjectionIntentStore(
          root: intentRoot,
          durability: durability,
          fileManager: fileManager)
        guard
          let binding = try await intentStore.indexedRecoveryBinding()
        else {
          throw CaptureCoachLiveSpoolError.corruptEntry(indexedMarker.path)
        }
        result.unresolvedCaptureMarkers += 1
        try await intentStore.restoreLocalMarkerFromIndex()
        try await intentStore.resumeRetirementIfEligible()
        guard try await intentStore.indexedRecoveryBinding() != nil else {
          continue
        }
        guard binding.captureId == captureId else {
          throw CaptureCoachLiveSpoolError.identifierCollision(captureId)
        }

        var interactionsById = Dictionary(
          uniqueKeysWithValues:
            try await intentStore.recoveredCanonicalInteractions().map {
              ($0.interactionId, $0)
            })
        let unresolved = try await intentStore.unresolvedInteractionIds()
        let missing = unresolved.subtracting(interactionsById.keys)
        if !missing.isEmpty {
          // A canonical append may have won the crash race immediately before the sidecar write.
          // Only the exact draft named by the durable marker is opened; finalized archives never
          // need a full snapshot because normal close and interrupted recovery publish sidecars
          // before CaptureCommit/finalization.
          if let records = try? await draftStore.allRecords(
            archiveId: binding.archiveId, captureId: captureId)
          {
            result.canonicalArchiveReads += 1
            var fromDraft: [String: CaptureCoachInteraction] = [:]
            try mergeInteractions(records, into: &fromDraft)
            for interactionId in missing {
              guard let interaction = fromDraft[interactionId] else { continue }
              try await intentStore.recordCanonicalInteraction(interaction)
              interactionsById[interactionId] = interaction
            }
          }
        }
        guard unresolved.isSubset(of: interactionsById.keys) else {
          // Leave the marker intact. This is an integrity/recovery condition, never permission to
          // scan unrelated archives or invent a canonical user action.
          throw CaptureCoachLiveSpoolError.corruptEntry(intentRoot.path)
        }

        let receipts = try CaptureCoachLiveExactByteSpool<
          CaptureCoachLiveReceiptDocument
        >(
          root: partition.appendingPathComponent("receipts", isDirectory: true),
          globalCollisionRoot:
            liveRoot
            .appendingPathComponent("identity", isDirectory: true)
            .appendingPathComponent("receipts", isDirectory: true),
          durability: durability,
          fileManager: fileManager)
        let projector = CaptureCoachLiveActionReceiptProjector(
          intents: intentStore,
          receipts: receipts)
        try await projector.recover(
          interactionsById.values.sorted {
            ($0.occurredAt, $0.interactionId)
              < ($1.occurredAt, $1.interactionId)
          })
        if (try? await draftStore.captureCommit(
          archiveId: binding.archiveId, captureId: captureId)) != nil
        {
          try await intentStore.markCaptureCommitted()
        }
      }
    }
    return result
  }

  private static func safeDirectories(
    at root: URL,
    fileManager: FileManager
  ) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).filter { url in
      guard
        let values = try? url.resourceValues(
          forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      else { return false }
      return values.isDirectory == true && values.isSymbolicLink != true
    }
  }

  private static func safeJSONFiles(
    at root: URL,
    fileManager: FileManager
  ) throws -> [URL] {
    try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true,
        values.isSymbolicLink != true,
        url.pathExtension == "json"
      else { throw CaptureCoachLiveSpoolError.corruptEntry(url.path) }
      return url
    }
  }

  private static func mergeInteractions(
    _ records: [JazzArchiveRecord],
    into interactions: inout [String: CaptureCoachInteraction]
  ) throws {
    for record in records
    where record.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType {
      let interaction = try record.coachInteractionRecord().payload
      if let existing = interactions[interaction.interactionId] {
        guard existing == interaction else {
          throw CaptureCoachLiveSpoolError.identifierCollision(
            interaction.interactionId)
        }
      } else {
        interactions[interaction.interactionId] = interaction
      }
    }
  }

  private static func recoveryRecordContext(
    manifest: JazzArchiveManifest,
    session: JazzArchiveSession,
    records: [JazzArchiveRecord]
  ) throws -> CaptureCoachRecordContext {
    let coachRecord = try records.first {
      $0.recordType == ArchiveRecord<CaptureCoachInteraction>.coachRecordType
    }?.coachInteractionRecord()
    guard
      let streamId = coachRecord?.streamId ?? session.streamIds.first,
      let sourceId = coachRecord?.sourceRefs.first?.sourceId
        ?? session.sourceIds.first
    else {
      throw CaptureCoachLiveContractError.invalidField(
        "prompt recovery archive context")
    }
    return CaptureCoachRecordContext(
      originId: manifest.originId,
      captureId: session.captureId,
      streamId: streamId,
      sourceRefs: coachRecord?.sourceRefs ?? [
        JazzArchiveSourceRef(sourceId: sourceId, role: "coach_ui")
      ],
      actorRefs: [
        JazzArchiveActorRef(
          actorId: session.recorderActorId,
          role: "respondent",
          basis: .declared,
          method: "session_recorder")
      ],
      provenance: coachRecord?.provenance
        ?? JazzArchiveProvenance(
          factClass: .observed, sources: [sourceId]),
      quality: coachRecord?.quality ?? session.quality,
      privacy: coachRecord?.privacy
        ?? JazzArchivePrivacy(
          status: .captured,
          policyVersion: session.capturePolicy.policyVersion))
  }
}
