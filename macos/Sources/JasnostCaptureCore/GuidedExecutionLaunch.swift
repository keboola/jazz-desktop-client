import Foundation

/// Fresh native facts accepted by the server when an imported PREPARE has expired. Business-object
/// authority is intentionally absent: the server resolves current connector-backed anchor heads
/// for the immutable ProcessExecution identities.
public struct GuidedReplayRefreshRuntime: Codable, Equatable, Sendable {
    public var requestedAt: String
    public var capabilities: [GuidedCapability]
    public var locatorResolution: GuidedLocatorResolution
    public var applicationObservations: [GuidedApplicationObservation]

    public init(
        requestedAt: String,
        capabilities: [GuidedCapability],
        locatorResolution: GuidedLocatorResolution,
        applicationObservations: [GuidedApplicationObservation]
    ) {
        self.requestedAt = requestedAt
        self.capabilities = capabilities
        self.locatorResolution = locatorResolution
        self.applicationObservations = applicationObservations
    }

    /// Match the server's canonical refresh normalizer before persistence, digesting, or wire
    /// encoding. Capability identity is the id alone; repeating it with another version is
    /// ambiguous and therefore rejected rather than sorted into an apparently valid request.
    public func canonicalized() throws -> Self {
        var normalizedCapabilities = try capabilities.map {
            GuidedCapability(
                id: try guidedRefreshCanonicalText(
                    $0.id,
                    field: "runtime.capabilities.id"),
                version: try guidedRefreshCanonicalText(
                    $0.version,
                    field: "runtime.capabilities.version"))
        }
        let capabilityIds = normalizedCapabilities.map {
            Data($0.id.utf8)
        }
        guard Set(capabilityIds).count == capabilityIds.count else {
            throw GuidedExecutionError.invalidField(
                "refresh runtime duplicate capability id")
        }
        normalizedCapabilities.sort {
            let idOrder = guidedRefreshUTF8Order($0.id, $1.id)
            if idOrder != 0 { return idOrder < 0 }
            return guidedRefreshUTF8Order($0.version, $1.version) < 0
        }

        var normalizedLocator = locatorResolution
        normalizedLocator.stepId = try guidedRefreshCanonicalText(
            normalizedLocator.stepId,
            field: "runtime.locatorResolution.stepId")
        normalizedLocator.locatorId = try guidedRefreshCanonicalText(
            normalizedLocator.locatorId,
            field: "runtime.locatorResolution.locatorId")
        guard normalizedLocator.matchCount >= 0 else {
            throw GuidedExecutionError.invalidField(
                "runtime.locatorResolution.matchCount")
        }
        normalizedLocator.applicationId = try guidedRefreshCanonicalText(
            normalizedLocator.applicationId,
            field: "runtime.locatorResolution.applicationId")
        normalizedLocator.resolvedAt = try guidedRefreshCanonicalTimestamp(
            normalizedLocator.resolvedAt,
            field: "runtime.locatorResolution.resolvedAt")
        normalizedLocator.evidence = try guidedRefreshCanonicalEvidence(
            normalizedLocator.evidence,
            field: "runtime.locatorResolution.evidence")
        guard !normalizedLocator.evidence.isEmpty else {
            throw GuidedExecutionError.invalidField(
                "runtime.locatorResolution.evidence")
        }

        let normalizedApplications = try applicationObservations.enumerated().map {
            index, source -> (index: Int, value: GuidedApplicationObservation) in
            var application = source
            application.applicationId = try guidedRefreshCanonicalText(
                application.applicationId,
                field: "runtime.applicationObservations.applicationId")
            application.observedVersion = try guidedRefreshCanonicalText(
                application.observedVersion,
                field: "runtime.applicationObservations.observedVersion")
            if let environment = application.environment {
                application.environment = try guidedRefreshCanonicalText(
                    environment,
                    field: "runtime.applicationObservations.environment")
            }
            application.matchedVersionConstraint = try guidedRefreshCanonicalText(
                application.matchedVersionConstraint,
                field: "runtime.applicationObservations.matchedVersionConstraint")
            application.resolver.id = try guidedRefreshCanonicalText(
                application.resolver.id,
                field: "runtime.applicationObservations.resolver.id")
            application.resolver.version = try guidedRefreshCanonicalText(
                application.resolver.version,
                field: "runtime.applicationObservations.resolver.version")
            application.observedAt = try guidedRefreshCanonicalTimestamp(
                application.observedAt,
                field: "runtime.applicationObservations.observedAt")
            application.evidence = try guidedRefreshCanonicalEvidence(
                application.evidence,
                field: "runtime.applicationObservations.evidence")
            guard !application.evidence.isEmpty else {
                throw GuidedExecutionError.invalidField(
                    "runtime.applicationObservations.evidence")
            }
            return (index, application)
        }.sorted {
            let left = (
                $0.value.applicationId,
                $0.value.observedVersion,
                $0.value.environment ?? "")
            let right = (
                $1.value.applicationId,
                $1.value.observedVersion,
                $1.value.environment ?? "")
            let applicationOrder = guidedRefreshUTF8Order(left.0, right.0)
            if applicationOrder != 0 { return applicationOrder < 0 }
            let versionOrder = guidedRefreshUTF8Order(left.1, right.1)
            if versionOrder != 0 { return versionOrder < 0 }
            let environmentOrder = guidedRefreshUTF8Order(left.2, right.2)
            if environmentOrder != 0 { return environmentOrder < 0 }
            // Python's sorted() is stable; make the same tie behavior explicit.
            return $0.index < $1.index
        }.map(\.value)

        var result = self
        result.requestedAt = try guidedRefreshCanonicalTimestamp(
            requestedAt,
            field: "runtime.requestedAt")
        result.capabilities = normalizedCapabilities
        result.locatorResolution = normalizedLocator
        result.applicationObservations = normalizedApplications
        return result
    }
}

