import Foundation
import JasnostCaptureCore

/// The result of exactly one renewal attempt. Every failure carries the disposition that decides
/// whether the same request may be replayed — the client itself never retries.
enum DeviceTokenRenewalOutcome {
    case renewed(JazzDeviceTokenRenewalGrant)
    case failed(JazzDeviceTokenRenewalDisposition, retryAfter: TimeInterval?)
}

/// System half of unattended device-token renewal: one same-origin POST derived from the signed
/// archive route, with the credential the device already holds.
///
/// Every decision (route derivation, request bytes, response validation, failure classification)
/// lives in ``JasnostCaptureCore`` and is unit-tested there. This adapter only performs I/O.
final class DeviceTokenRenewalHTTPClient: @unchecked Sendable {
    let route: JazzDeviceTokenRenewalRoute
    private let session: JazzCredentialSafeHTTPSession

    init(
        routeBinding: JazzArchiveUploadRouteBinding,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) throws {
        route = try JazzDeviceTokenRenewalRoute(routeBinding: routeBinding)
        let configuration = sessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        session = JazzCredentialSafeHTTPSession(configuration: configuration)
    }

    /// Perform one attempt. `request` must be the SAME assertion across a retry sequence: the
    /// server keeps a just-superseded credential renewal-valid for a bounded grace window, so an
    /// exact replay recovers a response that was lost in flight.
    func renew(
        request renewalRequest: JazzDeviceTokenRenewalRequest,
        credential: JazzArchiveScopedDeviceCredential,
        routing: JazzArchiveEnrollmentRouting,
        now: Date = Date()
    ) async -> DeviceTokenRenewalOutcome {
        let urlRequest: URLRequest
        do {
            urlRequest = try route.request(
                body: try renewalRequest.body(),
                credential: credential)
        } catch {
            return .failed(
                .clientDefect("the renewal request could not be built"),
                retryAfter: nil)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.boundedData(
                for: urlRequest,
                maximumResponseBytes: JazzDeviceTokenRenewalRoute.maximumResponseBytes)
        } catch let error as URLError {
            // Never interpolate `localizedDescription`: it can embed the URL, and this string is
            // shown verbatim in the menu bar.
            return .failed(
                JazzDeviceTokenRenewalFailure.transport(
                    "offline or unreachable (URLError \(error.code.rawValue))"),
                retryAfter: nil)
        } catch {
            return .failed(
                JazzDeviceTokenRenewalFailure.transport("the renewal response could not be read"),
                retryAfter: nil)
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed(
                JazzDeviceTokenRenewalFailure.transport("the renewal response was not HTTP"),
                retryAfter: nil)
        }
        let retryAfter = JazzDeviceTokenRenewalFailure.retryAfter(
            http.value(forHTTPHeaderField: "Retry-After"))
        guard http.statusCode == 200 else {
            return .failed(
                JazzDeviceTokenRenewalFailure.classify(
                    status: http.statusCode,
                    code: JazzDeviceTokenRenewalFailure.code(inResponse: data)),
                retryAfter: retryAfter)
        }
        // A renewed credential must never be cacheable. A 200 without the server's own no-store
        // promise did not come from this route as deployed.
        guard http.value(forHTTPHeaderField: "Cache-Control")?
            .lowercased().contains("no-store") == true
        else {
            return .failed(
                JazzDeviceTokenRenewalFailure.transport(
                    "the renewal response was not marked no-store"),
                retryAfter: nil)
        }
        do {
            let grant = try JazzDeviceTokenRenewalGrant(
                responseData: data,
                request: renewalRequest,
                currentRouting: routing,
                now: now)
            return .renewed(grant)
        } catch let error as JazzDeviceTokenRenewalError {
            // A malformed or mismatched grant is treated as transient: the stored credential is
            // untouched, and a deployment fixed server-side heals on the next attempt.
            return .failed(
                JazzDeviceTokenRenewalFailure.transport("\(error)"),
                retryAfter: nil)
        } catch {
            return .failed(
                JazzDeviceTokenRenewalFailure.transport("the renewal grant was rejected"),
                retryAfter: nil)
        }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }
}
