import Foundation
import JazzCaptureCore

enum LiveCompatibilityStatusHTTPError: Error, Equatable, CustomStringConvertible {
    case invalidEndpoint
    case invalidCaptureIdentity
    case credentialUnavailable
    case notFound
    case retryable(Int)
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidResponse

    var description: String {
        switch self {
        case .invalidEndpoint:
            "Live parity requires a valid signed Jazz Archive enrollment."
        case .invalidCaptureIdentity:
            "Live parity capture identity is invalid."
        case .credentialUnavailable:
            "Reconnect this device to read live parity."
        case .notFound:
            "Live projection has not reached Jazz yet."
        case .retryable(let status):
            "Live parity is temporarily unavailable\(status == 0 ? "" : " (HTTP \(status))")."
        case .unexpectedStatus(let status):
            "Live parity returned HTTP \(status)."
        case .responseTooLarge:
            "Live parity response exceeded its hard byte limit."
        case .invalidResponse:
            "Live parity response did not match the authenticated capture."
        }
    }
}

struct LiveCompatibilityDiscrepancyStatus: Decodable, Equatable, Sendable {
    let discrepancyId: String
    let kind: String
    let itemKind: String
    let itemId: String
    let expectedDigest: String?
    let actualDigest: String?
    let firstObservedAt: String
    let lastObservedAt: String
    let occurrenceCount: Int
    let detailCode: String
}

struct LiveCompatibilityCaptureStatus: Decodable, Equatable, Sendable {
    let captureId: String
    let archiveId: String
    let originId: String
    let state: String
    let provisional: Bool
    let canonicalAuthority: String
    let acceptedIngestId: String?
    let acceptedCommitId: String?
    let acceptedCommitDigest: String?
    let firstReceivedAt: String
    let lastReceivedAt: String
    let reconciledAt: String?
    let uniqueItemCount: Int
    let deliveryCount: Int
    let provisionalItemCount: Int
    let discrepancyCounts: [String: Int]
    let discrepancies: [LiveCompatibilityDiscrepancyStatus]
    let discrepanciesTruncated: Bool
    let itemsTruncated: Bool

    private static let allowedStates: Set<String> = [
        "provisional",
        "archive_rejected",
        "archive_quarantined",
        "reconciled_zero",
        "reconciled_discrepant",
    ]
    private static let allowedAuthorities: Set<String> = ["none", "accepted_archive"]
    private static let allowedDiscrepancies: Set<String> = [
        "live_only",
        "archive_only",
        "duplicate",
        "late",
        "mutated",
        "extra",
        "reordered",
        "unsupported",
    ]

    var discrepancyTotal: Int {
        discrepancyCounts.values.reduce(0, +)
    }

    var presentation: String {
        if canonicalAuthority == "accepted_archive" {
            return discrepancyTotal == 0
                ? "Archive canonical · zero discrepancies"
                : "Archive canonical · \(discrepancyTotal) discrepancy occurrence(s)"
        }
        switch state {
        case "archive_rejected":
            return "Provisional only · archive rejected"
        case "archive_quarantined":
            return "Provisional only · archive quarantined"
        default:
            return "Provisional · \(provisionalItemCount) live item(s) · awaiting accepted archive"
        }
    }

    var discrepancyPresentation: String? {
        let values = discrepancyCounts
            .filter { $0.value > 0 }
            .sorted { left, right in
                left.key == right.key ? left.value > right.value : left.key < right.key
            }
            .map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value)" }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    func validate(expectedCaptureId: String, expectedArchiveId: String) throws {
        guard captureId == expectedCaptureId,
            archiveId == expectedArchiveId,
            Self.allowedStates.contains(state),
            Self.allowedAuthorities.contains(canonicalAuthority),
            uniqueItemCount >= 0,
            deliveryCount >= uniqueItemCount,
            provisionalItemCount >= 0,
            provisionalItemCount <= uniqueItemCount,
            discrepancies.count <= 25,
            discrepancyCounts.count <= Self.allowedDiscrepancies.count,
            discrepancyCounts.allSatisfy({
                Self.allowedDiscrepancies.contains($0.key) && $0.value >= 0
            }),
            discrepancies.allSatisfy({
                Self.allowedDiscrepancies.contains($0.kind) && $0.occurrenceCount >= 1
            }),
            (canonicalAuthority == "accepted_archive") == (acceptedIngestId != nil),
            (canonicalAuthority == "accepted_archive") == (acceptedCommitId != nil),
            (canonicalAuthority == "accepted_archive") == (acceptedCommitDigest != nil),
            provisional == (canonicalAuthority == "none")
        else { throw LiveCompatibilityStatusHTTPError.invalidResponse }
    }
}