private struct GuidedRefreshEvidenceKey: Hashable, Comparable {
    let kind: Data
    let ref: Data

    static func < (
        lhs: GuidedRefreshEvidenceKey,
        rhs: GuidedRefreshEvidenceKey
    ) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind.lexicographicallyPrecedes(rhs.kind)
        }
        return lhs.ref.lexicographicallyPrecedes(rhs.ref)
    }
}

private func guidedRefreshUTF8Order(_ lhs: String, _ rhs: String) -> Int {
    let left = Data(lhs.utf8)
    let right = Data(rhs.utf8)
    if left == right { return 0 }
    return left.lexicographicallyPrecedes(right) ? -1 : 1
}

private func guidedRefreshCanonicalText(
    _ value: String,
    field: String
) throws -> String {
    let scalars = value.unicodeScalars
    var start = scalars.startIndex
    var end = scalars.endIndex
    while start < end, guidedRefreshIsPythonWhitespace(scalars[start]) {
        scalars.formIndex(after: &start)
    }
    while end > start {
        let previous = scalars.index(before: end)
        guard guidedRefreshIsPythonWhitespace(scalars[previous]) else {
            break
        }
        end = previous
    }
    let normalized = String(value[start..<end])
    guard !normalized.isEmpty else {
        throw GuidedExecutionError.invalidField(field)
    }
    return normalized
}

/// Python 3.12 `str.strip()` whitespace scalars. The server contract uses Python, so relying on
/// Foundation's locale-independent CharacterSet would still leave room for client/server drift.
private func guidedRefreshIsPythonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0009...0x000D,
        0x001C...0x001F,
        0x0020,
        0x0085,
        0x00A0,
        0x1680,
        0x2000...0x200A,
        0x2028...0x2029,
        0x202F,
        0x205F,
        0x3000:
        true
    default:
        false
    }
}

private func guidedRefreshRequestIdIsCanonical(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count == 40,
        Array(bytes.prefix(4)) == Array("grq_".utf8)
    else {
        return false
    }
    let uuid = Array(bytes.dropFirst(4))
    let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
    for (offset, byte) in uuid.enumerated() {
        if hyphenOffsets.contains(offset) {
            guard byte == 0x2D else { return false }
        } else {
            guard (0x30...0x39).contains(byte)
                || (0x61...0x66).contains(byte)
            else {
                return false
            }
        }
    }
    return uuid[14] == 0x37
        && [UInt8(0x38), 0x39, 0x61, 0x62].contains(uuid[19])
}

