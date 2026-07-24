import Foundation

public enum CaptureCoachLiveContractError: Error, Equatable, CustomStringConvertible {
  case invalidField(String)
  case unsupportedDocument
  case nonCanonicalJSON
  case contentDigestMismatch
  case documentTooLarge
  case identityCollision(String)

  public var description: String {
    switch self {
    case .invalidField(let field): "Invalid Capture Coach live field: \(field)"
    case .unsupportedDocument: "Unsupported Capture Coach live document"
    case .nonCanonicalJSON: "Capture Coach live bytes are not strict RFC 8785 JCS"
    case .contentDigestMismatch:
      "Capture Coach live contentDigest does not bind the document"
    case .documentTooLarge: "Capture Coach live document exceeds its hard byte limit"
    case .identityCollision(let identifier):
      "Capture Coach live identity collision: \(identifier)"
    }
  }
}

public struct CaptureCoachLiveScope: Codable, Equatable, Sendable {
  public var companyId: String
  public var areaId: String
  public var processId: String
  public var deviceId: String

  public init(companyId: String, areaId: String, processId: String, deviceId: String) {
    self.companyId = companyId
    self.areaId = areaId
    self.processId = processId
    self.deviceId = deviceId
  }

  public func validate() throws {
    try CaptureCoachLiveValidation.enrollmentIdentifier(
      companyId, field: "scope.companyId", maximumCharacters: 64)
    try CaptureCoachLiveValidation.enrollmentIdentifier(
      areaId, field: "scope.areaId", maximumCharacters: 64)
    try CaptureCoachLiveValidation.enrollmentIdentifier(
      processId, field: "scope.processId", maximumCharacters: 200)
    try CaptureCoachLiveValidation.enrollmentIdentifier(
      deviceId, field: "scope.deviceId", maximumCharacters: 64)
  }
}

public struct CaptureCoachLivePromptQueryItem: Equatable, Sendable {
  public var name: String
  public var value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }
}

/// Exact lineage selector for the prompt GET. Enrollment scope alone is not sufficient: one device
/// may have multiple captures or labels in flight, and a prompt must never cross either boundary.
public struct CaptureCoachLivePromptSelector: Codable, Equatable, Sendable {
  public var companyId: String
  public var areaId: String
  public var processId: String
  public var deviceId: String
  public var captureId: String
  public var labelId: String

  public init(
    scope: CaptureCoachLiveScope,
    captureId: String,
    labelId: String
  ) {
    companyId = scope.companyId
    areaId = scope.areaId
    processId = scope.processId
    deviceId = scope.deviceId
    self.captureId = captureId
    self.labelId = labelId
  }

  public var scope: CaptureCoachLiveScope {
    CaptureCoachLiveScope(
      companyId: companyId,
      areaId: areaId,
      processId: processId,
      deviceId: deviceId)
  }

  public var orderedQueryItems: [CaptureCoachLivePromptQueryItem] {
    [
      CaptureCoachLivePromptQueryItem(name: "companyId", value: companyId),
      CaptureCoachLivePromptQueryItem(name: "areaId", value: areaId),
      CaptureCoachLivePromptQueryItem(name: "processId", value: processId),
      CaptureCoachLivePromptQueryItem(name: "deviceId", value: deviceId),
      CaptureCoachLivePromptQueryItem(name: "captureId", value: captureId),
      CaptureCoachLivePromptQueryItem(name: "labelId", value: labelId),
    ]
  }

  public func validate() throws {
    try scope.validate()
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
    try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
  }

  public func requestURL(endpoint: URL) throws -> URL {
    try validate()
    guard
      var components = URLComponents(
        url: endpoint, resolvingAgainstBaseURL: false)
    else {
      throw CaptureCoachLiveContractError.invalidField(
        "promptSelector.endpoint")
    }
    components.queryItems = orderedQueryItems.map {
      URLQueryItem(name: $0.name, value: $0.value)
    }
    guard let result = components.url else {
      throw CaptureCoachLiveContractError.invalidField(
        "promptSelector.endpoint")
    }
    return result
  }

  public func matches(_ prompt: CaptureCoachLivePrompt) -> Bool {
    prompt.scope == scope
      && prompt.captureId == captureId
      && prompt.labelId == labelId
  }
}

public enum CaptureCoachLiveProducerKind: String, Codable, Equatable, Sendable {
  case nativeDesktop = "native_desktop"
  case meetingSource = "meeting_source"
  case otherCaptureSource = "other_capture_source"
}

public struct CaptureCoachLiveProducer: Codable, Equatable, Sendable {
  public var producerId: String
  public var kind: CaptureCoachLiveProducerKind
  public var version: String
  public var capabilities: [String]
  public var unavailableCapabilities: [String]

  public init(
    producerId: String,
    kind: CaptureCoachLiveProducerKind,
    version: String,
    capabilities: [String],
    unavailableCapabilities: [String]
  ) {
    self.producerId = producerId
    self.kind = kind
    self.version = version
    self.capabilities = capabilities
    self.unavailableCapabilities = unavailableCapabilities
  }