/// Read-only, same-origin native status adapter. Scope comes only from the signed enrollment token;
/// capture/archive IDs are response-binding assertions and never authorize access.
final class LiveCompatibilityStatusHTTPClient: @unchecked Sendable {
    private static let maximumResponseBytes = 256 * 1_024
    private static let captureIdentity = try! NSRegularExpression(
        pattern:
            #"^cap-[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#
    )

    private let routeBinding: JazzArchiveUploadRouteBinding
    private let capturesURL: URL
    private let credentialProvider: any JazzArchiveCredentialProvider
    private let session: JazzCredentialSafeHTTPSession

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        credentialProvider: any JazzArchiveCredentialProvider,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        guard routeBinding.hasSignedAuthority,
            let normalized = JazzArchiveControlPlaneURL.normalize(
                routeBinding.ingestEndpoint),
            normalized == routeBinding.ingestEndpoint,
            normalized.hasSuffix("/api/archive-ingests"),
            let capturesURL = URL(
                string:
                    String(normalized.dropLast("/api/archive-ingests".count))
                    + "/api/live-compatibility/captures")
        else { throw LiveCompatibilityStatusHTTPError.invalidEndpoint }
        self.routeBinding = routeBinding
        self.capturesURL = capturesURL
        self.credentialProvider = credentialProvider
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    @MainActor
    convenience init(
        routeBinding: JazzArchiveUploadRouteBinding,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        try self.init(
            routeBinding: routeBinding,
            credentialProvider: KeychainArchiveCredentialProvider(),
            sessionConfiguration: sessionConfiguration)
    }

    func status(
        captureId: String,
        archiveId: String
    ) async throws -> LiveCompatibilityCaptureStatus {
        guard Self.isCaptureIdentity(captureId) else {
            throw LiveCompatibilityStatusHTTPError.invalidCaptureIdentity
        }
        let credential: JazzArchiveScopedDeviceCredential
        do {
            credential = try await credentialProvider.credential(for: routeBinding)
        } catch {
            throw LiveCompatibilityStatusHTTPError.credentialUnavailable
        }
        guard var components = URLComponents(
            url: capturesURL.appendingPathComponent(captureId),
            resolvingAgainstBaseURL: false)
        else { throw LiveCompatibilityStatusHTTPError.invalidEndpoint }
        components.queryItems = [
            URLQueryItem(name: "discrepancyLimit", value: "25"),
            URLQueryItem(name: "itemLimit", value: "1"),
        ]
        guard let url = components.url else {
            throw LiveCompatibilityStatusHTTPError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            routeBinding.scope.deviceId,
            forHTTPHeaderField: "X-Jazz-Device-Id")
        credential.withValue {
            request.setValue($0, forHTTPHeaderField: "X-StorageApi-Token")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: Self.maximumResponseBytes)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw LiveCompatibilityStatusHTTPError.responseTooLarge
        } catch {
            throw LiveCompatibilityStatusHTTPError.retryable(0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LiveCompatibilityStatusHTTPError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw LiveCompatibilityStatusHTTPError.credentialUnavailable
        case 404:
            throw LiveCompatibilityStatusHTTPError.notFound
        case 408, 425, 429, 500...599:
            throw LiveCompatibilityStatusHTTPError.retryable(http.statusCode)
        default:
            throw LiveCompatibilityStatusHTTPError.unexpectedStatus(http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Cache-Control")?
            .lowercased().contains("no-store") == true
        else { throw LiveCompatibilityStatusHTTPError.invalidResponse }
        let value: LiveCompatibilityCaptureStatus
        do {
            value = try JSONDecoder().decode(
                LiveCompatibilityCaptureStatus.self,
                from: data)
        } catch {
            throw LiveCompatibilityStatusHTTPError.invalidResponse
        }
        try value.validate(
            expectedCaptureId: captureId,
            expectedArchiveId: archiveId)
        return value
    }

    private static func isCaptureIdentity(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return captureIdentity.firstMatch(in: value, range: range)?.range == range
    }
}
