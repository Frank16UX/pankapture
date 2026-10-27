import Foundation
import Security
import Synchronization

/// API keys in the login Keychain, one generic password per provider preset
/// (PRD AI-3). Keys never go to UserDefaults, project files, or logs.
///
/// Reading a key can make macOS ask for the login password: the item is tied
/// to the build that saved it (without a Team ID its partition is that
/// build's code hash), so a rebuilt or updated app is a stranger to it
/// (ADR-41). So:
/// - `hasKey(for:)` reads attributes only and never prompts; use it for UI.
/// - `key(for:)` reads the secret only when a request is about to be made,
///   and keeps it for the rest of the launch: at most one prompt per key.
/// - `setKey(_:for:)` replaces the item, so the current build owns it and
///   reading it back never prompts.
public enum APIKeyStore {
    static let service = "com.franklinperez.Pankapture.ai-provider"

    /// Keys read or saved during this launch.
    private static let cache = Mutex<[String: String]>([:])

    /// Whether a key is saved, without reading it (no Keychain prompt).
    public static func hasKey(for presetID: String) -> Bool {
        if cache.withLock({ $0[presetID] }) != nil { return true }
        var query = baseQuery(presetID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// The key, for a request about to be made. The first read in a launch may
    /// ask for the Keychain password (blocking the calling thread until the
    /// user answers), so call it off the main actor where possible.
    public static func key(for presetID: String) -> String? {
        if let cached = cache.withLock({ $0[presetID] }) { return cached }
        var query = baseQuery(presetID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        cache.withLock { $0[presetID] = key }
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
        // A new item rather than an update: updating one an earlier build
        // saved would prompt, and would leave it tied to that build.
        let deleted = SecItemDelete(baseQuery(presetID) as CFDictionary)
        if deleted == errSecSuccess || deleted == errSecItemNotFound {
            var item = baseQuery(presetID)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Pankapture AI provider key (\(presetID))"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                // The old item is already gone; don't keep serving it from the cache.
                cache.withLock { $0[presetID] = nil }
                throw KeychainError(status: added)
            }
        } else {
            let updated = SecItemUpdate(baseQuery(presetID) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainError(status: updated) }
        }
        cache.withLock { $0[presetID] = trimmed }
    }

    public static func deleteKey(for presetID: String) {
        SecItemDelete(baseQuery(presetID) as CFDictionary)
        cache.withLock { $0[presetID] = nil }
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