  public func validate() throws {
    try CaptureCoachLiveValidation.boundedText(
      producerId, field: "producer.producerId", maximumUTF8Bytes: 256)
    try CaptureCoachLiveValidation.boundedText(
      version, field: "producer.version", maximumUTF8Bytes: 128)
    for (name, values) in [
      ("capabilities", capabilities),
      ("unavailableCapabilities", unavailableCapabilities),
    ] {
      guard values.count <= 64,
        values == values.sorted(),
        Set(values).count == values.count
      else {
        throw CaptureCoachLiveContractError.invalidField("producer.\(name)")
      }
      for value in values {
        try CaptureCoachLiveValidation.boundedText(
          value, field: "producer.\(name)", maximumUTF8Bytes: 128)
      }
    }
  }
}

public struct CaptureCoachLiveSanitizedObservationContext: Codable, Equatable, Sendable {
  public var applicationId: String?
  public var applicationVersion: String?
  public var documentKind: String?
  public var documentRef: String?
  public var action: String?
  public var targetRole: String?
  public var targetName: String?
  public var payloadSummary: String?
  public var redactionPolicyVersion: String
  public var maskedFields: [String]

  public init(
    applicationId: String? = nil,
    applicationVersion: String? = nil,
    documentKind: String? = nil,
    documentRef: String? = nil,
    action: String? = nil,
    targetRole: String? = nil,
    targetName: String? = nil,
    payloadSummary: String? = nil,
    redactionPolicyVersion: String,
    maskedFields: [String]
  ) {
    self.applicationId = applicationId
    self.applicationVersion = applicationVersion
    self.documentKind = documentKind
    self.documentRef = documentRef
    self.action = action
    self.targetRole = targetRole
    self.targetName = targetName
    self.payloadSummary = payloadSummary
    self.redactionPolicyVersion = redactionPolicyVersion
    self.maskedFields = maskedFields
  }

  fileprivate func validate() throws {
    for (field, value, maximum) in [
      ("applicationId", applicationId, 256),
      ("applicationVersion", applicationVersion, 128),
      ("documentKind", documentKind, 128),
      ("documentRef", documentRef, 1_024),
      ("action", action, 128),
      ("targetRole", targetRole, 128),
      ("targetName", targetName, 1_024),
      ("payloadSummary", payloadSummary, 8_192),
    ] {
      if let value {
        try CaptureCoachLiveValidation.boundedText(
          value, field: "sanitizedContext.\(field)", maximumUTF8Bytes: maximum)
      }
    }
    try CaptureCoachLiveValidation.boundedText(
      redactionPolicyVersion,
      field: "sanitizedContext.redactionPolicyVersion",
      maximumUTF8Bytes: 256)
    guard maskedFields.count <= 64,
      maskedFields == maskedFields.sorted(),
      Set(maskedFields).count == maskedFields.count
    else {
      throw CaptureCoachLiveContractError.invalidField(
        "sanitizedContext.maskedFields")
    }
    let inspected = [documentRef, targetName, payloadSummary]
      .compactMap { $0 }.joined(separator: " ").lowercased()
    guard
      !["authorization:", "x-storageapi-token", "password=", "token="]
        .contains(where: inspected.contains)
    else {
      throw CaptureCoachLiveContractError.invalidField(
        "sanitizedContext credential material")
    }
  }
}

public enum CaptureCoachLivePreviewPrivacyStatus: String, Codable, Equatable, Sendable {
  case masked
  case noSensitiveContent = "no_sensitive_content"
}

public struct CaptureCoachLivePreviewPrivacy: Codable, Equatable, Sendable {
  public var policyVersion: String
  public var status: CaptureCoachLivePreviewPrivacyStatus
  public var redactionCount: Int
  public var redactionDigest: String?

  public init(
    policyVersion: String,
    status: CaptureCoachLivePreviewPrivacyStatus,
    redactionCount: Int,
    redactionDigest: String? = nil
  ) {
    self.policyVersion = policyVersion
    self.status = status
    self.redactionCount = redactionCount
    self.redactionDigest = redactionDigest
  }

  fileprivate func validate() throws {
    try CaptureCoachLiveValidation.boundedText(
      policyVersion, field: "preview.privacy.policyVersion", maximumUTF8Bytes: 256)
    guard (0...10_000).contains(redactionCount) else {
      throw CaptureCoachLiveContractError.invalidField(
        "preview.privacy.redactionCount")
    }
    switch status {
    case .masked:
      guard redactionCount > 0, let redactionDigest else {
        throw CaptureCoachLiveContractError.invalidField("preview.privacy")
      }
      try CaptureCoachLiveValidation.sha256(
        redactionDigest, field: "preview.privacy.redactionDigest")
    case .noSensitiveContent:
      guard redactionCount == 0, redactionDigest == nil else {
        throw CaptureCoachLiveContractError.invalidField("preview.privacy")
      }
    }
  }
}

public struct CaptureCoachLiveImagePreview: Codable, Equatable, Sendable {
  public var mediaType: String
  public var byteLength: Int
  public var contentSha256: String
  public var contentBase64: String
  public var privacy: CaptureCoachLivePreviewPrivacy

