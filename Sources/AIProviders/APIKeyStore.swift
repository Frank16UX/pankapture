import Foundation
import Security

/// API keys in the login Keychain, one generic password per provider preset
/// (PRD AI-3). Keys never go to UserDefaults, project files, or logs.
public enum APIKeyStore {
    static let service = "com.franklinperez.Pankapture.ai-provider"

    public static func key(for presetID: String) -> String? {
        var query = baseQuery(presetID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Stores `key`, replacing any previous one. An empty key deletes it.
    public static func setKey(_ key: String, for presetID: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteKey(for: presetID)
            return
        }
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(baseQuery(presetID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery(presetID)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Pankapture AI provider key (\(presetID))"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func deleteKey(for presetID: String) {
        SecItemDelete(baseQuery(presetID) as CFDictionary)
    }

    private static func baseQuery(_ presetID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: presetID,
        ]
    }

    public struct KeychainError: LocalizedError {
        public let status: OSStatus

        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The key couldn't be saved in the Keychain: \(message)"
        }
    }
}
