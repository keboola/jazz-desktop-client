import Foundation
import XCTest

@testable import JazzCaptureCore

/// Guards for the assumptions of the `formal/token-renewal` TLA+ model (see its README).
///
/// The model's findings (D1: an older enrollment's renewal overwrites a newer re-enrollment; D2: a
/// renewal answer that arrives around a disconnect writes the credential back) are fixed: the
/// renewer commits through `JazzSignedDeviceCredentialVault.commitRenewal`, a compare-and-set
/// against the snapshot the attempt read, which also refuses once the renewer was stopped. The
/// `testD1_*`/`testD2_*` guards replay the model traces against that commit at vault level (the
/// executable's Keychain vault is the same type over a Keychain slot).
///
/// The first two tests check the facts the model's unguarded `Resume` step is built on: a renewal
/// is derived from the snapshot, and a plain `replace` is still last-writer-wins, which is why the
/// renewer must never use it for a renewal.
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

    /// Model assumption A2 (the unguarded `Resume`): a plain `vault.replace` has no generation or
    /// compare-and-swap check, so replaying the D1 trace through it leaves the OLDER enrollment in
    /// the slot. This is why the renewer commits through `commitRenewal` instead (see the D1 guard).
    func testVaultReplaceIsLastWriterWinsAcrossGenerations() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        let first = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        try vault.replace(with: first)

        // StartAttempt: DeviceTokenRenewer.renew reads the envelope.
        let snapshot = try XCTUnwrap(try vault.envelope())
        // ReEnroll: a newer signed bundle is imported while the request is in flight.
        let second = try envelope(generation: 2, bundleSuffix: "2", tokenId: "900")
        try vault.replace(with: second)
        // Resume through the unguarded replace (the pre-fix DeviceTokenRenewer.commit).
        try vault.replace(with: try snapshot.renewed(with: try grant(for: snapshot)))

        let stored = try XCTUnwrap(try vault.envelope())
        XCTAssertEqual(stored.routeBinding.signedAuthority?.generation, 1)
        XCTAssertEqual(stored.enrollmentRouting.tokenId, "457")
    }

    // MARK: - Fixed findings (guards)

    /// D1 trace `StartAttempt, Respond, ReEnroll, Resume`: the renewal of the older enrollment is
    /// dropped and the newly imported enrollment stays in the slot.
    func testD1_RenewalDoesNotOverwriteANewerEnrollment() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "456"))

        let snapshot = try XCTUnwrap(try vault.envelope())
        let second = try envelope(generation: 2, bundleSuffix: "2", tokenId: "900")
        try vault.replace(with: second)
        let decision = try vault.commitRenewal(
            try snapshot.renewed(with: try grant(for: snapshot)),
            replacing: snapshot,
            renewerStopped: false)

        XCTAssertEqual(decision, .discardSuperseded)
        let stored = try XCTUnwrap(try vault.envelope())
        XCTAssertEqual(stored.routeBinding.signedAuthority?.generation, 2)
        XCTAssertEqual(stored.enrollmentRouting.tokenId, "900")
        XCTAssertTrue(stored.isSameCredential(as: second))
    }

    /// D1 variant: a same-enrollment credential that changed (another renewal committed) is also a
    /// different credential, so a stale answer cannot roll the token back.
    func testD1_RenewalDoesNotOverwriteAnotherRenewalOfTheSameEnrollment() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "456"))
        let snapshot = try XCTUnwrap(try vault.envelope())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "458"))

        let decision = try vault.commitRenewal(
            try snapshot.renewed(with: try grant(for: snapshot)),
            replacing: snapshot,
            renewerStopped: false)

        XCTAssertEqual(decision, .discardSuperseded)
        XCTAssertEqual(try vault.envelope()?.enrollmentRouting.tokenId, "458")
    }

    /// D2 trace `StartAttempt, Respond, Disconnect, Resume`: the disconnect deleted the slot and
    /// stopped the renewer; the queued answer writes nothing back.
    func testD2_RenewalAfterDisconnectWritesNothingBack() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "456"))
        let snapshot = try XCTUnwrap(try vault.envelope())
        let renewed = try snapshot.renewed(with: try grant(for: snapshot))
        try vault.replace(with: nil)

        XCTAssertEqual(
            try vault.commitRenewal(renewed, replacing: snapshot, renewerStopped: true),
            .discardStopped)
        XCTAssertNil(try vault.envelope())
        // Even if the stop signal were lost, the empty slot alone refuses the write.
        XCTAssertEqual(
            try vault.commitRenewal(renewed, replacing: snapshot, renewerStopped: false),
            .discardRevoked)
        XCTAssertNil(try vault.envelope())
    }

    /// D2: an answer delivered while `stop()` ran is dropped even when the slot is untouched.
    func testD2_RenewalAfterStopWritesNothing() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        let first = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        try vault.replace(with: first)
        let snapshot = try XCTUnwrap(try vault.envelope())

        let decision = try vault.commitRenewal(
            try snapshot.renewed(with: try grant(for: snapshot)),
            replacing: snapshot,
            renewerStopped: true)

        XCTAssertEqual(decision, .discardStopped)
        XCTAssertEqual(try vault.envelope()?.enrollmentRouting.tokenId, "456")
    }

    /// The happy path still commits: an untouched slot of a running renewer is replaced.
    func testRenewalCommitsOverAnUntouchedSlot() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "456"))
        let snapshot = try XCTUnwrap(try vault.envelope())
        let renewed = try snapshot.renewed(with: try grant(for: snapshot))

        XCTAssertEqual(
            try vault.commitRenewal(renewed, replacing: snapshot, renewerStopped: false),
            .commit)
        let stored = try XCTUnwrap(try vault.envelope())
        XCTAssertTrue(stored.isSameCredential(as: renewed))
        XCTAssertEqual(stored.enrollmentRouting.tokenId, "457")
    }

    /// The failure path's staleness check (no write): a failure of an attempt whose credential was
    /// replaced by a re-enrollment, or whose renewer was stopped, is stale; an untouched slot's
    /// failure still applies. The slot is never modified by the check.
    func testRenewalDecisionMarksAFailureOfASupersededAttemptStale() throws {
        let vault = JazzSignedDeviceCredentialVault(persistence: MemorySlot())
        try vault.replace(with: try envelope(generation: 1, bundleSuffix: "1", tokenId: "456"))
        let snapshot = try XCTUnwrap(try vault.envelope())

        XCTAssertEqual(
            try vault.renewalDecision(for: snapshot, renewerStopped: false), .commit)
        XCTAssertEqual(
            try vault.renewalDecision(for: snapshot, renewerStopped: true), .discardStopped)

        let second = try envelope(generation: 2, bundleSuffix: "2", tokenId: "900")
        try vault.replace(with: second)
        XCTAssertEqual(
            try vault.renewalDecision(for: snapshot, renewerStopped: false), .discardSuperseded)
        XCTAssertTrue(try XCTUnwrap(try vault.envelope()).isSameCredential(as: second))

        try vault.replace(with: nil)
        XCTAssertEqual(
            try vault.renewalDecision(for: snapshot, renewerStopped: false), .discardRevoked)
        XCTAssertNil(try vault.envelope())
    }

    func testCommitDecisionIsAPureCompareAndSet() throws {
        let snapshot = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        let sameBytes = try envelope(generation: 1, bundleSuffix: "1", tokenId: "456")
        let newer = try envelope(generation: 2, bundleSuffix: "2", tokenId: "900")

        XCTAssertEqual(
            JazzDeviceTokenRenewalCommitDecision.decide(
                snapshot: snapshot, current: sameBytes, renewerStopped: false),
            .commit)
        XCTAssertEqual(
            JazzDeviceTokenRenewalCommitDecision.decide(
                snapshot: snapshot, current: newer, renewerStopped: false),
            .discardSuperseded)
        XCTAssertEqual(
            JazzDeviceTokenRenewalCommitDecision.decide(
                snapshot: snapshot, current: nil, renewerStopped: false),
            .discardRevoked)
        XCTAssertEqual(
            JazzDeviceTokenRenewalCommitDecision.decide(
                snapshot: snapshot, current: sameBytes, renewerStopped: true),
            .discardStopped)
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
