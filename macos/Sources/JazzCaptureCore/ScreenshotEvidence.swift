import Foundation

/// Portable screenshot evidence carried in ``JazzArchiveArtifact.extensions``.
///
/// The namespace is versioned because macOS, the future Windows client, and the processor must
/// interpret the timing and capture scope identically. Current archives require the complete
/// profile. Profileless v1 screenshots are admitted only through the explicit, producer-pinned
/// legacy read-only validation mode.
public struct JazzArchiveScreenshotEvidenceV1: Equatable, Sendable {
    public static let namespace = "dev.jazz.capture.screenshot.v1"

    public static let requestStartedAtKey = "\(namespace).requestStartedAt"
    public static let frameCompletedAtKey = "\(namespace).frameCompletedAt"
    public static let monotonicDurationMillisKey = "\(namespace).monotonicDurationMillis"
    public static let scopeKey = "\(namespace).scope"
    public static let ownerBundleIdKey = "\(namespace).ownerBundleId"
    public static let windowIdKey = "\(namespace).windowId"
    public static let displayIdKey = "\(namespace).displayId"
    public static let excludedApplicationBundleIdsKey =
        "\(namespace).excludedApplicationBundleIds"

    public static let temporalIntervalReason = "\(namespace).temporal_interval"
    public static let displayFallbackReason = "\(namespace).display_fallback"
    public static let ownerMismatchReason = "\(namespace).owner_mismatch"
    public static let unavailableReason = "\(namespace).unavailable"

    private static let knownKeys: Set<String> = [
        requestStartedAtKey,
        frameCompletedAtKey,
        monotonicDurationMillisKey,
        scopeKey,
        ownerBundleIdKey,
        windowIdKey,
        displayIdKey,
        excludedApplicationBundleIdsKey,
    ]

    public enum Scope: Equatable, Sendable {
        case window(ownerBundleId: String, windowId: Int64)
        case display(displayId: Int64, excludedApplicationBundleIds: [String])
    }

    public var requestStartedAt: String
    public var frameCompletedAt: String
    public var monotonicDurationMillis: Int64
    public var scope: Scope

    public init(
        requestStartedAt: String,
        frameCompletedAt: String,
        monotonicDurationMillis: Int64,
        scope: Scope
    ) {
        self.requestStartedAt = requestStartedAt
        self.frameCompletedAt = frameCompletedAt
        self.monotonicDurationMillis = monotonicDurationMillis
        self.scope = scope
    }

    public var extensions: [String: JazzArchiveJSONValue] {
        var values: [String: JazzArchiveJSONValue] = [
            Self.requestStartedAtKey: .string(requestStartedAt),
            Self.frameCompletedAtKey: .string(frameCompletedAt),
            Self.monotonicDurationMillisKey: .integer(monotonicDurationMillis),
        ]
        switch scope {
        case .window(let ownerBundleId, let windowId):
            values[Self.scopeKey] = .string("window")
            values[Self.ownerBundleIdKey] = .string(ownerBundleId)
            values[Self.windowIdKey] = .integer(windowId)
        case .display(let displayId, let excludedApplicationBundleIds):
            values[Self.scopeKey] = .string("display")
            values[Self.displayIdKey] = .integer(displayId)
            values[Self.excludedApplicationBundleIdsKey] = .array(
                excludedApplicationBundleIds.sorted().map(JazzArchiveJSONValue.string))
        }
        return values
    }

    /// Decode the v1 namespace. Absence is reported to the caller so the archive validator can
    /// either reject it in current mode or apply the explicit legacy read-only admission policy.
    /// Unknown keys inside the v1 namespace are rejected rather than guessed.
    public static func decode(
        from extensions: [String: JazzArchiveJSONValue]?
    ) throws -> JazzArchiveScreenshotEvidenceV1? {
        guard let extensions else { return nil }
        let profileKeys = Set(extensions.keys.filter { $0.hasPrefix(Self.namespace + ".") })
        guard !profileKeys.isEmpty else { return nil }
        guard profileKeys.isSubset(of: knownKeys) else {
            throw JazzArchiveError.invalidField("artifact.extensions screenshot evidence v1 key")
        }

        let requestStartedAt = try string(
            extensions[requestStartedAtKey],
            field: requestStartedAtKey)
        let frameCompletedAt = try string(
            extensions[frameCompletedAtKey],
            field: frameCompletedAtKey)
        let duration = try integer(
            extensions[monotonicDurationMillisKey],
            field: monotonicDurationMillisKey)
        let scopeName = try string(extensions[scopeKey], field: scopeKey)
        let scope: Scope
        switch scopeName {
        case "window":
            guard
                extensions[displayIdKey] == nil,
                extensions[excludedApplicationBundleIdsKey] == nil
            else {
                throw JazzArchiveError.invalidField(
                    "artifact.extensions screenshot window scope")
            }
            scope = .window(
                ownerBundleId: try string(
                    extensions[ownerBundleIdKey],
                    field: ownerBundleIdKey),
                windowId: try integer(
                    extensions[windowIdKey],
                    field: windowIdKey))
        case "display":
            guard
                extensions[ownerBundleIdKey] == nil,
                extensions[windowIdKey] == nil
            else {
                throw JazzArchiveError.invalidField(
                    "artifact.extensions screenshot display scope")
            }
            scope = .display(
                displayId: try integer(
                    extensions[displayIdKey],
                    field: displayIdKey),
                excludedApplicationBundleIds: try stringArray(
                    extensions[excludedApplicationBundleIdsKey],
                    field: excludedApplicationBundleIdsKey))
        default:
            throw JazzArchiveError.invalidField(scopeKey)
        }

        let value = JazzArchiveScreenshotEvidenceV1(
            requestStartedAt: requestStartedAt,
            frameCompletedAt: frameCompletedAt,
            monotonicDurationMillis: duration,
            scope: scope)
        try value.validate()
        return value
    }

