import Foundation
import JazzCaptureCore

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
}