  public init(
    mediaType: String,
    bytes: Data,
    privacy: CaptureCoachLivePreviewPrivacy
  ) {
    self.mediaType = mediaType
    byteLength = bytes.count
    contentSha256 = JazzArchiveDigest.sha256Hex(bytes)
    contentBase64 = bytes.base64EncodedString()
    self.privacy = privacy
  }

  fileprivate func validate() throws -> Int {
    guard ["image/jpeg", "image/png", "image/webp"].contains(mediaType),
      let bytes = Data(base64Encoded: contentBase64),
      !bytes.isEmpty,
      bytes.count == byteLength,
      bytes.count <= CaptureCoachLiveLimits.maximumPreviewBytes,
      JazzArchiveDigest.sha256Hex(bytes) == contentSha256
    else {
      throw CaptureCoachLiveContractError.invalidField("preview")
    }
    try privacy.validate()
    return bytes.count
  }
}

public struct CaptureCoachLiveCanonicalObservation: Codable, Equatable, Sendable {
  public var kind = "canonicalObservation"
  public var observationId: String
  public var streamId: String
  public var streamSequence: Int
  public var recordType: String
  public var recordDigest: String
  public var sanitizedContext: CaptureCoachLiveSanitizedObservationContext
  public var preview: CaptureCoachLiveImagePreview?

  public init(
    observationId: String,
    streamId: String,
    streamSequence: Int,
    recordType: String,
    recordDigest: String,
    sanitizedContext: CaptureCoachLiveSanitizedObservationContext,
    preview: CaptureCoachLiveImagePreview? = nil
  ) {
    self.observationId = observationId
    self.streamId = streamId
    self.streamSequence = streamSequence
    self.recordType = recordType
    self.recordDigest = recordDigest
    self.sanitizedContext = sanitizedContext
    self.preview = preview
  }

  private enum CodingKeys: String, CodingKey {
    case kind, observationId, streamId, streamSequence, recordType, recordDigest
    case sanitizedContext, preview
  }
}

public struct CaptureCoachLiveTranscriptSpan: Codable, Equatable, Sendable {
  public var kind = "transcriptSpan"
  public var transcriptId: String
  public var revision: Int
  public var startMillis: Int
  public var endMillis: Int
  public var text: String
  public var textDigest: String
  public var finalized: Bool

  public init(
    transcriptId: String,
    revision: Int,
    startMillis: Int,
    endMillis: Int,
    text: String,
    finalized: Bool
  ) {
    self.transcriptId = transcriptId
    self.revision = revision
    self.startMillis = startMillis
    self.endMillis = endMillis
    self.text = text
    textDigest = JazzArchiveDigest.sha256Hex(Data(text.utf8))
    self.finalized = finalized
  }

  private enum CodingKeys: String, CodingKey {
    case kind, transcriptId, revision, startMillis, endMillis, text, textDigest, finalized
  }
}

public struct CaptureCoachLiveAudioChunk: Codable, Equatable, Sendable {
  public var kind = "audioChunk"
  public var chunkId: String
  public var streamId: String
  public var streamSequence: Int
  public var startMillis: Int
  public var endMillis: Int
  public var mediaType: String
  public var byteLength: Int
  public var contentSha256: String
  public var contentBase64: String

  /// `streamId` identifies one label-scoped audio stream. Sequence starts at zero for each label;
  /// start/end milliseconds are derived from contiguous PCM frame counts relative to that label's
  /// microphone start, never from wall-clock time.
  public init(
    chunkId: String = Identifiers.newCoachAudioChunkId(),
    streamId: String,
    streamSequence: Int,
    startMillis: Int,
    endMillis: Int,
    mediaType: String,
    bytes: Data
  ) {
    self.chunkId = chunkId
    self.streamId = streamId
    self.streamSequence = streamSequence
    self.startMillis = startMillis
    self.endMillis = endMillis
    self.mediaType = mediaType
    byteLength = bytes.count
    contentSha256 = JazzArchiveDigest.sha256Hex(bytes)
    contentBase64 = bytes.base64EncodedString()
  }

  private enum CodingKeys: String, CodingKey {
    case kind, chunkId, streamId, streamSequence, startMillis, endMillis, mediaType
    case byteLength, contentSha256, contentBase64
  }
}

public enum CaptureCoachLiveEvidence: Equatable, Sendable {
  case canonicalObservation(CaptureCoachLiveCanonicalObservation)
  case transcriptSpan(CaptureCoachLiveTranscriptSpan)
  case audioChunk(CaptureCoachLiveAudioChunk)
}

extension CaptureCoachLiveEvidence: Codable {
  private enum Kind: String, Codable { case canonicalObservation, transcriptSpan, audioChunk }
  private enum CodingKeys: String, CodingKey { case kind }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .canonicalObservation:
      self = .canonicalObservation(
        try CaptureCoachLiveCanonicalObservation(from: decoder))
    case .transcriptSpan:
      self = .transcriptSpan(try CaptureCoachLiveTranscriptSpan(from: decoder))
    case .audioChunk:
      self = .audioChunk(try CaptureCoachLiveAudioChunk(from: decoder))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .canonicalObservation(let value): try value.encode(to: encoder)
    case .transcriptSpan(let value): try value.encode(to: encoder)
    case .audioChunk(let value): try value.encode(to: encoder)
    }
  }
}