private func guidedRefreshCanonicalTimestamp(
    _ value: String,
    field: String
) throws -> String {
    let normalized = try guidedRefreshCanonicalText(value, field: field)
    let expression = try NSRegularExpression(
        pattern:
            #"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}:[0-9]{2})$"#)
    let fullRange = NSRange(normalized.startIndex..., in: normalized)
    guard let match = expression.firstMatch(
        in: normalized,
        range: fullRange),
        match.range == fullRange
    else {
        throw GuidedExecutionError.invalidField(field)
    }

    func component(_ index: Int) -> String? {
        let range = match.range(at: index)
        guard range.location != NSNotFound,
            let swiftRange = Range(range, in: normalized)
        else { return nil }
        return String(normalized[swiftRange])
    }
    guard let year = component(1).flatMap(Int.init),
        let month = component(2).flatMap(Int.init),
        let day = component(3).flatMap(Int.init),
        let hour = component(4).flatMap(Int.init),
        let minute = component(5).flatMap(Int.init),
        let second = component(6).flatMap(Int.init),
        year >= 1,
        (1...12).contains(month),
        (0...23).contains(hour),
        (0...59).contains(minute),
        (0...59).contains(second),
        let zone = component(8)
    else {
        throw GuidedExecutionError.invalidField(field)
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
        calendar: calendar,
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second)
    guard let localAsUTC = calendar.date(from: components) else {
        throw GuidedExecutionError.invalidField(field)
    }
    let verified = calendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .second],
        from: localAsUTC)
    guard verified.year == year,
        verified.month == month,
        verified.day == day,
        verified.hour == hour,
        verified.minute == minute,
        verified.second == second
    else {
        throw GuidedExecutionError.invalidField(field)
    }

    let offsetSeconds: Int
    if zone == "Z" {
        offsetSeconds = 0
    } else {
        let zoneCharacters = Array(zone)
        guard let zoneHour = Int(String(zoneCharacters[1...2])),
            let zoneMinute = Int(String(zoneCharacters[4...5])),
            zoneCharacters[3] == ":",
            (0...23).contains(zoneHour),
            (0...59).contains(zoneMinute)
        else {
            throw GuidedExecutionError.invalidField(field)
        }
        let magnitude = zoneHour * 3_600 + zoneMinute * 60
        offsetSeconds = zoneCharacters[0] == "-" ? -magnitude : magnitude
    }

    let utcWholeSecond = Int64(localAsUTC.timeIntervalSince1970) - Int64(offsetSeconds)
    let fraction = component(7) ?? ""
    let sixDigits = String(fraction.prefix(6))
        + String(repeating: "0", count: max(0, 6 - fraction.prefix(6).count))
    guard let microseconds = Int64(sixDigits) else {
        throw GuidedExecutionError.invalidField(field)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter.string(
        from: Date(timeIntervalSince1970: TimeInterval(utcWholeSecond)))
        + String(format: ".%06lldZ", microseconds)
}

private func guidedRefreshCanonicalEvidence(
    _ evidence: [GuidedEvidenceReference],
    field: String
) throws -> [GuidedEvidenceReference] {
    var best: [GuidedRefreshEvidenceKey: GuidedEvidenceReference] = [:]
    for source in evidence {
        var normalized = source
        normalized.ref = try guidedRefreshCanonicalText(
            source.ref,
            field: "\(field).ref")
        if let confidence = normalized.confidence,
            !confidence.isFinite || confidence < 0 || confidence > 1
        {
            throw GuidedExecutionError.invalidField("\(field).confidence")
        }
        let key = GuidedRefreshEvidenceKey(
            kind: Data(normalized.kind.rawValue.utf8),
            ref: Data(normalized.ref.utf8))
        let newConfidence = normalized.confidence ?? -1
        let priorConfidence = best[key]?.confidence ?? -1
        if best[key] == nil || newConfidence > priorConfidence {
            best[key] = normalized
        }
    }
    return best.keys.sorted().compactMap { best[$0] }
}

public struct GuidedExecutionRefreshIntent: Codable, Equatable, Sendable {
    public let refreshRequestId: String
    public let refreshRequestDigest: String
    public let scope: GuidedExecutionScope
    public let operatorId: String
    public let predecessorDecisionId: String
    public let predecessorDecisionContentDigest: String
    public let runtime: GuidedReplayRefreshRuntime

    public init(
        refreshRequestId: String,
        scope: GuidedExecutionScope,
        operatorId: String,
        predecessor: GuidedReplayDecisionDocument,
        runtime: GuidedReplayRefreshRuntime
    ) throws {
        guard guidedRefreshRequestIdIsCanonical(refreshRequestId) else {
            throw GuidedExecutionError.invalidField("refreshRequestId")
        }
        let canonicalRuntime = try runtime.canonicalized()
        self.refreshRequestId = refreshRequestId
        self.scope = scope
        self.operatorId = operatorId
        self.predecessorDecisionId = predecessor.decision.decisionId
        self.predecessorDecisionContentDigest = predecessor.decision.contentDigest
        self.runtime = canonicalRuntime
        self.refreshRequestDigest = try guidedExecutionRefreshRequestDigest(
            refreshRequestId: refreshRequestId,
            scope: scope,
            operatorId: operatorId,
            predecessorDecisionId: predecessor.decision.decisionId,
            predecessorDecisionContentDigest: predecessor.decision.contentDigest,
            runtime: canonicalRuntime)
    }

    public func validate(predecessor: GuidedReplayDecisionDocument) throws {
        let canonicalRuntime = try runtime.canonicalized()
        guard guidedRefreshRequestIdIsCanonical(refreshRequestId),
            refreshTextExactlyEqual(
                predecessorDecisionId,
                predecessor.decision.decisionId),
            refreshTextExactlyEqual(
                predecessorDecisionContentDigest,
                predecessor.decision.contentDigest),
            try refreshEncodedExactlyEqual(
                predecessor.decision.request.scope,
                scope),
            refreshTextExactlyEqual(
                predecessor.decision.request.operatorId,
                operatorId),
            try refreshEncodedExactlyEqual(runtime, canonicalRuntime),
            refreshRequestDigest
                == (try guidedExecutionRefreshRequestDigest(
                    refreshRequestId: refreshRequestId,
                    scope: scope,
                    operatorId: operatorId,
                    predecessorDecisionId: predecessorDecisionId,
                    predecessorDecisionContentDigest: predecessorDecisionContentDigest,
                    runtime: runtime))
        else {
            throw GuidedExecutionError.refreshBindingMismatch
        }
    }
}

