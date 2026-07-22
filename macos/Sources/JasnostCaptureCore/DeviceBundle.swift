import Foundation

/// A one-time **enrollment bundle** (ADR 0005, Phase 1) an admin generates in the Data App and the
/// desktop imports instead of pasting a raw Keboola master token. The bundle carries a per-device,
/// scoped, expiring Storage token plus (optionally) the OTLP stream endpoint, so the project master
/// key never lands on a laptop's Keychain.
///
/// Pure Foundation + Codable so parsing and validation are unit-testable with no networking. The
/// executable target (`JasnostCapture`) does the Keychain write and the live `tokens/verify` refusal
/// — this type only decodes and cheaply validates the pasted blob.
///
/// Secret handling: `token` is the device's scoped Storage token and `streamEndpoint` embeds the
/// stream secret in its path. Neither is logged; the caller stores them ONLY in the Keychain (same
/// accounts the raw-token path uses).
public struct DeviceBundle: Codable, Equatable, Sendable {
    /// Discriminator — MUST be ``kind`` for a bundle to be accepted (guards against a raw token or
    /// some other JSON being pasted into the bundle field).
    public static let expectedKind = "jazz-device-bundle"

    /// The bundle's shape discriminator (validated to equal ``expectedKind``).
    public let kind: String
    /// The enrolled device's id (`device_registry` key). Required, non-empty.
    public let deviceId: String
    /// The per-device OTLP stream source id, when the admin provisioned one. Optional in Phase 1 —
    /// the app may register a shared endpoint instead (see ADR 0005).
    public let streamSourceId: String?
    /// The full OTLP ingest URL (path embeds the stream secret). Optional — when absent, the device
    /// keeps whatever endpoint it already has, or the admin supplies it out of band.
    public let streamEndpoint: String?
    /// The device's scoped, expiring Storage token — the one-time reveal. Required, non-empty.
    public let token: String
    /// The scoped token's id (persisted server-side for rotation/revocation). Required, non-empty.
    public let tokenId: String
    /// ISO-8601 expiry of ``token`` (the app re-enrolls before it lapses).
    public let expiresAt: String
    /// The Keboola components the scoped token may run (informational on the device).
    public let componentAccess: [String]?

    enum CodingKeys: String, CodingKey {
        case kind, deviceId, streamSourceId, streamEndpoint, token, tokenId, expiresAt,
            componentAccess
    }

    public init(
        kind: String = DeviceBundle.expectedKind,
        deviceId: String,
        streamSourceId: String? = nil,
        streamEndpoint: String? = nil,
        token: String,
        tokenId: String,
        expiresAt: String,
        componentAccess: [String]? = nil
    ) {
        self.kind = kind
        self.deviceId = deviceId
        self.streamSourceId = streamSourceId
        self.streamEndpoint = streamEndpoint
        self.token = token
        self.tokenId = tokenId
        self.expiresAt = expiresAt
        self.componentAccess = componentAccess
    }

    /// The parsed ``expiresAt``, tolerant of fractional seconds; `nil` when absent/unparseable.
    public var expiresAtDate: Date? { Timestamps.parse(expiresAt) }

    /// Typed parse failures — surfaced verbatim to the admin so a bad paste is self-explaining.
    public enum BundleError: Error, Equatable, CustomStringConvertible {
        /// The blob isn't JSON, or is JSON of the wrong shape (missing required keys).
        case malformed(String)
        /// Valid JSON but not a jazz device bundle (`kind` missing or wrong).
        case notJazzBundle
        /// The bundle decoded but its ``token`` (or ``deviceId``) is empty / obviously invalid.
        case missingToken

        public var description: String {
            switch self {
            case let .malformed(detail):
                return "That doesn't look like an enrollment bundle (\(detail))."
            case .notJazzBundle:
                return "That JSON isn't a Jazz enrollment bundle (expected kind"
                    + " \"\(DeviceBundle.expectedKind)\")."
            case .missingToken:
                return "The enrollment bundle is missing a device token."
            }
        }
    }

