import CryptoKit
import Foundation
import JasnostCaptureCore

/// Out-of-band trust used to authenticate copied Jazz enrollment bundles.
///
/// A bundle contains only a protected ``kid`` selector. It can never add a key, replace this
/// issuer/audience policy, or supply a URL from which a key is fetched. Production configuration
/// is read from the code-signed application Info.plist; an enterprise may therefore stamp the same
/// values through its signed build pipeline without making editable bundle JSON its own trust root.
public struct EnrollmentTrustPolicy: Sendable {
    public let issuer: String
    public let audience: String
    public let clockSkew: TimeInterval
    fileprivate let publicKeysByKeyID: [String: Curve25519.Signing.PublicKey]

    public init(
        issuer: String,
        audience: String,
        publicKeysByKeyID: [String: String],
        clockSkew: TimeInterval = 0
    ) throws {
        guard EnrollmentURLPolicy.isSecureOrigin(issuer) else {
            throw EnrollmentTrustPolicyError.invalidIssuer
        }
        guard
            !audience.isEmpty,
            audience == audience.trimmingCharacters(in: .whitespacesAndNewlines),
            audience.unicodeScalars.count <= 256
        else {
            throw EnrollmentTrustPolicyError.invalidAudience
        }
        guard clockSkew.isFinite, clockSkew >= 0 else {
            throw EnrollmentTrustPolicyError.invalidClockSkew
        }
        guard !publicKeysByKeyID.isEmpty else {
            throw EnrollmentTrustPolicyError.missingPublicKeys
        }

        var parsed: [String: Curve25519.Signing.PublicKey] = [:]
        for (keyID, encodedKey) in publicKeysByKeyID {
            guard EnrollmentEncoding.isValidKeyID(keyID) else {
                throw EnrollmentTrustPolicyError.invalidKeyID
            }
            guard
                let rawKey = EnrollmentEncoding.decodeBase64URL(
                    encodedKey,
                    maximumBytes: 32),
                rawKey.count == 32,
                let publicKey = try? Curve25519.Signing.PublicKey(
                    rawRepresentation: rawKey)
            else {
                throw EnrollmentTrustPolicyError.invalidPublicKey
            }
            parsed[keyID] = publicKey
        }

        self.issuer = issuer
        self.audience = audience
        self.clockSkew = clockSkew
        self.publicKeysByKeyID = parsed
    }

    func publicKey(for keyID: String) -> Curve25519.Signing.PublicKey? {
        publicKeysByKeyID[keyID]
    }
}

public enum EnrollmentTrustPolicyError: Error, Equatable, CustomStringConvertible {
    case invalidIssuer
    case invalidAudience
    case invalidClockSkew
    case missingPublicKeys
    case invalidKeyID
    case invalidPublicKey
    case invalidRedemptionOrigins

    public var description: String {
        switch self {
        case .invalidIssuer:
            "The configured enrollment issuer is not a canonical HTTPS origin."
        case .invalidAudience:
            "The configured enrollment audience is invalid."
        case .invalidClockSkew:
            "The configured enrollment clock skew is invalid."
        case .missingPublicKeys:
            "No Ed25519 enrollment trust anchor is configured."
        case .invalidKeyID:
            "An enrollment trust-anchor key id is invalid."
        case .invalidPublicKey:
            "An enrollment trust anchor is not a 32-byte Ed25519 public key."
        case .invalidRedemptionOrigins:
            "The native enrollment redemption origin allowlist is invalid."
        }
    }
}

/// Code-signed bootstrap configuration. Missing or partially invalid configuration returns nil so
/// the importer fails closed before it can inspect a credential or start a network request.
public enum EnrollmentTrustBootstrap {
    public static let issuerInfoKey = "JazzEnrollmentIssuer"
    public static let audienceInfoKey = "JazzEnrollmentAudience"
    public static let publicKeysInfoKey = "JazzEnrollmentEd25519PublicKeys"
    public static let redemptionOriginsInfoKey = "JazzEnrollmentRedemptionOrigins"

    public static func load(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> EnrollmentTrustPolicy? {
        guard
            let infoDictionary,
            let issuer = infoDictionary[issuerInfoKey] as? String,
            let audience = infoDictionary[audienceInfoKey] as? String,
            let publicKeys = infoDictionary[publicKeysInfoKey] as? [String: String]
        else {
            return nil
        }
        return try? EnrollmentTrustPolicy(
            issuer: issuer,
            audience: audience,
            publicKeysByKeyID: publicKeys)
    }

    public static func loadRedemptionRoutePolicy(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> EnrollmentRedemptionRoutePolicy? {
        guard
            let origins = infoDictionary?[redemptionOriginsInfoKey] as? [String]
        else {
            return nil
        }
        return try? EnrollmentRedemptionRoutePolicy(trustedOrigins: origins)
    }
}

/// Code-signed native-gateway allowlist, intentionally separate from the signed-bundle issuer.
///
/// A deployment may route native traffic through a different gateway or a path prefix. Only its
/// HTTPS origin is pinned here; the copied `redemptionURL` still supplies that deployment path.
public struct EnrollmentRedemptionRoutePolicy: Equatable, Sendable {
    public let trustedOrigins: Set<String>

    public init(trustedOrigins: [String]) throws {
        guard !trustedOrigins.isEmpty, Set(trustedOrigins).count == trustedOrigins.count else {
            throw EnrollmentTrustPolicyError.invalidRedemptionOrigins
        }
        var normalized = Set<String>()
        for origin in trustedOrigins {
            guard
                origin == origin.trimmingCharacters(in: .whitespacesAndNewlines),
                let components = URLComponents(string: origin),
                components.scheme?.lowercased() == "https",
                let host = components.host?.lowercased(),
                !host.isEmpty,
                components.user == nil,
                components.password == nil,
                components.query == nil,
                components.fragment == nil,
                components.path.isEmpty || components.path == "/",
                components.port.map({ (1...65_535).contains($0) }) ?? true
            else {
                throw EnrollmentTrustPolicyError.invalidRedemptionOrigins
            }
            var canonical = "https://\(host)"
            if let port = components.port {
                canonical += ":\(port)"
            }
            guard canonical == origin else {
                throw EnrollmentTrustPolicyError.invalidRedemptionOrigins
            }
            normalized.insert(canonical)
        }
        self.trustedOrigins = normalized
    }

    public func allows(_ endpoint: URL) -> Bool {
        guard
            let components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https",
            let host = components.host?.lowercased()
        else {
            return false
        }
        var origin = "https://\(host)"
        if let port = components.port {
            origin += ":\(port)"
        }
        return trustedOrigins.contains(origin)
    }
}

enum EnrollmentURLPolicy {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static func isSecureOrigin(_ value: String) -> Bool {
        guard
            value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.contains("\\"),
            !value.contains("?"),
            !value.contains("#"),
            value.unicodeScalars.allSatisfy({
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
                    && $0.value != 0x7f
            }),
            let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased(),
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.port.map({ (1...65_535).contains($0) }) ?? true,
            components.path.isEmpty || components.path == "/"
        else {
            return false
        }
        return scheme == "https" || (scheme == "http" && loopbackHosts.contains(host))
    }

    static func isSecureEndpoint(_ value: String) -> Bool {
        StreamEndpoint.isSecureSignedEndpoint(value)
    }
}
