import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for the one secret the app holds: the Keboola (KBC)
/// Storage API token. Secrets belong in the Keychain, never in UserDefaults (which is a plist any
/// process running as the user can read) and never on a process's argv (visible via `ps`).
///
/// Stored as a generic password keyed by ``service`` + ``account``.
/// ``kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`` lets the app read it after the user has
/// unlocked the Mac once (so a headless relaunch works), while preventing a signed enrollment,
/// bootstrap bearer, or scoped credential from being restored onto another Mac.
enum Keychain {
    /// Namespaced to the app's code identity (matches the TCC/bundle id used elsewhere).
    static let service = "dev.jazz.capture"

    /// Account names for the secrets the app holds. The stream endpoint counts as a secret
    /// because the OTLP ingest URL embeds the source's token in its path.
    enum Account {
        static let kbcToken = "kbc-token"
        static let streamEndpoint = "stream-endpoint"
        /// Atomic signed-enrollment tuple used by archive and Keboola API requests. The JSON value
        /// contains the Storage token and therefore belongs only in this Keychain item.
        static let signedDeviceCredentialEnvelope = "signed-device-credential-envelope-v1"
        /// One restart-safe device-bound enrollment operation. It includes the short-lived
        /// bootstrap bearer and exact claim bytes, so the complete record stays in Keychain.
        static let pendingDeviceEnrollment = "pending-device-enrollment-v1"
        /// Scoped bearer used only by the direct Jazz guided-execution HTTPS client.
        static let guidedExecutionToken = "guided-execution-token"
    }

    /// Every credential held by this process is device-local authority. Keep this value visible to
    /// executable-target tests so a future Keychain refactor cannot silently make credentials
    /// migratable through an encrypted backup.
    static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)
        case invalidData

        var description: String {
            switch self {
            case let .unexpectedStatus(status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(msg)"
            case .invalidData:
                return "Keychain item contains invalid UTF-8 data"
            }
        }
    }

    /// Store (or replace) a secret for ``account``. An empty value deletes the item instead.
    static func set(_ value: String, account: String) throws {
        guard !value.isEmpty else {
            try delete(account: account)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try to update an existing item first; if none, add one.
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = accessibility
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Read the secret for ``account``, or ``nil`` if none is stored.
    static func get(account: String) throws -> String? {
        guard let data = try getData(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return value
    }

    /// Read exact Keychain bytes while preserving the distinction between an absent item and a
    /// present-but-malformed value. Signed credential JSON uses this path so non-UTF8 corruption
    /// can never look like permission to enter legacy fallback.
    static func getData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data else {
            throw KeychainError.invalidData
        }
        return data
    }

    /// Delete the secret for ``account`` (idempotent — missing is success).
    static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Whether a non-empty secret exists for ``account`` (without returning it).
    static func has(account: String) -> Bool {
        ((try? get(account: account)) ?? nil)?.isEmpty == false
    }

    /// Distinguish genuine absence from an unreadable/corrupt value. Callers with fail-closed
    /// fallback rules treat an error as present instead of silently reviving older authority.
    static func exists(account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        return true
    }
}