public enum CaptureCoachLiveLimits {
  public static let maximumMessageBytes = 1_048_576
  public static let maximumObservationCount = 16
  public static let maximumTranscriptSpanCount = 8
  public static let maximumAudioChunkCount = 1
  public static let maximumAudioBytes = 262_144
  public static let maximumPreviewBytes = 393_216
  public static let maximumTranscriptTextBytes = 8_192
}

/// Live Coach is a separate disclosure/consent decision from legacy OTLP compatibility. Absence
/// of a stored choice is always disabled, preserving the default local-first capture path.
public enum CaptureCoachLiveConsent {
  public static func isEnabled(storedValue: Bool?) -> Bool {
    storedValue == true
  }
}

public protocol CaptureCoachLiveSpoolDocument: Codable, Equatable, Sendable {
  var spoolIdentifier: String { get }
  var contentDigest: String { get }
  func validate() throws
}

extension CaptureCoachLiveSpoolDocument {
  public func canonicalData() throws -> Data {
    try validate()
    return try JazzArchiveCanonicalJSON.encode(self)
  }

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

public struct CaptureCoachLiveMessage: CaptureCoachLiveSpoolDocument {
  public var documentType = "message"
  public var schemaVersion = 1
  public var messageId: String
  public var scope: CaptureCoachLiveScope
  public var producer: CaptureCoachLiveProducer
  public var captureId: String
  public var labelId: String
  public var createdAt: String
  public var inputWatermark: CaptureCoachInputWatermark
  public var evidence: [CaptureCoachLiveEvidence]
  public var contentDigest: String

