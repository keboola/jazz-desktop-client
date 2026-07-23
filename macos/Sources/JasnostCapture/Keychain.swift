import Foundation
import Security

/// Minimal wrapper over the macOS Keychain for the one secret the app holds: the Keboola (KBC)
/// Storage API token. Secrets belong in the Keychain, never in UserDefaults (which is a plist any
/// process running as the user can read) and never on a process's argv (visible via `ps`).
///
/// Stored as a generic password keyed by ``service`` + ``account``. ``kSecAttrAccessibleAfterFirstUnlock``
/// lets the app read it after the user has unlocked the Mac once (so a headless relaunch works),
/// without syncing it to iCloud.
enum Keychain {
    /// Namespaced to the app's code identity (matches the TCC/bundle id used elsewhere).
    static let service = "dev.jasnost.capture"

    /// Account names for the secrets the app holds. The stream endpoint counts as a secret
    /// because the OTLP ingest URL embeds the source's token in its path.
    enum Account {
        static let kbcToken = "kbc-token"
        static let streamEndpoint = "stream-endpoint"
        /// Scoped bearer used only by the direct Jazz guided-execution HTTPS client.
        static let guidedExecutionToken = "guided-execution-token"
    }

    enum KeychainError: Error, CustomStringConvertible {
        case unexpectedStatus(OSStatus)

        var description: String {
            switch self {
            case let .unexpectedStatus(status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(msg)"
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Read the secret for ``account``, or ``nil`` if none is stored.
    static func get(account: String) throws -> String? {
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
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
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
}