public struct GuidedExecutionRefreshResponseDocument: Sendable {
    public let refreshRequestId: String
    public let refreshRequestDigest: String
    public let predecessorDecisionId: String
    public let predecessorDecisionContentDigest: String
    public let decisionDocument: GuidedReplayDecisionDocument
    public let rawData: Data
    public let canonicalData: Data

    public init(serverData: Data) throws {
        let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: serverData)
        guard case let .object(root) = value,
            Set(root.keys)
                == [
                    "protocol",
                    "protocolVersion",
                    "refreshRequestId",
                    "refreshRequestDigest",
                    "predecessorDecisionId",
                    "predecessorDecisionContentDigest",
                    "decision",
                ],
            case let .string(protocolName)? = root["protocol"],
            protocolName == "dev.jazz.guided-execution-refresh",
            let protocolVersion = Self.integer(root["protocolVersion"]),
            [1, 2].contains(protocolVersion),
            case let .string(requestId)? = root["refreshRequestId"],
            case let .string(requestDigest)? = root["refreshRequestDigest"],
            case let .string(predecessorId)? = root["predecessorDecisionId"],
            case let .string(predecessorDigest)? =
                root["predecessorDecisionContentDigest"],
            let decisionValue = root["decision"]
        else {
            throw GuidedExecutionError.invalidField("guided execution refresh response")
        }
        let canonical = try JazzArchiveCanonicalJSON.encode(value)
        let decisionDocument = try GuidedReplayDecisionDocument(
            serverData: JazzArchiveCanonicalJSON.encode(decisionValue))
        guard (protocolVersion == 1
                && decisionDocument.decision.artifactType == "guidedReplayDecision")
                || (protocolVersion == 2
                    && decisionDocument.decision.artifactType
                        == "guidedReplayPreparation")
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution refresh action-authority generation")
        }
        self.refreshRequestId = requestId
        self.refreshRequestDigest = requestDigest
        self.predecessorDecisionId = predecessorId
        self.predecessorDecisionContentDigest = predecessorDigest
        self.decisionDocument = decisionDocument
        self.rawData = serverData
        self.canonicalData = canonical
    }

    public func validate(
        intent: GuidedExecutionRefreshIntent,
        predecessor: GuidedReplayDecisionDocument
    ) throws {
        try intent.validate(predecessor: predecessor)
        guard refreshTextExactlyEqual(refreshRequestId, intent.refreshRequestId),
            refreshTextExactlyEqual(
                refreshRequestDigest,
                intent.refreshRequestDigest),
            refreshTextExactlyEqual(
                predecessorDecisionId,
                predecessor.decision.decisionId),
            refreshTextExactlyEqual(
                predecessorDecisionContentDigest,
                predecessor.decision.contentDigest),
            refreshTextExactlyEqual(
                decisionDocument.decision.request.requestedAt,
                intent.runtime.requestedAt),
            try refreshEncodedExactlyEqual(
                decisionDocument.decision.request.capabilities,
                intent.runtime.capabilities),
            try refreshEncodedExactlyEqual(
                decisionDocument.decision.request.locatorResolution,
                Optional(intent.runtime.locatorResolution)),
            try refreshEncodedExactlyEqual(
                decisionDocument.decision.request.applicationObservations,
                intent.runtime.applicationObservations)
        else {
            throw GuidedExecutionError.refreshBindingMismatch
        }
        try validateGuidedExecutionRefreshSuccessor(
            predecessor.decision,
            decisionDocument.decision)
    }

    private static func integer(_ value: JazzArchiveJSONValue?) -> Int? {
        switch value {
        case let .integer(number): return Int(exactly: number)
        case let .unsignedInteger(number): return Int(exactly: number)
        default: return nil
        }
    }
}

public func guidedExecutionRefreshRequestDigest(
    refreshRequestId: String,
    scope: GuidedExecutionScope,
    operatorId: String,
    predecessorDecisionId: String,
    predecessorDecisionContentDigest: String,
    runtime: GuidedReplayRefreshRuntime
) throws -> String {
    "sha256:"
        + JazzArchiveDigest.sha256Hex(
            try guidedExecutionRefreshRequestCanonicalData(
                refreshRequestId: refreshRequestId,
                scope: scope,
                operatorId: operatorId,
                predecessorDecisionId: predecessorDecisionId,
                predecessorDecisionContentDigest:
                    predecessorDecisionContentDigest,
                runtime: runtime))
}