  public init(
    messageId: String = Identifiers.newCoachLiveMessageId(),
    scope: CaptureCoachLiveScope,
    producer: CaptureCoachLiveProducer,
    captureId: String,
    labelId: String,
    createdAt: String = Timestamps.iso8601(),
    inputWatermark: CaptureCoachInputWatermark,
    evidence: [CaptureCoachLiveEvidence]
  ) throws {
    documentType = "message"
    schemaVersion = 1
    self.messageId = messageId
    self.scope = scope
    self.producer = producer
    self.captureId = captureId
    self.labelId = labelId
    self.createdAt = createdAt
    self.inputWatermark = inputWatermark
    self.evidence = evidence
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public var spoolIdentifier: String { messageId }

  public func validate() throws {
    guard documentType == "message", schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try CaptureCoachLiveValidation.uuidV7(messageId, prefix: "ccm")
    try scope.validate()
    try producer.validate()
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
    try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
    guard Timestamps.parse(createdAt) != nil, captureId == inputWatermark.captureId else {
      throw CaptureCoachLiveContractError.invalidField("message context")
    }
    try inputWatermark.validate()
    guard inputWatermark.schemaVersion == 2, !evidence.isEmpty, evidence.count <= 25 else {
      throw CaptureCoachLiveContractError.invalidField("message evidence")
    }
    let streams = Dictionary(
      uniqueKeysWithValues: inputWatermark.streams.map {
        ($0.streamId, $0.throughSequence)
      })
    let transcripts = Dictionary(
      uniqueKeysWithValues: (inputWatermark.transcripts ?? []).map {
        ($0.transcriptId, $0)
      })
    var observationCount = 0
    var transcriptCount = 0
    var audioCount = 0
    var previewBytes = 0
    var evidenceKeys = Set<String>()
    for item in evidence {
      switch item {
      case .canonicalObservation(let value):
        observationCount += 1
        guard value.kind == "canonicalObservation" else {
          throw CaptureCoachLiveContractError.invalidField(
            "canonicalObservation.kind")
        }
        try CaptureCoachLiveValidation.uuidV7(value.observationId, prefix: "obs")
        try CaptureCoachLiveValidation.uuidV7(value.streamId, prefix: "stream")
        guard value.streamSequence >= 0,
          streams[value.streamId].map({ $0 >= value.streamSequence }) == true
        else {
          throw CaptureCoachLiveContractError.invalidField(
            "canonicalObservation watermark")
        }
        try CaptureCoachLiveValidation.boundedText(
          value.recordType, field: "canonicalObservation.recordType",
          maximumUTF8Bytes: 256)
        try CaptureCoachLiveValidation.sha256(
          value.recordDigest, field: "canonicalObservation.recordDigest")
        try value.sanitizedContext.validate()
        let key = "observation:\(value.observationId)"
        guard evidenceKeys.insert(key).inserted else {
          throw CaptureCoachLiveContractError.identityCollision(value.observationId)
        }
        if let preview = value.preview {
          if !value.sanitizedContext.maskedFields.isEmpty,
            preview.privacy.status != .masked
          {
            throw CaptureCoachLiveContractError.invalidField(
              "preview pixel privacy")
          }
          previewBytes += try preview.validate()
        }
      case .transcriptSpan(let value):
        transcriptCount += 1
        guard value.kind == "transcriptSpan",
          value.revision >= 1,
          value.startMillis >= 0,
          value.endMillis > value.startMillis,
          !value.text.isEmpty,
          value.text.utf8.count <= CaptureCoachLiveLimits.maximumTranscriptTextBytes,
          JazzArchiveDigest.sha256Hex(Data(value.text.utf8)) == value.textDigest,
          let watermark = transcripts[value.transcriptId],
          watermark.revision == value.revision,
          watermark.throughMillis >= value.endMillis,
          !value.finalized || watermark.finalized
        else {
          throw CaptureCoachLiveContractError.invalidField("transcriptSpan")
        }
        let key = [
          "transcript", value.transcriptId, String(value.revision),
          String(value.startMillis), String(value.endMillis), value.textDigest,
        ].joined(separator: ":")
        guard evidenceKeys.insert(key).inserted else {
          throw CaptureCoachLiveContractError.identityCollision(key)
        }
      case .audioChunk(let value):
        audioCount += 1
        guard value.kind == "audioChunk" else {
          throw CaptureCoachLiveContractError.invalidField("audioChunk.kind")
        }
        try CaptureCoachLiveValidation.uuidV7(value.chunkId, prefix: "cac")
        try CaptureCoachLiveValidation.uuidV7(value.streamId, prefix: "stream")
        guard value.streamSequence >= 0,
          streams[value.streamId].map({ $0 >= value.streamSequence }) == true,
          value.startMillis >= 0,
          value.endMillis > value.startMillis,
          [
            "audio/l16;rate=16000;channels=1",
            "audio/l16;rate=24000;channels=1",
            "audio/l16;rate=48000;channels=1",
          ].contains(value.mediaType),
          let bytes = Data(base64Encoded: value.contentBase64),
          !bytes.isEmpty,
          bytes.count == value.byteLength,
          bytes.count <= CaptureCoachLiveLimits.maximumAudioBytes,
          JazzArchiveDigest.sha256Hex(bytes) == value.contentSha256
        else {
          throw CaptureCoachLiveContractError.invalidField("audioChunk")
        }
        guard evidenceKeys.insert("audio:\(value.chunkId)").inserted else {
          throw CaptureCoachLiveContractError.identityCollision(value.chunkId)
        }
      }
    }
    guard observationCount <= CaptureCoachLiveLimits.maximumObservationCount,
      transcriptCount <= CaptureCoachLiveLimits.maximumTranscriptSpanCount,
      audioCount <= CaptureCoachLiveLimits.maximumAudioChunkCount,
      previewBytes <= CaptureCoachLiveLimits.maximumPreviewBytes
    else {
      throw CaptureCoachLiveContractError.documentTooLarge
    }
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
    guard
      try JazzArchiveCanonicalJSON.encode(self).count
        <= CaptureCoachLiveLimits.maximumMessageBytes
    else {
      throw CaptureCoachLiveContractError.documentTooLarge
    }
  }

  private struct DigestMaterial: Codable {
    var documentType: String
    var schemaVersion: Int
    var messageId: String
    var scope: CaptureCoachLiveScope
    var producer: CaptureCoachLiveProducer
    var captureId: String
    var labelId: String
    var createdAt: String
    var inputWatermark: CaptureCoachInputWatermark
    var evidence: [CaptureCoachLiveEvidence]
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      documentType: documentType,
      schemaVersion: schemaVersion,
      messageId: messageId,
      scope: scope,
      producer: producer,
      captureId: captureId,
      labelId: labelId,
      createdAt: createdAt,
      inputWatermark: inputWatermark,
      evidence: evidence)
  }
}

public struct CaptureCoachLivePrompt: CaptureCoachLiveSpoolDocument {
  public var documentType = "prompt"
  public var schemaVersion = 1
  public var promptId: String
  public var scope: CaptureCoachLiveScope
  public var captureId: String
  public var labelId: String
  public var sourceMessageIds: [String]
  public var assessmentRef: CaptureCoachAssessmentRef
  public var inputWatermark: CaptureCoachInputWatermark
  public var snapshot: CaptureCoachPromptSnapshot
  public var issuedAt: String
  public var contentDigest: String