    public func validate() throws {
        guard
            let startMillis = Self.canonicalTimestampMillis(requestStartedAt),
            let endMillis = Self.canonicalTimestampMillis(frameCompletedAt)
        else {
            throw JazzArchiveError.invalidTimestamp(
                field: "artifact.extensions screenshot evidence v1",
                value: "\(requestStartedAt)..\(frameCompletedAt)")
        }
        guard endMillis >= startMillis else {
            throw JazzArchiveError.invalidField(
                "artifact.extensions screenshot frameCompletedAt before requestStartedAt")
        }
        guard (0...9_007_199_254_740_991).contains(monotonicDurationMillis) else {
            throw JazzArchiveError.invalidNumber(
                field: Self.monotonicDurationMillisKey)
        }
        guard endMillis - startMillis == monotonicDurationMillis else {
            throw JazzArchiveError.invalidField(
                "artifact.extensions screenshot interval differs from monotonic duration")
        }

        switch scope {
        case .window(let ownerBundleId, let windowId):
            guard
                !ownerBundleId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                (0...Int64(UInt32.max)).contains(windowId)
            else {
                throw JazzArchiveError.invalidField(
                    "artifact.extensions screenshot window scope")
            }
        case .display(let displayId, let excludedApplicationBundleIds):
            let sorted = excludedApplicationBundleIds.sorted()
            guard
                (0...Int64(UInt32.max)).contains(displayId),
                sorted == excludedApplicationBundleIds,
                Set(sorted).count == sorted.count,
                sorted.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
            else {
                throw JazzArchiveError.invalidField(
                    "artifact.extensions screenshot display scope")
            }
        }
    }

    private static func string(
        _ value: JazzArchiveJSONValue?,
        field: String
    ) throws -> String {
        guard case .string(let result) = value, !result.isEmpty else {
            throw JazzArchiveError.invalidField(field)
        }
        return result
    }

    private static func integer(
        _ value: JazzArchiveJSONValue?,
        field: String
    ) throws -> Int64 {
        guard case .integer(let result) = value else {
            throw JazzArchiveError.invalidField(field)
        }
        return result
    }

    private static func stringArray(
        _ value: JazzArchiveJSONValue?,
        field: String
    ) throws -> [String] {
        guard case .array(let values) = value else {
            throw JazzArchiveError.invalidField(field)
        }
        return try values.map { try string($0, field: field) }
    }

    /// V1 deliberately uses one cross-runtime timestamp representation. Millisecond strings make
    /// duration arithmetic integer-exact in Swift, Python, and future Windows producers instead of
    /// relying on each runtime's fractional parsing and ties-to-even behaviour.
    private static func canonicalTimestampMillis(_ value: String) -> Int64? {
        let bytes = Array(value.utf8)
        guard
            bytes.count == 24,
            bytes[4] == 45,
            bytes[7] == 45,
            bytes[10] == 84,
            bytes[13] == 58,
            bytes[16] == 58,
            bytes[19] == 46,
            bytes[23] == 90
        else { return nil }
        let punctuation = Set([4, 7, 10, 13, 16, 19, 23])
        guard bytes.indices.allSatisfy({ index in
            punctuation.contains(index) || (48...57).contains(bytes[index])
        }),
            let date = Timestamps.parse(value),
            Timestamps.iso8601(date) == value
        else { return nil }
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        guard
            milliseconds.isFinite,
            milliseconds >= -9_007_199_254_740_991,
            milliseconds <= 9_007_199_254_740_991
        else { return nil }
        return Int64(milliseconds)
    }
}