/// Byte-exact digest material shared by desktop conformance tests and server mirrors.
public func guidedExecutionRefreshRequestCanonicalData(
    refreshRequestId: String,
    scope: GuidedExecutionScope,
    operatorId: String,
    predecessorDecisionId: String,
    predecessorDecisionContentDigest: String,
    runtime: GuidedReplayRefreshRuntime
) throws -> Data {
    let canonicalRuntime = try runtime.canonicalized()
    let material = JazzArchiveJSONValue.object([
        "requestKind": .string("guidedExecution.refresh"),
        "refreshRequestId": .string(refreshRequestId),
        "principalId": .string(operatorId),
        "scope": try encodedJSONValue(scope),
        "predecessorDecisionId": .string(predecessorDecisionId),
        "predecessorDecisionContentDigest": .string(
            predecessorDecisionContentDigest),
        "runtime": try encodedJSONValue(canonicalRuntime),
    ])
    return try JazzArchiveCanonicalJSON.encode(material)
}

public func validateGuidedExecutionRefreshSuccessor(
    _ predecessor: GuidedReplayDecision,
    _ successor: GuidedReplayDecision
) throws {
    let priorRequest = predecessor.request
    let nextRequest = successor.request
    // The response document already binds every fresh runtime value byte-for-value to the frozen
    // intent. Compare only identities and non-refreshable request claims here: a refresh exists
    // precisely because capability availability, match count, observed versions, compatibility,
    // timestamps, evidence, and resolver outcomes may have changed.
    guard predecessor.status == .ready,
        [.ready, .blocked].contains(successor.status),
        successor.decisionId != predecessor.decisionId,
        successor.contentDigest != predecessor.contentDigest,
        try refreshEncodedExactlyEqual(successor.runbook, predecessor.runbook),
        successor.attemptNumber == predecessor.attemptNumber,
        refreshOptionalTextExactlyEqual(successor.retryOf, predecessor.retryOf),
        refreshTextExactlyEqual(
            successor.logicalOperationKey,
            predecessor.logicalOperationKey),
        refreshTextExactlyEqual(
            nextRequest.requestVersion,
            priorRequest.requestVersion),
        refreshTextExactlyEqual(nextRequest.executionId, priorRequest.executionId),
        try refreshEncodedExactlyEqual(nextRequest.scope, priorRequest.scope),
        refreshTextExactlyEqual(
            nextRequest.runbookVersionId,
            priorRequest.runbookVersionId),
        refreshTextExactlyEqual(
            nextRequest.runbookContentDigest,
            priorRequest.runbookContentDigest),
        refreshTextExactlyEqual(nextRequest.operatorId, priorRequest.operatorId),
        refreshTextExactlyEqual(
            nextRequest.idempotencyKey,
            priorRequest.idempotencyKey),
        refreshOptionalTextExactlyEqual(
            nextRequest.targetStepId,
            priorRequest.targetStepId),
        try refreshEncodedExactlyEqual(
            nextRequest.processExecution,
            priorRequest.processExecution),
        nextRequest.processExecution != nil,
        try refreshEncodedExactlyEqual(
            nextRequest.preconditions,
            priorRequest.preconditions),
        refreshLocatorIdentityMatches(
            priorRequest.locatorResolution,
            nextRequest.locatorResolution),
        refreshApplicationIdentitiesMatch(
            priorRequest.applicationObservations,
            nextRequest.applicationObservations,
            allowMissing: successor.status == .blocked),
        refreshBusinessObjectIdentitiesMatch(
            priorRequest.businessObjectInputs,
            nextRequest.businessObjectInputs)
    else {
        throw GuidedExecutionError.refreshBindingMismatch
    }
    if successor.status == .ready {
        guard refreshOptionalTextExactlyEqual(
            successor.authorizedStep?.stepId,
            predecessor.authorizedStep?.stepId),
            refreshOptionalTextExactlyEqual(
                successor.authorizedStep?.variantRef,
                predecessor.authorizedStep?.variantRef)
        else {
            throw GuidedExecutionError.refreshBindingMismatch
        }
    }
}

private func encodedJSONValue<T: Encodable>(_ value: T) throws -> JazzArchiveJSONValue {
    try JSONDecoder().decode(
        JazzArchiveJSONValue.self,
        from: JSONEncoder().encode(value))
}

private func refreshEncodedExactlyEqual<T: Encodable>(
    _ lhs: T,
    _ rhs: T
) throws -> Bool {
    try JazzArchiveCanonicalJSON.encode(lhs)
        == JazzArchiveCanonicalJSON.encode(rhs)
}

private func refreshTextExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
    Data(lhs.utf8) == Data(rhs.utf8)
}

private func refreshOptionalTextExactlyEqual(
    _ lhs: String?,
    _ rhs: String?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (left?, right?): refreshTextExactlyEqual(left, right)
    default: false
    }
}