  public init(
    promptId: String = Identifiers.newCoachPromptId(),
    scope: CaptureCoachLiveScope,
    captureId: String,
    labelId: String,
    sourceMessageIds: [String],
    assessmentRef: CaptureCoachAssessmentRef,
    inputWatermark: CaptureCoachInputWatermark,
    snapshot: CaptureCoachPromptSnapshot,
    issuedAt: String = Timestamps.iso8601()
  ) throws {
    documentType = "prompt"
    schemaVersion = 1
    self.promptId = promptId
    self.scope = scope
    self.captureId = captureId
    self.labelId = labelId
    self.sourceMessageIds = sourceMessageIds
    self.assessmentRef = assessmentRef
    self.inputWatermark = inputWatermark
    self.snapshot = snapshot
    self.issuedAt = issuedAt
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public init(
    promptId: String,
    scope: CaptureCoachLiveScope,
    captureId: String,
    labelId: String,
    sourceMessageIds: [String],
    assessmentRef: CaptureCoachAssessmentRef,
    inputWatermark: CaptureCoachInputWatermark,
    snapshot: CaptureCoachPromptSnapshot,
    issuedAt: String,
    contentDigest: String
  ) {
    self.promptId = promptId
    self.scope = scope
    self.captureId = captureId
    self.labelId = labelId
    self.sourceMessageIds = sourceMessageIds
    self.assessmentRef = assessmentRef
    self.inputWatermark = inputWatermark
    self.snapshot = snapshot
    self.issuedAt = issuedAt
    self.contentDigest = contentDigest
  }

  public var spoolIdentifier: String { promptId }

  public func validate() throws {
    guard documentType == "prompt", schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try CaptureCoachLiveValidation.uuidV7(promptId, prefix: "prompt")
    try scope.validate()
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
    try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
    guard !sourceMessageIds.isEmpty,
      sourceMessageIds.count <= 128,
      sourceMessageIds == sourceMessageIds.sorted(),
      Set(sourceMessageIds).count == sourceMessageIds.count,
      sourceMessageIds.allSatisfy({
        CaptureCoachLiveValidation.isUUIDV7($0, prefix: "ccm")
      }),
      Timestamps.parse(issuedAt) != nil,
      captureId == inputWatermark.captureId
    else {
      throw CaptureCoachLiveContractError.invalidField("prompt context")
    }
    let domain = domainPrompt
    try domain.validate(for: captureId)
    guard inputWatermark.schemaVersion == 2 else {
      throw CaptureCoachLiveContractError.invalidField("prompt inputWatermark")
    }
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  public var domainPrompt: CaptureCoachPrompt {
    CaptureCoachPrompt(
      promptId: promptId,
      labelId: labelId,
      assessmentRef: assessmentRef,
      inputWatermark: inputWatermark,
      snapshot: snapshot)
  }

  private struct DigestMaterial: Codable {
    var documentType: String
    var schemaVersion: Int
    var promptId: String
    var scope: CaptureCoachLiveScope
    var captureId: String
    var labelId: String
    var sourceMessageIds: [String]
    var assessmentRef: CaptureCoachAssessmentRef
    var inputWatermark: CaptureCoachInputWatermark
    var snapshot: CaptureCoachPromptSnapshot
    var issuedAt: String
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      documentType: documentType,
      schemaVersion: schemaVersion,
      promptId: promptId,
      scope: scope,
      captureId: captureId,
      labelId: labelId,
      sourceMessageIds: sourceMessageIds,
      assessmentRef: assessmentRef,
      inputWatermark: inputWatermark,
      snapshot: snapshot,
      issuedAt: issuedAt)
  }
}

public enum CaptureCoachLivePromptReceiptAction: String, Codable, Equatable, Sendable {
  case shown
  case answered
  case dismissed
  case suppressed
}

public enum CaptureCoachLiveScopeControlAction: String, Codable, Equatable, Sendable {
  case muted
  case resumed
  case finishAnyway = "finish_anyway"
}

public struct CaptureCoachLiveCanonicalInteractionRef: Codable, Equatable, Hashable, Sendable {
  public var interactionId: String
  public var interactionType: CaptureCoachInteractionType

  public init(interactionId: String, interactionType: CaptureCoachInteractionType) {
    self.interactionId = interactionId
    self.interactionType = interactionType
  }

  fileprivate func validate() throws {
    try CaptureCoachLiveValidation.uuidV7(interactionId, prefix: "coach")
  }
}

public struct CaptureCoachLivePromptReceipt: CaptureCoachLiveSpoolDocument {
  public var documentType = "receipt"
  public var schemaVersion = 1
  public var receiptId: String
  public var scope: CaptureCoachLiveScope
  public var promptId: String
  public var promptDigest: String
  public var captureId: String
  public var labelId: String
  public var assessmentId: String
  public var inputWatermark: CaptureCoachInputWatermark
  public var action: CaptureCoachLivePromptReceiptAction
  public var suppressionReason: CaptureCoachDispositionReason?
  public var canonicalInteractions: [CaptureCoachLiveCanonicalInteractionRef]
  public var occurredAt: String
  public var clientRecordedAt: String
  public var contentDigest: String

