import Foundation
import JasnostCaptureCore

/// One Keychain generic-password item is the commit boundary for the signed token and every piece
/// of authority metadata needed to route it. `SecItemUpdate`/`SecItemAdd` replace that one value
/// atomically; no archive or Keboola request reconstructs the tuple from UserDefaults.
struct KeychainSignedDeviceCredentialPersistence:
    JazzSignedDeviceCredentialPersisting, Sendable
{
    func read() throws -> Data? {
        try Keychain.getData(
            account: Keychain.Account.signedDeviceCredentialEnvelope)
    }

    func replaceAtomically(with data: Data?) throws {
        guard let data else {
            try Keychain.delete(account: Keychain.Account.signedDeviceCredentialEnvelope)
            return
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw JazzArchiveUploadError.credentialBindingMismatch
        }
        try Keychain.set(
            value,
            account: Keychain.Account.signedDeviceCredentialEnvelope)
    }
}

enum SignedDeviceCredentialKeychain {
    static var vault: JazzSignedDeviceCredentialVault {
        JazzSignedDeviceCredentialVault(
            persistence: KeychainSignedDeviceCredentialPersistence())
    }

    /// Re-derive the single-value Keychain projections of a signed tuple. They are conveniences for
    /// the legacy read paths, never authority: the atomic envelope above is the commit point, and
    /// every one of these writes is repairable from it. Called after an enrollment import and after
    /// each unattended token renewal.
    static func repairProjections(_ envelope: JazzSignedDeviceCredentialEnvelope) {
        if let credential = try? envelope.keboolaCredential() {
            credential.withValue {
                try? Keychain.set($0, account: Keychain.Account.kbcToken)
            }
        }
        if let endpoint = try? envelope.signedStreamEndpoint() {
            try? Keychain.set(endpoint, account: Keychain.Account.streamEndpoint)
        } else {
            try? Keychain.delete(account: Keychain.Account.streamEndpoint)
        }
    }
}
