import CryptoKit
import Foundation
import XCTest

@testable import JazzEnrollmentSecurity

final class DeviceBoundEnrollmentSecurityTests: XCTestCase {
    func testPythonGoldenClaimAndSealVerifyAndDecryptExactSignedBytes() throws {
        let fixture = try Harness.fixture()
        let claimBytes = try Harness.canonical(fixture.claimEnvelope.object)
        let verified = try DeviceBoundEnrollmentCrypto.verifyClaim(claimBytes)
        let wrappingPrivateKey = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.wrappingPrivateKey,
                maximumBytes: 32))
        let sealedBytes = try Harness.canonical(fixture.sealedBundle.object)
        let expectedSignedBytes = try Harness.decode(
            fixture.signedDeviceBundle,
            maximumBytes: 131_072)

        XCTAssertEqual(
            verified.binding.claimSHA256,
            fixture.expected.claimSha256)
        XCTAssertEqual(
            verified.binding.proofKeyThumbprint,
            fixture.expected.proofKeyThumbprint)
        XCTAssertEqual(
            verified.binding.wrappingKeyThumbprint,
            fixture.expected.wrappingKeyThumbprint)
        XCTAssertEqual(
            Harness.hexSHA256(sealedBytes),
            fixture.expected.sealedBundleSha256)
        XCTAssertEqual(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                sealedBytes,
                wrappingPrivateKey: wrappingPrivateKey,
                binding: verified.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z")),
            expectedSignedBytes)
        XCTAssertEqual(
            Harness.hexSHA256(expectedSignedBytes),
            fixture.expected.bundleSha256)
    }

    func testSwiftClaimUsesCanonicalLowSES256AndServerPayloadDigestIdentity() throws {
        let fixture = try Harness.fixture()
        let payload = fixture.claimPayload
        let proofPrivateKey = try P256.Signing.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.proofPrivateKey,
                maximumBytes: 32))

        let first = try DeviceBoundEnrollmentCrypto.makeClaim(
            payload: payload,
            proofPrivateKey: proofPrivateKey)
        let second = try DeviceBoundEnrollmentCrypto.makeClaim(
            payload: payload,
            proofPrivateKey: proofPrivateKey)
        let firstVerified = try DeviceBoundEnrollmentCrypto.verifyClaim(first)
        let secondVerified = try DeviceBoundEnrollmentCrypto.verifyClaim(second)
        let firstEnvelope = try Harness.object(first)
        let proof = try Harness.decode(
            try XCTUnwrap(firstEnvelope["proof"] as? String),
            maximumBytes: 64)

        XCTAssertEqual(proof.count, 64)
        XCTAssertLessThanOrEqual(
            Harness.compare(
                proof.subdata(in: 32..<64),
                Harness.p256HalfOrder),
            0)
        XCTAssertEqual(firstVerified.binding, secondVerified.binding)
        XCTAssertEqual(
            firstVerified.binding.claimSHA256,
            fixture.expected.claimSha256)
        // CryptoKit is permitted to randomize ECDSA. Idempotence is deliberately the canonical
        // payload digest and exact keys, never signature bytes.
        XCTAssertEqual(firstVerified.canonicalPayload, secondVerified.canonicalPayload)
    }

    func testClaimRejectsDuplicateUnknownNoncanonicalAndOversizedJSON() throws {
        let fixture = try Harness.fixture()
        let payload = fixture.claimEnvelope.payload
        let proof = fixture.claimEnvelope.proof
        let duplicate = Data(
            """
            {"payload":"\(payload)","payload":"\(payload)","proof":"\(proof)"}
            """.utf8)
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(duplicate)
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .malformedClaim)
        }

        var unknown = fixture.claimEnvelope.object
        unknown["alg"] = "ES256"
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(
                try Harness.canonical(unknown))
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .malformedClaim)
        }

        let pretty = try JSONSerialization.data(
            withJSONObject: fixture.claimEnvelope.object,
            options: [.prettyPrinted, .sortedKeys])
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(pretty)
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .malformedClaim)
        }

        let oversized = Data("{".utf8)
            + Data(repeating: 0x20, count: 20_001)
            + Data("}".utf8)
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(oversized)
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .malformedClaim)
        }
    }

    func testClaimRejectsCompressedHybridAndOffCurveP256Points() throws {
        let fixture = try Harness.fixture()
        let proofKey = try P256.Signing.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.proofPrivateKey,
                maximumBytes: 32))
        let points = [
            Data([0x02]) + Data(repeating: 0x01, count: 32),
            Data([0x06]) + Data(repeating: 0x01, count: 64),
            Data([0x04]) + Data(repeating: 0x00, count: 64),
        ]

        for point in points {
            var payload = try Harness.object(
                try Harness.canonicalPayload(fixture.claimPayload))
            var wrapping = try XCTUnwrap(
                payload["wrappingKey"] as? [String: Any])
            wrapping["publicKey"] = EnrollmentEncoding.encodeBase64URL(point)
            payload["wrappingKey"] = wrapping
            let envelope = try Harness.rawSignedClaim(
                payload: payload,
                proofKey: proofKey)

            XCTAssertThrowsError(
                try DeviceBoundEnrollmentCrypto.verifyClaim(envelope)
            ) { error in
                XCTAssertEqual(error as? DeviceBoundEnrollmentError, .invalidClaim)
            }
        }
    }

    func testClaimRejectsHighSMalleationAndProofTamper() throws {
        let fixture = try Harness.fixture()
        var envelope = fixture.claimEnvelope.object
        var proof = try Harness.decode(
            fixture.claimEnvelope.proof,
            maximumBytes: 64)
        let s = proof.subdata(in: 32..<64)
        let highS = Harness.subtract(Harness.p256Order, s)
        proof.replaceSubrange(32..<64, with: highS)
        envelope["proof"] = EnrollmentEncoding.encodeBase64URL(proof)

        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(
                try Harness.canonical(envelope))
        ) { error in
            XCTAssertEqual(
                error as? DeviceBoundEnrollmentError,
                .nonCanonicalSignature)
        }

        proof = try Harness.decode(
            fixture.claimEnvelope.proof,
            maximumBytes: 64)
        proof[0] ^= 1
        envelope["proof"] = EnrollmentEncoding.encodeBase64URL(proof)
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.verifyClaim(
                try Harness.canonical(envelope))
        ) { error in
            XCTAssertEqual(
                error as? DeviceBoundEnrollmentError,
                .invalidClaimProof)
        }
    }

    func testCopiedClaimCannotBeOpenedWithSecondMacWrappingKey() throws {
        let fixture = try Harness.fixture()
        let verified = try DeviceBoundEnrollmentCrypto.verifyClaim(
            try Harness.canonical(fixture.claimEnvelope.object))
        let secondMacKey = P256.KeyAgreement.PrivateKey()

        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                try Harness.canonical(fixture.sealedBundle.object),
                wrappingPrivateKey: secondMacKey,
                binding: verified.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .wrongRecipient)
            XCTAssertFalse(String(describing: error).contains("TEST-DEVICE-TOKEN"))
        }
    }

    func testSealedBundleRejectsCiphertextTagAndProtectedContextTamper() throws {
        let fixture = try Harness.fixture()
        let claim = try DeviceBoundEnrollmentCrypto.verifyClaim(
            try Harness.canonical(fixture.claimEnvelope.object))
        let key = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.wrappingPrivateKey,
                maximumBytes: 32))

        for field in ["ciphertext", "tag"] {
            var envelope = fixture.sealedBundle.object
            var value = try Harness.decode(
                try XCTUnwrap(envelope[field] as? String),
                maximumBytes: 131_072)
            value[0] ^= 1
            envelope[field] = EnrollmentEncoding.encodeBase64URL(value)
            XCTAssertThrowsError(
                try DeviceBoundEnrollmentCrypto.openSealedBundle(
                    try Harness.canonical(envelope),
                    wrappingPrivateKey: key,
                    binding: claim.binding,
                    descriptor: Harness.descriptor,
                    now: try Harness.date("2026-07-24T09:31:00Z"))
            ) { error in
                XCTAssertEqual(
                    error as? DeviceBoundEnrollmentError,
                    .authenticationFailed)
                XCTAssertFalse(
                    String(describing: error).contains("TEST-DEVICE-TOKEN"))
            }
        }

        var envelope = fixture.sealedBundle.object
        var protected = try Harness.object(
            try Harness.decode(
                try XCTUnwrap(envelope["protected"] as? String),
                maximumBytes: 12_288))
        var context = try XCTUnwrap(protected["context"] as? [String: Any])
        context["deviceId"] = "second-mac"
        protected["context"] = context
        envelope["protected"] = EnrollmentEncoding.encodeBase64URL(
            try Harness.canonical(protected))
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                try Harness.canonical(envelope),
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .contextMismatch)
        }
    }

    func testSealedBundleRejectsWrongExpectedContextDuplicateUnknownAndBounds() throws {
        let fixture = try Harness.fixture()
        let claim = try DeviceBoundEnrollmentCrypto.verifyClaim(
            try Harness.canonical(fixture.claimEnvelope.object))
        let key = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.wrappingPrivateKey,
                maximumBytes: 32))
        let wrongDescriptor = DeviceBundleSealDescriptor(
            bundleId: "jdb_99999999999999999999999999999999",
            generation: 7,
            sealedAt: "2026-07-24T09:31:00Z",
            revealExpiresAt: "2026-07-24T09:41:00Z")
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                try Harness.canonical(fixture.sealedBundle.object),
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: wrongDescriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .contextMismatch)
        }

        let wire = try String(
            data: Harness.canonical(fixture.sealedBundle.object),
            encoding: .utf8).unwrap()
        let duplicate = Data(
            wire.replacingOccurrences(
                of: #""tag":"#,
                with: #""tag":"AAAAAAAAAAAAAAAAAAAAAA","tag":"#,
                options: [.literal],
                range: try wire.range(of: #""tag":"#).unwrap()).utf8)
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                duplicate,
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceBoundEnrollmentError,
                .malformedSealedBundle)
        }

        var unknown = fixture.sealedBundle.object
        unknown["jwk"] = ["kty": "EC"]
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                try Harness.canonical(unknown),
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceBoundEnrollmentError,
                .malformedSealedBundle)
        }

        let oversized = Data("{".utf8)
            + Data(repeating: 0x20, count: 200_001)
            + Data("}".utf8)
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                oversized,
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:31:00Z"))
        ) { error in
            XCTAssertEqual(
                error as? DeviceBoundEnrollmentError,
                .malformedSealedBundle)
        }
    }

    func testExpiredSealFailsClosedAndFixtureNeverPersistsBootstrapBearer() throws {
        let fixture = try Harness.fixture()
        let rawFixture = try Data(contentsOf: Harness.fixtureURL)
        let claim = try DeviceBoundEnrollmentCrypto.verifyClaim(
            try Harness.canonical(fixture.claimEnvelope.object))
        let key = try P256.KeyAgreement.PrivateKey(
            rawRepresentation: try Harness.decode(
                fixture.testOnly.wrappingPrivateKey,
                maximumBytes: 32))

        XCTAssertFalse(
            String(data: rawFixture, encoding: .utf8)!.contains(
                "TEST-ONLY-BOOTSTRAP-BEARER"))
        XCTAssertThrowsError(
            try DeviceBoundEnrollmentCrypto.openSealedBundle(
                try Harness.canonical(fixture.sealedBundle.object),
                wrappingPrivateKey: key,
                binding: claim.binding,
                descriptor: Harness.descriptor,
                now: try Harness.date("2026-07-24T09:42:00Z"))
        ) { error in
            XCTAssertEqual(error as? DeviceBoundEnrollmentError, .expired)
            XCTAssertFalse(String(describing: error).contains("stream.example.test"))
        }
    }
}