private func refreshLocatorIdentityMatches(
    _ lhs: GuidedLocatorResolution?,
    _ rhs: GuidedLocatorResolution?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
        true
    case let (left?, right?):
        refreshTextExactlyEqual(left.stepId, right.stepId)
            && refreshTextExactlyEqual(left.locatorId, right.locatorId)
            && left.kind == right.kind
            && refreshTextExactlyEqual(
                left.applicationId,
                right.applicationId)
    default:
        false
    }
}

private func refreshApplicationIdentitiesMatch(
    _ lhs: [GuidedApplicationObservation],
    _ rhs: [GuidedApplicationObservation],
    allowMissing: Bool
) -> Bool {
    // Required version policy is held by the immutable authorized Runbook step. The similarly
    // named `matchedVersionConstraint` belongs to the fresh observation and may change with its
    // outcome. A BLOCKED refresh may omit an application that could no longer be observed.
    struct Identity: Hashable {
        let applicationId: Data
        let environment: Data
    }
    func identities(_ values: [GuidedApplicationObservation]) -> [Identity] {
        values.map {
            Identity(
                applicationId: Data($0.applicationId.utf8),
                environment: Data(($0.environment ?? "").utf8))
        }
    }
    let prior = identities(lhs)
    let next = identities(rhs)
    guard Set(prior).count == prior.count, Set(next).count == next.count else {
        return false
    }
    return allowMissing
        ? Set(next).isSubset(of: Set(prior))
        : Set(next) == Set(prior)
}

private func refreshBusinessObjectIdentitiesMatch(
    _ lhs: [GuidedBusinessObjectInput],
    _ rhs: [GuidedBusinessObjectInput]
) -> Bool {
    struct Identity: Hashable {
        let role: Data
        let companyId: Data
        let areaId: Data
        let processId: Data
        let systemNamespace: Data
        let connectionId: Data
        let objectType: Data
        let externalId: Data
    }
    func identities(_ values: [GuidedBusinessObjectInput]) -> [Identity] {
        values.map {
            Identity(
                role: Data($0.role.utf8),
                companyId: Data($0.scope.companyId.utf8),
                areaId: Data($0.scope.areaId.utf8),
                processId: Data($0.scope.processId.utf8),
                systemNamespace: Data($0.systemNamespace.utf8),
                connectionId: Data($0.connectionId.utf8),
                objectType: Data($0.objectType.utf8),
                externalId: Data($0.externalId.utf8))
        }
    }
    let left = identities(lhs)
    let right = identities(rhs)
    guard Set(left).count == left.count, Set(right).count == right.count else {
        return false
    }
    return Set(left) == Set(right)
}

extension GuidedRuntimeSnapshot {
    /// Construct the candidate runtime returned by a fresh server decision. The executable must
    /// still revalidate the live target and add a decision-bound user confirmation before this
    /// value can authorize PREPARE locally.
    public init(replayRequest request: GuidedReplayRequest) throws {
        guard let locatorResolution = request.locatorResolution else {
            throw GuidedExecutionError.invalidField(
                "refreshed replay request locatorResolution")
        }
        self.init(
            observedAt: request.requestedAt,
            operatorId: request.operatorId,
            capabilities: request.capabilities,
            preconditions: request.preconditions,
            locatorResolution: locatorResolution,
            applicationObservations: request.applicationObservations,
            businessObjectInputs: request.businessObjectInputs,
            userConfirmation: nil)
    }
}

/// Losslessly admitted server launch material. The envelope is only a portable handoff carrier:
/// the desktop re-prepares its decision with the configured server before CLAIM, and the runtime
/// seed is revalidated against live OS state before a human is guided to the target.
public struct GuidedReplayDesktopHandoff: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let handoffId: String
    public let expiresAt: String
    public let nativeGovernanceURL: String
    public let targetDeviceId: String
    public let operatorId: String
    public let scope: GuidedExecutionScope
    public let decisionId: String
    public let decisionContentDigest: String
    public let executionId: String
    public let runbookVersionId: String
    public let runbookContentDigest: String
    public let governedSkillRef: GuidedGovernedSkillReference?
    public let capability: String

    public init(
        schemaVersion: Int = 1,
        handoffId: String,
        expiresAt: String,
        nativeGovernanceURL: String,
        targetDeviceId: String,
        operatorId: String,
        scope: GuidedExecutionScope,
        decisionId: String,
        decisionContentDigest: String,
        executionId: String,
        runbookVersionId: String,
        runbookContentDigest: String,
        governedSkillRef: GuidedGovernedSkillReference?,
        capability: String
    ) {
        self.schemaVersion = schemaVersion
        self.handoffId = handoffId
        self.expiresAt = expiresAt
        self.nativeGovernanceURL = nativeGovernanceURL
        self.targetDeviceId = targetDeviceId
        self.operatorId = operatorId
        self.scope = scope
        self.decisionId = decisionId
        self.decisionContentDigest = decisionContentDigest
        self.executionId = executionId
        self.runbookVersionId = runbookVersionId
        self.runbookContentDigest = runbookContentDigest
        self.governedSkillRef = governedSkillRef
        self.capability = capability
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiry = Timestamps.parse(expiresAt) else { return true }
        return expiry <= now
    }
}