  public init(
    receiptId: String = Identifiers.newCoachLiveReceiptId(),
    scope: CaptureCoachLiveScope,
    prompt: CaptureCoachLivePrompt,
    action: CaptureCoachLivePromptReceiptAction,
    suppressionReason: CaptureCoachDispositionReason? = nil,
    canonicalInteractions: [CaptureCoachLiveCanonicalInteractionRef],
    occurredAt: String,
    clientRecordedAt: String = Timestamps.iso8601()
  ) throws {
    documentType = "receipt"
    schemaVersion = 1
    self.receiptId = receiptId
    self.scope = scope
    promptId = prompt.promptId
    promptDigest = prompt.contentDigest
    captureId = prompt.captureId
    labelId = prompt.labelId
    assessmentId = prompt.assessmentRef.assessmentId
    inputWatermark = prompt.inputWatermark
    self.action = action
    self.suppressionReason = suppressionReason
    self.canonicalInteractions = canonicalInteractions
    self.occurredAt = occurredAt
    self.clientRecordedAt = clientRecordedAt
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public var spoolIdentifier: String { receiptId }

  public func validate() throws {
    guard documentType == "receipt", schemaVersion == 1 else {
      throw CaptureCoachLiveContractError.unsupportedDocument
    }
    try CaptureCoachLiveValidation.uuidV7(receiptId, prefix: "ccr")
    try scope.validate()
    try CaptureCoachLiveValidation.uuidV7(promptId, prefix: "prompt")
    try CaptureCoachLiveValidation.sha256(promptDigest, field: "promptDigest")
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
    try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
    try CaptureCoachLiveValidation.uuidV7(assessmentId, prefix: "cqa")
    try inputWatermark.validate()
    guard inputWatermark.schemaVersion == 2,
      inputWatermark.captureId == captureId,
      let occurred = Timestamps.parse(occurredAt),
      let recorded = Timestamps.parse(clientRecordedAt),
      occurred <= recorded,
      Set(canonicalInteractions).count == canonicalInteractions.count
    else {
      throw CaptureCoachLiveContractError.invalidField("receipt context")
    }
    for interaction in canonicalInteractions { try interaction.validate() }
    switch action {
    case .shown:
      guard suppressionReason == nil,
        canonicalInteractions.map(\.interactionType) == [.received, .shown]
      else { throw CaptureCoachLiveContractError.invalidField("shown receipt") }
    case .answered:
      guard suppressionReason == nil,
        canonicalInteractions.map(\.interactionType) == [.answered]
      else { throw CaptureCoachLiveContractError.invalidField("answered receipt") }
    case .dismissed:
      guard suppressionReason == nil,
        canonicalInteractions.map(\.interactionType) == [.dismissed]
      else { throw CaptureCoachLiveContractError.invalidField("dismissed receipt") }
    case .suppressed:
      guard let suppressionReason,
        [
          .staleWatermark, .closedLabel, .committedCapture,
          .interruptedCapture, .resolvedPrompt, .rateLimited, .userAction,
          .unsupportedVersion,
        ].contains(suppressionReason),
        canonicalInteractions.map(\.interactionType) == [.suppressed]
          || (
            suppressionReason == .interruptedCapture
              && canonicalInteractions.map(\.interactionType)
                == [.received, .suppressed]
          )
      else { throw CaptureCoachLiveContractError.invalidField("suppressed receipt") }
    }
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  private struct DigestMaterial: Codable {
    var documentType: String
    var schemaVersion: Int
    var receiptId: String
    var scope: CaptureCoachLiveScope
    var promptId: String
    var promptDigest: String
    var captureId: String
    var labelId: String
    var assessmentId: String
    var inputWatermark: CaptureCoachInputWatermark
    var action: CaptureCoachLivePromptReceiptAction
    var suppressionReason: CaptureCoachDispositionReason?
    var canonicalInteractions: [CaptureCoachLiveCanonicalInteractionRef]
    var occurredAt: String
    var clientRecordedAt: String
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      documentType: documentType,
      schemaVersion: schemaVersion,
      receiptId: receiptId,
      scope: scope,
      promptId: promptId,
      promptDigest: promptDigest,
      captureId: captureId,
      labelId: labelId,
      assessmentId: assessmentId,
      inputWatermark: inputWatermark,
      action: action,
      suppressionReason: suppressionReason,
      canonicalInteractions: canonicalInteractions,
      occurredAt: occurredAt,
      clientRecordedAt: clientRecordedAt)
  }
}

public struct CaptureCoachLiveScopeControlReceipt: CaptureCoachLiveSpoolDocument {
  public var documentType = "receipt"
  public var schemaVersion = 1
  public var receiptId: String
  public var scope: CaptureCoachLiveScope
  public var captureId: String
  public var labelId: String
  public var inputWatermark: CaptureCoachInputWatermark
  public var action: CaptureCoachLiveScopeControlAction
  public var canonicalInteractions: [CaptureCoachLiveCanonicalInteractionRef]
  public var occurredAt: String
  public var clientRecordedAt: String
  public var contentDigest: String

  public init(
    receiptId: String = Identifiers.newCoachLiveReceiptId(),
    scope: CaptureCoachLiveScope,
    captureId: String,
    labelId: String,
    inputWatermark: CaptureCoachInputWatermark,
    action: CaptureCoachLiveScopeControlAction,
    canonicalInteraction: CaptureCoachLiveCanonicalInteractionRef,
    occurredAt: String,
    clientRecordedAt: String = Timestamps.iso8601()
  ) throws {
    documentType = "receipt"
    schemaVersion = 1
    self.receiptId = receiptId
    self.scope = scope
    self.captureId = captureId
    self.labelId = labelId
    self.inputWatermark = inputWatermark
    self.action = action
    canonicalInteractions = [canonicalInteraction]
    self.occurredAt = occurredAt
    self.clientRecordedAt = clientRecordedAt
    contentDigest = ""
    contentDigest = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(digestMaterial))
    try validate()
  }

