import Foundation
import JazzCaptureCore

enum DeviceRecordingPlanHTTPError: Error, Equatable, CustomStringConvertible {
    case credentialUnavailable
    case notFound
    case retryable(Int)
    case unexpectedStatus(Int)
    case responseTooLarge
    case invalidResponse

    var description: String {
        switch self {
        case .credentialUnavailable:
            "Reconnect this device to read its recording plan."
        case .notFound:
            "This Jazz deployment does not serve a device recording plan."
        case .retryable(let status):
            "The recording plan is temporarily unavailable\(status == 0 ? "" : " (HTTP \(status))")."
        case .unexpectedStatus(let status):
            "The recording plan returned HTTP \(status)."
        case .responseTooLarge:
            "The recording plan response exceeded its hard byte limit."
        case .invalidResponse:
            "The recording plan did not match this device's enrollment."
        }
    }
}

/// System half of the device recording plan: one same-origin GET derived from the enrolled archive
/// route, with the device credential read from the Keychain for exactly that request.
///
/// Route derivation, request headers and response decoding live in ``JazzCaptureCore``
/// (``JazzDeviceRecordingPlanRoute`` / ``JazzDeviceRecordingPlan``) and are unit-tested there.
/// This adapter only performs I/O. Callers treat every error as "no plan" and fall back to the
/// Files registry lookup (``RegistryFetcher``) — a plan fetch never blocks capture.
final class DeviceRecordingPlanHTTPClient: @unchecked Sendable {
    let route: JazzDeviceRecordingPlanRoute
    private let routeBinding: JazzArchiveUploadRouteBinding
    private let credentialProvider: any JazzArchiveCredentialProvider
    private let session: JazzCredentialSafeHTTPSession

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        credentialProvider: any JazzArchiveCredentialProvider,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        route = try JazzDeviceRecordingPlanRoute(routeBinding: routeBinding)
        self.routeBinding = routeBinding
        self.credentialProvider = credentialProvider
        // The plan is small JSON — tight budgets, like the client's other JSON calls.
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 10
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

    /// Fetch and bind the plan to this device's enrollment. Throws on any failure.
    func plan() async throws -> JazzDeviceRecordingPlan {
        let credential: JazzArchiveScopedDeviceCredential
        do {
            credential = try await credentialProvider.credential(for: routeBinding)
        } catch {
            throw DeviceRecordingPlanHTTPError.credentialUnavailable
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.boundedData(
                for: route.request(credential: credential),
                maximumResponseBytes: JazzDeviceRecordingPlanRoute.maximumResponseBytes)
        } catch JazzCredentialSafeHTTPSessionError.responseTooLarge {
            throw DeviceRecordingPlanHTTPError.responseTooLarge
        } catch {
            throw DeviceRecordingPlanHTTPError.retryable(0)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DeviceRecordingPlanHTTPError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw DeviceRecordingPlanHTTPError.credentialUnavailable
        case 404:
            throw DeviceRecordingPlanHTTPError.notFound
        case 408, 425, 429, 500...599:
            throw DeviceRecordingPlanHTTPError.retryable(http.statusCode)
        default:
            throw DeviceRecordingPlanHTTPError.unexpectedStatus(http.statusCode)
        }
        guard let plan = JazzDeviceRecordingPlan.parse(data: data),
            (try? plan.validate(for: route)) != nil
        else { throw DeviceRecordingPlanHTTPError.invalidResponse }
        return plan
    }

    /// The declared process choices for ``areaId``, or nil when the route is unavailable or the
    /// plan does not cover that Area — the caller's cue to fall back to the Files lookup.
    func processChoices(areaId: String) async -> [ProcessChoice]? {
        guard let plan = try? await plan() else { return nil }
        return plan.processChoices(forAreaId: areaId)
    }
}