public struct GuidedExecutionLaunchPacket: Equatable, Sendable {
    public let protocolVersion: Int
    public let approvedRunbook: GuidedApprovedRunbookPin
    public let decisionDocument: GuidedReplayDecisionDocument
    public let priorReceipts: [GuidedExecutionReceipt]
    public let runtime: GuidedRuntimeSnapshot
    public let handoff: GuidedReplayDesktopHandoff?

    public init(
        protocolVersion: Int = 1,
        approvedRunbook: GuidedApprovedRunbookPin,
        decisionDocument: GuidedReplayDecisionDocument,
        priorReceipts: [GuidedExecutionReceipt],
        runtime: GuidedRuntimeSnapshot,
        handoff: GuidedReplayDesktopHandoff? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.approvedRunbook = approvedRunbook
        self.decisionDocument = decisionDocument
        self.priorReceipts = priorReceipts
        self.runtime = runtime
        self.handoff = handoff
    }

    public func transportMode() throws -> GuidedExecutionLaunchTransportMode {
        switch (protocolVersion, handoff) {
        case (1, nil):
            return .legacy
        case (2...3, let handoff?):
            return .deviceBound(handoff)
        default:
            throw GuidedExecutionError.invalidField(
                "guided execution launch transport")
        }
    }
}

public enum GuidedExecutionLaunchTransportMode: Equatable, Sendable {
    case legacy
    case deviceBound(GuidedReplayDesktopHandoff)
}

/// Strictly admits the production server-to-desktop envelope. Conformance fixtures are not a
/// production launch authority; unknown fields, alternate protocols, and versions fail closed.
public enum GuidedExecutionLaunchPacketImporter {
    private static let productionProtocol = "dev.jazz.guided-execution-launch"
    private static let commonKeys: Set<String> = [
        "protocol",
        "protocolVersion",
        "approvedRunbook",
        "decision",
        "priorReceipts",
        "runtime",
    ]
    private static let handoffKeys: Set<String> = [
        "schemaVersion",
        "handoffId",
        "expiresAt",
        "nativeGovernanceURL",
        "targetDeviceId",
        "operatorId",
        "scope",
        "decisionId",
        "decisionContentDigest",
        "executionId",
        "runbookVersionId",
        "runbookContentDigest",
        "governedSkillRef",
        "capability",
    ]

