import Foundation
import XCTest

@testable import JazzCaptureCore

/// Guards for the assumptions of the `formal/token-renewal` TLA+ model (see its README).
///
/// The model's findings (D1: an older enrollment's renewal overwrites a newer re-enrollment; D2: a
/// renewal answer that arrives around a disconnect writes the credential back) live in
/// `DeviceTokenRenewer`, which sits in the `JazzCapture` executable target and always writes
/// through the hard-coded Keychain vault (`SignedDeviceCredentialKeychain.vault`). They cannot be
/// replayed here without a Keychain harness, so they stay "model trace only".
///
/// What CAN be checked in Core is the two facts the model's commit step (`Resume`) is built on.
/// These are ordinary tests, not bug assertions: if either changes (for example the vault gains a
/// compare-and-swap, which would be one way to fix D1/D2), update the model and its README.
final class FormalTokenRenewalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private final class MemorySlot: JazzSignedDeviceCredentialPersisting, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Data?

        func read() throws -> Data? {
            lock.withLock { bytes }
        }

        func replaceAtomically(with data: Data?) throws {
            lock.withLock { bytes = data }
        }
    }

    /// Model assumption A1 (`Resume` writes `gen |-> snap.gen`): a renewal envelope is derived
    /// from the SNAPSHOT the attempt read, so it carries that enrollment's bundle and generation.
    func testRenewedEnvelopeKeepsTheSnapshotsEnrollmentGeneration() throws {
        let snapshot = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        let renewed = try snapshot.renewed(with: try grant(for: snapshot))

        XCTAssertEqual(renewed.enrollmentRouting.tokenId, "457")
        XCTAssertEqual(renewed.routeBinding.signedAuthority?.generation, 1)
        XCTAssertEqual(
            renewed.routeBinding.signedAuthority?.bundleId,
            snapshot.routeBinding.signedAuthority?.bundleId)
    }

    /// Model assumption A2 (`Resume` has no guard on the current slot): the vault replaces the
    /// whole tuple with no generation or compare-and-swap check. Replaying the renewer's commit
    /// sequence at vault level therefore leaves the OLDER enrollment in the slot -- the D1 trace
    /// `StartAttempt, Respond, ReEnroll, Resume`.
    func testVaultReplaceIsLastWriterWinsAcrossGenerations() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        let first = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        try vault.replace(with: first)

        // StartAttempt: DeviceTokenRenewer.renew reads the envelope (:150).
        let snapshot = try XCTUnwrap(try vault.envelope())
        // ReEnroll: a newer signed bundle is imported while the request is in flight.
        let second = try envelope(generation: 2, bundleSuffix: "2", tokenId: "900")
        try vault.replace(with: second)
        // Resume: DeviceTokenRenewer.commit (:290, :304) -- no re-read of the slot.
        try vault.replace(with: try snapshot.renewed(with: try grant(for: snapshot)))

        let stored = try XCTUnwrap(try vault.envelope())
        XCTAssertEqual(stored.routeBinding.signedAuthority?.generation, 1)
        XCTAssertEqual(stored.enrollmentRouting.tokenId, "457")
    }

    // MARK: - Fixtures (mirroring DeviceTokenRenewalTests)

    private func makeRouting(
        generation: Int,
        bundleSuffix: String,
        tokenId: String
    ) throws -> JazzArchiveEnrollmentRouting {
        JazzArchiveEnrollmentRouting(
            projectId: "123",
            stackURL: "https://connection.signed.keboola.com",
            scope: try JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "mac-1"),
            archiveIngestURL: "https://jazz.example/api/archive-ingests",
            tokenId: tokenId,
            expiresAt: "2026-02-02T02:40:00Z",
            tokenBucketScope: .sink,
            sinkBucketId: "in.c-otlp-src1",
            signedAuthority: try JazzArchiveSignedEnrollmentAuthority(
                issuer: "https://issuer.example",
                audience: "jazz-desktop",
                bundleId: "jdb_" + String(repeating: "0", count: 31) + bundleSuffix,
                generation: generation,
                envelopeDigest: String(repeating: "c", count: 64)),
            authorizationProfile: .signedJWS)
    }

    private func envelope(
        generation: Int,
        bundleSuffix: String,
        tokenId: String
    ) throws -> JazzSignedDeviceCredentialEnvelope {
        let routing = try makeRouting(
            generation: generation,
            bundleSuffix: bundleSuffix,
            tokenId: tokenId)
        return try JazzSignedDeviceCredentialEnvelope(
            token: "123-device-secret-\(tokenId)",
            expiresAt: routing.expiresAt,
            routeBinding: try routing.signedUploadRouteBinding(),
            enrollmentRouting: routing,
            streamSourceId: "src1",
            streamEndpoint: "https://stream.example.test/otlp/123/src1/secret")
    }

    private func grant(
        for snapshot: JazzSignedDeviceCredentialEnvelope
    ) throws -> JazzDeviceTokenRenewalGrant {
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "kind": "jazz-device-token-renewal",
            "deviceId": "mac-1",
            "tokenId": "457",
            "token": "123-renewed-device-secret",
            "expiresAt": "2026-02-02T03:40:00Z",
            "tokenBucketScope": "sink",
            "sinkBucketId": "in.c-otlp-src1",
            "componentAccess": [],
            "renewAfterSeconds": 2_880,
            "serverTime": "2026-02-02T02:40:00Z",
        ]
        return try JazzDeviceTokenRenewalGrant(
            responseData: try JSONSerialization.data(withJSONObject: payload),
            request: try JazzDeviceTokenRenewalRequest(routeBinding: snapshot.routeBinding),
            currentRouting: snapshot.enrollmentRouting,
            now: now)
    }
}
