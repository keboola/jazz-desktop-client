import Foundation
import XCTest

@testable import JazzCaptureCore

final class SignedDeviceCredentialEnvelopeTests: XCTestCase {
    private enum InjectedFailure: Error {
        case beforeCommit
        case afterCommit
    }

    private final class AtomicPersistence: JazzSignedDeviceCredentialPersisting,
        @unchecked Sendable
    {
        enum FailureMode {
            case none
            case beforeCommit
            case afterCommit
        }

        private let lock = NSLock()
        private var bytes: Data?
        private var failureMode: FailureMode = .none

        init(bytes: Data? = nil) {
            self.bytes = bytes
        }

        func setFailureMode(_ value: FailureMode) {
            lock.withLock { failureMode = value }
        }

        func read() throws -> Data? {
            lock.withLock { bytes }
        }

        func replaceAtomically(with data: Data?) throws {
            try lock.withLock {
                switch failureMode {
                case .none:
                    bytes = data
                case .beforeCommit:
                    failureMode = .none
                    throw InjectedFailure.beforeCommit
                case .afterCommit:
                    bytes = data
                    failureMode = .none
                    throw InjectedFailure.afterCommit
                }
            }
        }
    }

    private final class LegacyReadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let storedValue: String?
        private var readCount = 0

        init(_ value: String?) {
            storedValue = value
        }

        func value() -> String? {
            lock.withLock {
                readCount += 1
                return storedValue
            }
        }