    /// Parse a pasted enrollment bundle. Accepts the raw JSON object, a `data:` URL wrapping it, or a
    /// blob with surrounding whitespace/newlines (people paste from a variety of sources). Validates
    /// the discriminator and the required non-empty fields, and cheaply rejects a token that couldn't
    /// possibly be a scoped device token.
    ///
    /// This is only the CHEAP local gate. The authoritative "is this a master token?" refusal stays a
    /// live check: the caller runs the existing `tokens/verify` step and refuses to proceed when the
    /// verified token reports `isMaster`/`canManageTokens` (ADR 0005 contract 1) — see
    /// ``JasnostSession`` / the `KeboolaConnection` import flow in the executable target.
    public static func parse(_ text: String) -> Result<DeviceBundle, BundleError> {
        guard let jsonData = jsonPayload(from: text) else {
            return .failure(.malformed("not JSON"))
        }

        // Pre-check the discriminator BEFORE full decode so a wrong-kind blob returns `notJazzBundle`
        // rather than a generic decode error, even when other required keys happen to be present.
        if let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let kind = (object["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard kind == expectedKind else { return .failure(.notJazzBundle) }
        } else {
            return .failure(.malformed("not a JSON object"))
        }

        let bundle: DeviceBundle
        do {
            bundle = try JSONDecoder().decode(DeviceBundle.self, from: jsonData)
        } catch {
            // A jazz-kind object that still fails to decode is missing a required field
            // (deviceId/token/tokenId/expiresAt) — report it as malformed with the decode detail.
            return .failure(.malformed("\(error)"))
        }

        guard bundle.kind == expectedKind else { return .failure(.notJazzBundle) }

        let token = bundle.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceId = bundle.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !deviceId.isEmpty else { return .failure(.missingToken) }
        // Cheap sanity gate on the token shape (a scoped Storage token is `<projectId>-<...>` with
        // real length). This never *confirms* a scoped token — it only rejects an obviously-wrong
        // one so the admin isn't sent to the network for a paste error. The definitive master-token
        // refusal is the live `tokens/verify`/`isMaster` check in the caller (contract 1).
        guard looksLikeStorageToken(token) else { return .failure(.missingToken) }

        return .success(bundle)
    }

    // MARK: - Internals

    /// Decode the paste into JSON bytes: a bare JSON object, a `data:` URL wrapping one (base64 or
    /// percent-encoded), or either with surrounding whitespace. Returns nil when nothing JSON-shaped
    /// can be recovered.
    private static func jsonPayload(from text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("data:") {
            if let decoded = decodeDataURL(trimmed) { return decoded }
            return nil
        }

        // A bare JSON object (optionally with stray whitespace) — the common case.
        guard trimmed.hasPrefix("{") else { return nil }
        return trimmed.data(using: .utf8)
    }

    /// Extract the payload of a `data:` URL. Supports `;base64` and plain (percent-encoded) bodies;
    /// the media type is ignored (an admin export may use `application/json` or `text/plain`).
    private static func decodeDataURL(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let meta = url[url.startIndex..<comma].lowercased()
        let payload = String(url[url.index(after: comma)...])
        if meta.contains(";base64") {
            return Data(base64Encoded: payload)
        }
        // Plain data URL: the body is percent-encoded text.
        return (payload.removingPercentEncoding ?? payload).data(using: .utf8)
    }

    /// A cheap, conservative shape check for a Keboola Storage token: `<projectId>-<rest>` where the
    /// project id is numeric and the whole thing has real length. Deliberately permissive — it must
    /// accept every legitimately-minted scoped token; its only job is to reject an empty or clearly
    /// non-token paste so we don't round-trip a typo to the API.
    static func looksLikeStorageToken(_ token: String) -> Bool {
        let parts = token.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let projectId = parts[0]
        let rest = parts[1]
        guard !projectId.isEmpty, projectId.allSatisfy(\.isNumber) else { return false }
        // A real Storage token secret is long; a stray word or id won't clear this floor.
        return rest.count >= 16
    }
}