    public static func decode(_ data: Data) throws -> GuidedExecutionLaunchPacket {
        let value = try JSONDecoder().decode(JazzArchiveJSONValue.self, from: data)
        guard case let .object(root) = value else {
            throw GuidedExecutionError.invalidField("guided execution launch root")
        }
        guard case let .string(protocolName)? = root["protocol"],
            protocolName == productionProtocol,
            let protocolVersion = integer(root["protocolVersion"]),
            [1, 2, 3].contains(protocolVersion)
        else {
            throw GuidedExecutionError.invalidField("guided execution launch protocol")
        }
        let expectedKeys =
            protocolVersion == 1 ? commonKeys : commonKeys.union(["handoff"])
        guard Set(root.keys) == expectedKeys else {
            throw GuidedExecutionError.invalidField("guided execution launch shape")
        }

        let approved: GuidedApprovedRunbookPin = try typed(
            root["approvedRunbook"], "approvedRunbook")
        guard let decisionValue = root["decision"] else {
            throw GuidedExecutionError.invalidField("guided execution launch decision")
        }
        let decisionDocument = try GuidedReplayDecisionDocument(
            serverData: JazzArchiveCanonicalJSON.encode(decisionValue))
        guard case let .array(receiptValues)? = root["priorReceipts"] else {
            throw GuidedExecutionError.invalidField("guided execution launch priorReceipts")
        }
        let receiptDocuments = try receiptValues.map {
            try GuidedExecutionReceiptDocument(
                serverData: JazzArchiveCanonicalJSON.encode($0))
        }
        let runtime: GuidedRuntimeSnapshot = try typed(root["runtime"], "runtime")
        let decision = decisionDocument.decision
        let expectedAuthorityGeneration =
            (protocolVersion < 3
                && decision.artifactType == "guidedReplayDecision"
                && decision.authorizedStep?.instruction != nil)
            || (protocolVersion == 3
                && decision.artifactType == "guidedReplayPreparation"
                && decision.schemaVersion == "2"
                && decision.actionAuthorityProtocol == "dev.jazz.action-authority"
                && decision.actionAuthorityProtocolVersion == 2
                && decision.authorizedStep?.instruction == nil
                && decision.authorizedStep?.instructionDigest != nil)
        guard approved.status == .approved,
            expectedAuthorityGeneration,
            approved.runbookId == decision.runbook.runbookId,
            approved.runbookVersionId == decision.runbook.runbookVersionId,
            approved.contentDigest == decision.runbook.contentDigest,
            approved.version == decision.runbook.version,
            approved.scope == decision.runbook.scope,
            decision.status == .ready,
            decision.authorizedStep != nil
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution launch approved RunbookVersion pin")
        }
        guard runtime.operatorId == decision.request.operatorId,
            runtime.capabilities == decision.request.capabilities,
            runtime.preconditions == decision.request.preconditions,
            runtime.locatorResolution == decision.request.locatorResolution,
            runtime.applicationObservations == decision.request.applicationObservations,
            runtime.businessObjectInputs == decision.request.businessObjectInputs
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution launch runtime/request binding")
        }
        let handoff: GuidedReplayDesktopHandoff?
        if protocolVersion >= 2 {
            guard case let .object(handoffObject)? = root["handoff"],
                Set(handoffObject.keys) == handoffKeys
            else {
                throw GuidedExecutionError.invalidField(
                    "guided execution launch handoff shape")
            }
            let admitted: GuidedReplayDesktopHandoff = try typed(
                root["handoff"], "handoff")
            try validate(
                handoff: admitted,
                approvedRunbook: approved,
                decision: decision)
            handoff = admitted
        } else {
            handoff = nil
        }
        return GuidedExecutionLaunchPacket(
            protocolVersion: protocolVersion,
            approvedRunbook: approved,
            decisionDocument: decisionDocument,
            priorReceipts: receiptDocuments.map(\.receipt),
            runtime: runtime,
            handoff: handoff)
    }

    private static func validate(
        handoff: GuidedReplayDesktopHandoff,
        approvedRunbook: GuidedApprovedRunbookPin,
        decision: GuidedReplayDecision
    ) throws {
        guard handoff.schemaVersion == 1,
            matches(handoff.handoffId, #"^rhc_[a-f0-9]{64}$"#),
            matches(
                handoff.capability,
                #"^rhc_[a-f0-9]{64}\.[A-Za-z0-9_-]{43}$"#),
            handoff.capability.hasPrefix("\(handoff.handoffId)."),
            matches(
                handoff.expiresAt,
                #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"#),
            Timestamps.parse(handoff.expiresAt) != nil,
            matches(
                handoff.targetDeviceId,
                #"^[a-z0-9][a-z0-9-]{0,63}$"#),
            boundedText(handoff.operatorId),
            boundedText(handoff.executionId),
            matches(handoff.decisionId, #"^grd_[a-f0-9]{32}$"#),
            matches(
                handoff.decisionContentDigest,
                #"^sha256:[a-f0-9]{64}$"#),
            matches(handoff.runbookVersionId, #"^rbv_[a-f0-9]{32}$"#),
            matches(
                handoff.runbookContentDigest,
                #"^sha256:[a-f0-9]{64}$"#),
            let governanceURL = GuidedExecutionEndpointBinding.normalize(
                handoff.nativeGovernanceURL),
            governanceURL.absoluteString == handoff.nativeGovernanceURL,
            governanceURL.path.hasSuffix("/api/process-governance"),
            handoff.operatorId == decision.request.operatorId,
            handoff.scope == decision.runbook.scope,
            handoff.scope == approvedRunbook.scope,
            handoff.decisionId == decision.decisionId,
            handoff.decisionContentDigest == decision.contentDigest,
            handoff.executionId == decision.request.executionId,
            handoff.runbookVersionId == decision.runbook.runbookVersionId,
            handoff.runbookVersionId == approvedRunbook.runbookVersionId,
            handoff.runbookContentDigest == decision.runbook.contentDigest,
            handoff.runbookContentDigest == approvedRunbook.contentDigest,
            handoff.governedSkillRef == decision.governedSkillRef
        else {
            throw GuidedExecutionError.invalidField(
                "guided execution launch handoff binding")
        }
    }

    private static func boundedText(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.count <= 1_000
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7f
            }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func typed<T: Decodable>(
        _ value: JazzArchiveJSONValue?,
        _ field: String
    ) throws -> T {
        guard let value else {
            throw GuidedExecutionError.invalidField("guided execution launch \(field)")
        }
        do {
            return try JSONDecoder().decode(
                T.self, from: JazzArchiveCanonicalJSON.encode(value))
        } catch {
            throw GuidedExecutionError.invalidField("guided execution launch \(field)")
        }
    }

    private static func integer(_ value: JazzArchiveJSONValue?) -> Int? {
        switch value {
        case let .integer(number): return Int(exactly: number)
        case let .unsignedInteger(number): return Int(exactly: number)
        default: return nil
        }
    }
}