        func count() -> Int {
            lock.withLock { readCount }
        }
    }

    private struct Tuple {
        let envelope: JazzSignedDeviceCredentialEnvelope
        let route: JazzArchiveUploadRouteBinding
        let token: String
        let stackURL: String
        let streamEndpoint: String?
    }

    private struct TransitionState {
        var signedTokenAndStack: (token: String, stack: String)?
        var signedStream: String?
        var rawToken: String?
        var rawStream: String?
        var settingsStack: String

        var resolvedTokenAndStack: (token: String, stack: String)? {
            signedTokenAndStack
                ?? rawToken.map { (token: $0, stack: settingsStack) }
        }

        var resolvedStream: String? {
            signedTokenAndStack == nil ? rawStream : signedStream
        }

        mutating func apply(
            _ operation: JazzLegacyCredentialTransitionOperation,
            newToken: String,
            newStack: String
        ) {
            switch operation {
            case .deleteRawToken:
                rawToken = nil
            case .deleteRawStream:
                rawStream = nil
            case .setVerifiedStack:
                settingsStack = newStack
            case .setRawToken:
                rawToken = newToken
            case .deleteSignedEnvelope:
                signedTokenAndStack = nil
                signedStream = nil
            }
        }
    }

    func testRotationFailureBeforeAtomicCommitLeavesEntireOldTuple() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let old = try tuple(generation: 1, marker: "old")
        let new = try tuple(generation: 2, marker: "new")
        try vault.replace(with: old.envelope)

        persistence.setFailureMode(.beforeCommit)
        XCTAssertThrowsError(try vault.replace(with: new.envelope)) {
            XCTAssertEqual($0 as? InjectedFailure, .beforeCommit)
        }

        try assertResolvedTuple(
            vault: vault,
            expected: old,
            pinnedArchiveRoute: old.route)
    }

    func testRotationFailureAfterAtomicCommitExposesEntireNewTuple() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let old = try tuple(generation: 1, marker: "old")
        let new = try tuple(generation: 2, marker: "new")
        try vault.replace(with: old.envelope)

        persistence.setFailureMode(.afterCommit)
        XCTAssertThrowsError(try vault.replace(with: new.envelope)) {
            XCTAssertEqual($0 as? InjectedFailure, .afterCommit)
        }

        try assertResolvedTuple(
            vault: vault,
            expected: new,
            pinnedArchiveRoute: new.route)
    }

    func testFirstSignedImportCommitEdgeIsLegacyOldOrSignedNewNeverMixed() throws {
        let signed = try tuple(generation: 1, marker: "signed")
        let legacyStack = "https://connection.legacy.keboola.com"
        let legacyToken = "legacy-token"
        let legacyStream = "https://stream.example.test/otlp/legacy/source/secret"

        let beforePersistence = AtomicPersistence()
        let beforeVault = JazzSignedDeviceCredentialVault(persistence: beforePersistence)
        beforePersistence.setFailureMode(.beforeCommit)
        XCTAssertThrowsError(try beforeVault.replace(with: signed.envelope))
        let oldRequest = try beforeVault.keboolaCredential(
            requestedStackURL: legacyStack,
            legacyToken: legacyToken,
            now: referenceDate())
            .request(path: "/v2/storage/files", method: "GET", timeout: 10)
        XCTAssertEqual(oldRequest.url?.absoluteString, legacyStack + "/v2/storage/files")
        XCTAssertEqual(oldRequest.value(forHTTPHeaderField: "X-StorageApi-Token"), legacyToken)
        XCTAssertEqual(
            try beforeVault.streamEndpoint(legacyEndpoint: legacyStream),
            legacyStream)

        let afterPersistence = AtomicPersistence()
        let afterVault = JazzSignedDeviceCredentialVault(persistence: afterPersistence)
        afterPersistence.setFailureMode(.afterCommit)
        XCTAssertThrowsError(try afterVault.replace(with: signed.envelope))
        try assertResolvedTuple(
            vault: afterVault,
            expected: signed,
            pinnedArchiveRoute: signed.route,
            requestedStack: legacyStack,
            legacyToken: legacyToken,
            legacyStream: legacyStream)
    }

    func testSameAuthorityRotationCanAuthorizePinnedArchiveWithNewToken() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let old = try tuple(generation: 1, marker: "old")
        let rotated = try tuple(generation: 2, marker: "rotated")
        XCTAssertTrue(old.route.hasSameDeliveryAuthority(as: rotated.route))
        XCTAssertNotEqual(old.route.tokenId, rotated.route.tokenId)

        try vault.replace(with: rotated.envelope)
        let credential = try vault.archiveCredential(
            for: old.route,
            now: referenceDate())
        XCTAssertEqual(credential.withValue { $0 }, rotated.token)
    }

    func testSignedEnvelopeIgnoresCallerStackAndLegacyToken() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let signed = try tuple(generation: 1, marker: "signed")
        try vault.replace(with: signed.envelope)
        let legacyProbe = LegacyReadProbe("legacy-token-must-not-be-read")

        let credential = try vault.keboolaCredential(
            requestedStackURL: "https://connection.wrong.keboola.com",
            legacyToken: legacyProbe.value(),
            now: referenceDate())
        let request = try credential.request(
            path: "/v2/storage/files/prepare",
            method: "POST",
            timeout: 10)

        XCTAssertEqual(
            request.url?.absoluteString,
            signed.stackURL + "/v2/storage/files/prepare")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            signed.token)
        XCTAssertEqual(legacyProbe.count(), 0)
    }

    func testCorruptSignedSlotBlocksAllLegacyFallback() throws {
        let persistence = AtomicPersistence(bytes: Data("{not-json".utf8))
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let tokenProbe = LegacyReadProbe("legacy-token")
        let streamProbe = LegacyReadProbe(
            "https://stream.example.test/otlp/legacy/source/secret")

        XCTAssertThrowsError(
            try vault.keboolaCredential(
                requestedStackURL: "https://connection.legacy.keboola.com",
                legacyToken: tokenProbe.value(),
                now: referenceDate())
        ) {
            XCTAssertEqual(
                $0 as? JazzArchiveUploadError,
                .credentialBindingMismatch)
        }
        XCTAssertThrowsError(
            try vault.streamEndpoint(legacyEndpoint: streamProbe.value())
        ) {
            XCTAssertEqual(
                $0 as? JazzArchiveUploadError,
                .credentialBindingMismatch)
        }
        XCTAssertEqual(tokenProbe.count(), 0)
        XCTAssertEqual(streamProbe.count(), 0)
    }

    func testPresentNonUTF8SignedSlotCannotBecomeLegacyAbsence() throws {
        let persistence = AtomicPersistence(bytes: Data([0xff, 0xfe, 0x80]))
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let tokenProbe = LegacyReadProbe("legacy-token")
        let streamProbe = LegacyReadProbe(
            "https://stream.example.test/otlp/legacy/source/secret")

        XCTAssertThrowsError(
            try vault.keboolaCredential(
                requestedStackURL: "https://connection.legacy.keboola.com",
                legacyToken: tokenProbe.value(),
                now: referenceDate())
        ) {
            XCTAssertEqual(
                $0 as? JazzArchiveUploadError,
                .credentialBindingMismatch)
        }
        XCTAssertThrowsError(
            try vault.streamEndpoint(legacyEndpoint: streamProbe.value()))
        XCTAssertEqual(tokenProbe.count(), 0)
        XCTAssertEqual(streamProbe.count(), 0)
    }

    func testSignedToLegacyPlanNeverPairsTokenWithWrongStackAtAnyFaultPoint() {
        let oldToken = "old-signed-token"
        let oldStack = "https://connection.old.keboola.com"
        let oldStream = "https://stream.example.test/otlp/old/source/secret"
        let newToken = "new-legacy-token"
        let newStack = "https://connection.new.keboola.com"
        var state = TransitionState(
            signedTokenAndStack: (oldToken, oldStack),
            signedStream: oldStream,
            rawToken: "old-projection-token",
            rawStream: "old-projection-stream",
            settingsStack: oldStack)
        let operations = JazzLegacyCredentialTransitionPlan.operations(
            signedEnvelopePresent: true)

        assertResolved(
            state,
            allowed: [(oldToken, oldStack)],
            allowedStreams: [oldStream])
        for operation in operations {
            state.apply(
                operation,
                newToken: newToken,
                newStack: newStack)
            let afterCommit = operation == .deleteSignedEnvelope
            assertResolved(
                state,
                allowed: afterCommit
                    ? [(newToken, newStack)]
                    : [(oldToken, oldStack)],
                allowedStreams: afterCommit ? [nil] : [oldStream])
        }
    }

    func testLegacyToLegacyPlanUsesCredentialFreeGapBeforeStackChange() {
        let oldToken = "old-legacy-token"
        let oldStack = "https://connection.old.keboola.com"
        let newToken = "new-legacy-token"
        let newStack = "https://connection.new.keboola.com"
        var state = TransitionState(
            signedTokenAndStack: nil,
            signedStream: nil,
            rawToken: oldToken,
            rawStream: "https://stream.example.test/otlp/old/source/secret",
            settingsStack: oldStack)
        let operations = JazzLegacyCredentialTransitionPlan.operations(
            signedEnvelopePresent: false)

        assertResolved(
            state,
            allowed: [(oldToken, oldStack)],
            allowedStreams: [state.rawStream])
        for operation in operations {
            state.apply(
                operation,
                newToken: newToken,
                newStack: newStack)
            let resolved = state.resolvedTokenAndStack
            if let resolved {
                XCTAssertTrue(
                    (resolved.token == oldToken && resolved.stack == oldStack)
                        || (resolved.token == newToken && resolved.stack == newStack))
            }
            if operation == .setVerifiedStack {
                XCTAssertNil(resolved, "stack may change only while no raw token is usable")
            }
        }
        XCTAssertEqual(state.resolvedTokenAndStack?.token, newToken)
        XCTAssertEqual(state.resolvedTokenAndStack?.stack, newStack)
        XCTAssertNil(state.resolvedStream)
    }

    func testExpiredStorageTokenFailsClosedButSignedStreamRemainsUsable() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let expired = try tuple(
            generation: 1,
            marker: "expired",
            expiresAt: "2026-07-23T00:00:00.000Z")
        try vault.replace(with: expired.envelope)
        let tokenProbe = LegacyReadProbe("legacy-token")
        let streamProbe = LegacyReadProbe(
            "https://stream.example.test/otlp/legacy/source/secret")

        XCTAssertThrowsError(
            try vault.keboolaCredential(
                requestedStackURL: "https://connection.legacy.keboola.com",
                legacyToken: tokenProbe.value(),
                now: referenceDate())
        ) {
            XCTAssertEqual($0 as? JazzArchiveUploadError, .credentialExpired)
        }
        XCTAssertThrowsError(
            try vault.archiveCredential(
                for: expired.route,
                now: referenceDate())
        ) {
            XCTAssertEqual($0 as? JazzArchiveUploadError, .credentialExpired)
        }
        XCTAssertEqual(
            try vault.streamEndpoint(legacyEndpoint: streamProbe.value()),
            expired.streamEndpoint)
        XCTAssertEqual(tokenProbe.count(), 0)
        XCTAssertEqual(streamProbe.count(), 0)
    }

    func testSignedExplicitNullStreamNeverInheritsLegacyEndpoint() throws {
        let persistence = AtomicPersistence()
        let vault = JazzSignedDeviceCredentialVault(persistence: persistence)
        let archiveOnly = try tuple(
            generation: 1,
            marker: "archive-only",
            streamEndpoint: nil)
        try vault.replace(with: archiveOnly.envelope)
        let legacyProbe = LegacyReadProbe(
            "https://stream.example.test/otlp/legacy/source/secret")

        XCTAssertNil(
            try vault.streamEndpoint(legacyEndpoint: legacyProbe.value()))
        XCTAssertEqual(legacyProbe.count(), 0)
    }

    func testMissingSignedEnvelopeStopsArchiveBeforeAnyNetworkOperation() throws {
        let vault = JazzSignedDeviceCredentialVault(
            persistence: AtomicPersistence())
        let pinned = try tuple(generation: 1, marker: "pinned").route
        var networkRequestCount = 0

        XCTAssertThrowsError(try {
            _ = try vault.archiveCredential(
                for: pinned,
                now: referenceDate())
            networkRequestCount += 1
        }()) {
            XCTAssertEqual(
                $0 as? JazzArchiveUploadError,
                .credentialUnavailable)
        }
        XCTAssertEqual(networkRequestCount, 0)
    }

    func testStreamSourceCannotExistWithoutEndpoint() throws {
        let value = try tuple(
            generation: 1,
            marker: "archive-only",
            streamEndpoint: nil)
        XCTAssertThrowsError(
            try JazzSignedDeviceCredentialEnvelope(
                token: value.token,
                expiresAt: "2099-07-24T00:00:00.000Z",
                routeBinding: value.route,
                enrollmentRouting: try routing(
                    generation: 1,
                    marker: "archive-only").0,
                streamSourceId: "source-without-endpoint",
                streamEndpoint: nil)
        ) {
            XCTAssertEqual(
                $0 as? JazzArchiveUploadError,
                .credentialBindingMismatch)
        }
    }

    func testVerifiedTokenWhitespaceIsPreservedRatherThanInventingWireValidation() throws {
        let value = try tuple(
            generation: 1,
            marker: "whitespace",
            token: " token accepted by live verify ")
        let request = try value.envelope.keboolaCredential(now: referenceDate())
            .request(path: "/v2/storage/files", method: "GET", timeout: 10)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            value.token)
    }

    private func assertResolvedTuple(
        vault: JazzSignedDeviceCredentialVault,
        expected: Tuple,
        pinnedArchiveRoute: JazzArchiveUploadRouteBinding,
        requestedStack: String = "https://connection.wrong.keboola.com",
        legacyToken: String = "legacy-token-must-not-win",
        legacyStream: String = "https://stream.example.test/otlp/legacy/source/secret"
    ) throws {
        let request = try vault.keboolaCredential(
            requestedStackURL: requestedStack,
            legacyToken: legacyToken,
            now: referenceDate())
            .request(path: "/v2/storage/files", method: "GET", timeout: 10)
        XCTAssertEqual(
            request.url?.absoluteString,
            expected.stackURL + "/v2/storage/files")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-StorageApi-Token"),
            expected.token)
        XCTAssertEqual(
            try vault.archiveCredential(
                for: pinnedArchiveRoute,
                now: referenceDate())
                .withValue { $0 },
            expected.token)
        XCTAssertEqual(
            try vault.streamEndpoint(legacyEndpoint: legacyStream),
            expected.streamEndpoint)
    }

    private func assertResolved(
        _ state: TransitionState,
        allowed: [(String, String)],
        allowedStreams: [String?],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if let resolved = state.resolvedTokenAndStack {
            XCTAssertTrue(
                allowed.contains {
                    $0.0 == resolved.token && $0.1 == resolved.stack
                },
                "resolved token/stack is a mixed authority",
                file: file,
                line: line)
        } else {
            XCTAssertTrue(
                allowed.isEmpty,
                "unexpected credential-free state",
                file: file,
                line: line)
        }
        XCTAssertTrue(
            allowedStreams.contains {
                $0 == state.resolvedStream
            },
            "resolved stream is outside the allowed authority states",
            file: file,
            line: line)
    }

    private func tuple(
        generation: Int,
        marker: String,
        token: String? = nil,
        expiresAt: String = "2099-07-24T00:00:00.000Z",
        streamEndpoint: String? = "https://stream.example.test/otlp/123/source/secret"
    ) throws -> Tuple {
        let (enrollmentRouting, route) = try routing(
            generation: generation,
            marker: marker,
            expiresAt: expiresAt)
        let token = token ?? "\(marker)-scoped-token"
        let envelope = try JazzSignedDeviceCredentialEnvelope(
            token: token,
            expiresAt: expiresAt,
            routeBinding: route,
            enrollmentRouting: enrollmentRouting,
            streamSourceId: streamEndpoint == nil ? nil : "source-\(marker)",
            streamEndpoint: streamEndpoint)
        return Tuple(
            envelope: envelope,
            route: route,
            token: token,
            stackURL: route.stackURL,
            streamEndpoint: streamEndpoint)
    }

    private func routing(
        generation: Int,
        marker: String,
        expiresAt: String = "2099-07-24T00:00:00.000Z"
    ) throws -> (
        JazzArchiveEnrollmentRouting,
        JazzArchiveUploadRouteBinding
    ) {
        let authority = try JazzArchiveSignedEnrollmentAuthority(
            issuer: "https://issuer.example",
            audience: "jazz-desktop",
            bundleId: String(
                format: "jdb_%032llx",
                UInt64(generation)),
            generation: generation,
            envelopeDigest: digest(marker))
        let enrollmentRouting = JazzArchiveEnrollmentRouting(
            projectId: "123",
            stackURL: "https://connection.signed.keboola.com",
            scope: try JazzArchiveUploadScope(
                companyId: "acme",
                areaId: "finance",
                deviceId: "mac-1"),
            archiveIngestURL: "https://jazz.example.test/api/archive-ingests",
            tokenId: "token-\(marker)",
            expiresAt: expiresAt,
            tokenBucketScope: JazzArchiveTokenBucketScope.none,
            signedAuthority: authority)
        return (
            enrollmentRouting,
            try enrollmentRouting.signedUploadRouteBinding()
        )
    }

    private func referenceDate() -> Date {
        Timestamps.parse("2026-07-24T12:00:00.000Z")!
    }

    private func digest(_ marker: String) -> String {
        let scalar = marker.utf8.reduce(0) { (Int($0) + Int($1)) % 16 }
        return String(repeating: String(format: "%x", scalar), count: 64)
    }
}
