import AppCore
import Foundation

/// The provider the user configured in Settings ▸ AI. Off by default (PRD
/// AI-1); the configuration has no secrets (keys are in `APIKeyStore`).
public enum ProviderSettings {
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PreferenceKey.aiProviderEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: PreferenceKey.aiProviderEnabled) }
    }

    /// The configured provider, enabled or not.
    public static var configuration: ProviderConfiguration? {
        get {
            guard let data = UserDefaults.standard.data(forKey: PreferenceKey.aiProviderConfiguration) else { return nil }
            return try? JSONDecoder().decode(ProviderConfiguration.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: PreferenceKey.aiProviderConfiguration)
            } else {
                UserDefaults.standard.removeObject(forKey: PreferenceKey.aiProviderConfiguration)
            }
        }
    }

    /// The provider auto-edit should use now: enabled, configured, and with a
    /// key when it needs one. `nil` means the rules decide alone.
    public static func active() -> (configuration: ProviderConfiguration, apiKey: String?)? {
        guard isEnabled, let configuration, !configuration.model.isEmpty else { return nil }
        let key = APIKeyStore.key(for: configuration.presetID)
        if configuration.preset?.needsKey == true, key == nil { return nil }
        return (configuration, key)
    }
}

public extension LanguageModelClient {
    /// Sends a tiny structured request to check the URL, key, and model
    /// (Settings ▸ AI ▸ Test Connection). Returns the round-trip time.
    func testConnection(configuration: ProviderConfiguration, apiKey: String?) async throws -> Double {
        let request = StructuredRequest(
            system: "Answer with JSON only.",
            user: "Reply with ok set to true.",
            schemaName: "connection_test",
            schema: [
                "type": "object",
                "properties": ["ok": ["type": "boolean"]],
                "required": ["ok"],
                "additionalProperties": false,
            ],
            maxOutputTokens: 2_000
        )
        let response = try await complete(request, configuration: configuration, apiKey: apiKey)
        guard (try? JSONValue.parse(Data(response.content.utf8)))?["ok"] != nil else {
            throw ProviderError.invalidResponse("the model didn't follow the JSON schema")
        }
        return response.latency
    }
}