private enum Harness {
    static let p256Order = Data(hex:
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")
    static let p256HalfOrder = Data(hex:
        "7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8")
    static let descriptor = DeviceBundleSealDescriptor(
        bundleId: "jdb_018ff3a2679a7bd18a5e6c3d4b2a1908",
        generation: 7,
        sealedAt: "2026-07-24T09:31:00Z",
        revealExpiresAt: "2026-07-24T09:41:00Z")

    static let fixtureURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "contract/enrollment/device-bound/fixtures/"
                    + "01-p256-device-bound-redemption.json")
    }()

    static func fixture() throws -> DeviceBoundFixture {
        try JSONDecoder().decode(
            DeviceBoundFixture.self,
            from: Data(contentsOf: fixtureURL))
    }

    static func canonicalPayload(
        _ payload: DeviceEnrollmentClaimPayload
    ) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        return try canonical(try object(data))
    }

    static func canonical(_ object: [String: Any]) throws -> Data {
        try EnrollmentEncoding.canonicalJSONObject(object).unwrap()
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try (JSONSerialization.jsonObject(with: data) as? [String: Any]).unwrap()
    }

    static func decode(_ value: String, maximumBytes: Int) throws -> Data {
        try EnrollmentEncoding.decodeBase64URL(
            value,
            maximumBytes: maximumBytes).unwrap()
    }

    static func rawSignedClaim(
        payload: [String: Any],
        proofKey: P256.Signing.PrivateKey
    ) throws -> Data {
        let payloadData = try canonical(payload)
        let signature = try proofKey.signature(
            for: DeviceBoundEnrollmentCrypto.claimProofDomain + payloadData)
        let lowS = normalizeLowS(signature.rawRepresentation)
        return try canonical([
            "payload": EnrollmentEncoding.encodeBase64URL(payloadData),
            "proof": EnrollmentEncoding.encodeBase64URL(lowS),
        ])
    }

    static func normalizeLowS(_ signature: Data) -> Data {
        let r = signature.subdata(in: 0..<32)
        var s = signature.subdata(in: 32..<64)
        if compare(s, p256HalfOrder) > 0 {
            s = subtract(p256Order, s)
        }
        return r + s
    }

    static func subtract(_ lhs: Data, _ rhs: Data) -> Data {
        var result = [UInt8](repeating: 0, count: lhs.count)
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        var borrow = 0
        for index in stride(from: lhs.count - 1, through: 0, by: -1) {
            var value = Int(left[index]) - Int(right[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return Data(result)
    }

    static func compare(_ lhs: Data, _ rhs: Data) -> Int {
        for (left, right) in zip(lhs, rhs) {
            if left < right { return -1 }
            if left > right { return 1 }
        }
        return 0
    }

    static func date(_ value: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return try formatter.date(from: value).unwrap()
    }

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct DeviceBoundFixture: Codable {
    struct TestOnly: Codable {
        let proofPrivateKey: String
        let wrappingPrivateKey: String
        let ephemeralPrivateKey: String
        let salt: String
        let iv: String
    }

    struct Expected: Codable {
        let claimSha256: String
        let proofKeyThumbprint: String
        let wrappingKeyThumbprint: String
        let bundleSha256: String
        let sealedBundleSha256: String
    }

    let fixtureVersion: Int
    let name: String
    let testOnly: TestOnly
    let bootstrap: [String: String]
    let claimPayload: DeviceEnrollmentClaimPayload
    let claimEnvelope: JSONEnvelope
    let signedDeviceBundle: String
    let sealedBundle: JSONEnvelope
    let expected: Expected
}

private struct JSONEnvelope: Codable {
    let data: Data

    init(from decoder: Decoder) throws {
        let value = try [String: JSONValue](from: decoder)
        data = try JSONEncoder().encode(value)
    }

    func encode(to encoder: Encoder) throws {
        let value = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: data)
        try value.encode(to: encoder)
    }

    var object: [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    var payload: String {
        object["payload"] as! String
    }

    var proof: String {
        object["proof"] as! String
    }
}

private enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}

private extension Optional {
    func unwrap(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Wrapped {
        try XCTUnwrap(self, file: file, line: line)
    }
}