  public var spoolIdentifier: String { receiptId }

  public func validate() throws {
    try CaptureCoachLiveValidation.uuidV7(receiptId, prefix: "ccr")
    try scope.validate()
    try CaptureCoachLiveValidation.uuidV7(captureId, prefix: "cap")
    try CaptureCoachLiveValidation.uuidV7(labelId, prefix: "l")
    try inputWatermark.validate()
    let expected: CaptureCoachInteractionType
    switch action {
    case .muted: expected = .muted
    case .resumed: expected = .resumed
    case .finishAnyway: expected = .finishAnyway
    }
    guard documentType == "receipt",
      schemaVersion == 1,
      inputWatermark.schemaVersion == 2,
      inputWatermark.captureId == captureId,
      canonicalInteractions.count == 1,
      canonicalInteractions[0].interactionType == expected,
      let occurred = Timestamps.parse(occurredAt),
      let recorded = Timestamps.parse(clientRecordedAt),
      occurred <= recorded
    else {
      throw CaptureCoachLiveContractError.invalidField("scope-control receipt")
    }
    try canonicalInteractions[0].validate()
    try CaptureCoachLiveValidation.digest(
      declared: contentDigest, material: digestMaterial)
  }

  private struct DigestMaterial: Codable {
    var documentType: String
    var schemaVersion: Int
    var receiptId: String
    var scope: CaptureCoachLiveScope
    var captureId: String
    var labelId: String
    var inputWatermark: CaptureCoachInputWatermark
    var action: CaptureCoachLiveScopeControlAction
    var canonicalInteractions: [CaptureCoachLiveCanonicalInteractionRef]
    var occurredAt: String
    var clientRecordedAt: String
  }

  private var digestMaterial: DigestMaterial {
    DigestMaterial(
      documentType: documentType,
      schemaVersion: schemaVersion,
      receiptId: receiptId,
      scope: scope,
      captureId: captureId,
      labelId: labelId,
      inputWatermark: inputWatermark,
      action: action,
      canonicalInteractions: canonicalInteractions,
      occurredAt: occurredAt,
      clientRecordedAt: clientRecordedAt)
  }
}

public enum CaptureCoachLiveEndpoint {
  /// Derives one same-origin advisory root from the signed archive authority without changing the
  /// enrollment bundle. A deployment prefix is retained; userinfo/query/fragment and ambiguous
  /// paths have already been rejected by `JazzArchiveControlPlaneURL`.
  public static func derive(fromArchiveIngestURL value: String) -> URL? {
    guard let normalized = JazzArchiveControlPlaneURL.normalize(value),
      var components = URLComponents(string: normalized)
    else { return nil }
    let archiveSuffix = "/api/archive-ingests"
    guard components.path.hasSuffix(archiveSuffix) else { return nil }
    let prefix = components.path.dropLast(archiveSuffix.count)
    components.path = String(prefix) + "/api/capture-coach/live"
    return components.url
  }
}

enum CaptureCoachLiveValidation {
  static func enrollmentIdentifier(
    _ value: String,
    field: String,
    maximumCharacters: Int
  ) throws {
    guard value.count <= maximumCharacters,
      value.range(
        of: #"^[a-z0-9][a-z0-9-]*$"#,
        options: .regularExpression) != nil
    else { throw CaptureCoachLiveContractError.invalidField(field) }
  }

  static func boundedText(
    _ value: String,
    field: String,
    maximumUTF8Bytes: Int
  ) throws {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty,
      value.utf8.count <= maximumUTF8Bytes
    else { throw CaptureCoachLiveContractError.invalidField(field) }
  }

  static func isUUIDV7(_ value: String, prefix: String) -> Bool {
    let marker = prefix + "-"
    guard value.hasPrefix(marker) else { return false }
    let raw = String(value.dropFirst(marker.count))
    guard let uuid = UUID(uuidString: raw), uuid.uuidString.lowercased() == raw else {
      return false
    }
    let chars = Array(raw)
    return chars.count == 36 && chars[14] == "7" && "89ab".contains(chars[19])
  }

  static func uuidV7(_ value: String, prefix: String) throws {
    guard isUUIDV7(value, prefix: prefix) else {
      throw CaptureCoachLiveContractError.invalidField(prefix)
    }
  }

  static func sha256(_ value: String, field: String) throws {
    guard value.count == 64,
      value.allSatisfy({ "0123456789abcdef".contains($0) })
    else { throw CaptureCoachLiveContractError.invalidField(field) }
  }

  static func digest<T: Encodable>(declared: String, material: T) throws {
    try sha256(declared, field: "contentDigest")
    let actual = JazzArchiveDigest.sha256Hex(
      try JazzArchiveCanonicalJSON.encode(material))
    guard declared == actual else {
      throw CaptureCoachLiveContractError.contentDigestMismatch
    }
  }
}
