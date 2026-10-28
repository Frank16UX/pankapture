import Foundation

/// The two wire protocols that cover every supported provider (PRD AI-2).
public enum ProviderAPI: String, Codable, Sendable {
    /// Anthropic Messages API (`/v1/messages`).
    case anthropic
    /// OpenAI Chat Completions (`/chat/completions`): OpenAI, Gemini's
    /// compatibility endpoint, Groq, OpenRouter, LM Studio, Ollama, and others.
    case openAICompatible
}

/// A ready-made provider setting. Presets are data: model names change every
/// few months, so the model is always editable.
public struct ProviderPreset: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let api: ProviderAPI
    public let baseURL: URL
    public let defaultModel: String
    /// Sent as `reasoning_effort` (OpenAI-compatible) or `output_config.effort`
    /// (Anthropic); `nil` leaves the provider's default.
    public let defaultReasoningEffort: String?
    public let needsKey: Bool
    /// Runs on this Mac: free, private, nothing to configure but the server.
    public let isLocal: Bool
    /// Environment variable `make eval` reads the key from.
    public let keyEnvironmentVariable: String?

    public static let anthropic = ProviderPreset(
        id: "anthropic", name: "Anthropic", api: .anthropic,
        baseURL: URL(string: "https://api.anthropic.com")!, defaultModel: "claude-haiku-5-5",
        defaultReasoningEffort: "low", needsKey: true, isLocal: false, keyEnvironmentVariable: "ANTHROPIC_API_KEY"
    )
    public static let openAI = ProviderPreset(
        id: "openai", name: "OpenAI", api: .openAICompatible,
        baseURL: URL(string: "https://api.openai.com/v1")!, defaultModel: "gpt-6-luna",
        defaultReasoningEffort: "none", needsKey: true, isLocal: false, keyEnvironmentVariable: "OPENAI_API_KEY"
    )
    public static let gemini = ProviderPreset(
        id: "gemini", name: "Google Gemini", api: .openAICompatible,
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!, defaultModel: "gemini-2.5-flash-lite",
        defaultReasoningEffort: nil, needsKey: true, isLocal: false, keyEnvironmentVariable: "GEMINI_API_KEY"
    )
    public static let groq = ProviderPreset(
        id: "groq", name: "Groq", api: .openAICompatible,
        baseURL: URL(string: "https://api.groq.com/openai/v1")!, defaultModel: "openai/gpt-oss-20b",
        defaultReasoningEffort: "low", needsKey: true, isLocal: false, keyEnvironmentVariable: "GROQ_API_KEY"
    )
    public static let openRouter = ProviderPreset(
        id: "openrouter", name: "OpenRouter", api: .openAICompatible,
        baseURL: URL(string: "https://openrouter.ai/api/v1")!, defaultModel: "openai/gpt-6-luna",
        defaultReasoningEffort: nil, needsKey: true, isLocal: false, keyEnvironmentVariable: "OPENROUTER_API_KEY"
    )
    public static let lmStudio = ProviderPreset(
        id: "lmstudio", name: "LM Studio", api: .openAICompatible,
        baseURL: URL(string: "http://localhost:1234/v1")!, defaultModel: "qwen3.5-9b",
        defaultReasoningEffort: nil, needsKey: false, isLocal: true, keyEnvironmentVariable: nil
    )
    public static let ollama = ProviderPreset(
        id: "ollama", name: "Ollama", api: .openAICompatible,
        baseURL: URL(string: "http://localhost:11434/v1")!, defaultModel: "qwen3.5:9b",
        defaultReasoningEffort: nil, needsKey: false, isLocal: true, keyEnvironmentVariable: nil
    )
    /// Any OpenAI-compatible endpoint; base URL and model are the user's.
    public static let custom = ProviderPreset(
        id: "custom", name: "Custom (OpenAI-compatible)", api: .openAICompatible,
        baseURL: URL(string: "http://localhost:8080/v1")!, defaultModel: "",
        defaultReasoningEffort: nil, needsKey: false, isLocal: false, keyEnvironmentVariable: "CUSTOM_API_KEY"
    )

    public static let all: [ProviderPreset] = [anthropic, openAI, gemini, groq, openRouter, lmStudio, ollama, custom]

    public static func preset(id: String) -> ProviderPreset? {
        all.first { $0.id == id }
    }
}

/// The provider a request goes to: a preset, possibly with its model, URL, or
/// effort changed. Contains no secrets; keys are passed separately.
public struct ProviderConfiguration: Codable, Hashable, Sendable {
    public var presetID: String
    public var api: ProviderAPI
    public var baseURL: URL
    public var model: String
    public var reasoningEffort: String?

    public init(preset: ProviderPreset, model: String? = nil, baseURL: URL? = nil, reasoningEffort: String?? = nil) {
        self.presetID = preset.id
        self.api = preset.api
        self.baseURL = baseURL ?? preset.baseURL
        self.model = model ?? preset.defaultModel
        self.reasoningEffort = reasoningEffort ?? preset.defaultReasoningEffort
    }

    public var preset: ProviderPreset? { ProviderPreset.preset(id: presetID) }

    /// Requests stay on this Mac.
    public var isLocal: Bool {
        guard let host = baseURL.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// "OpenAI gpt-6-luna (none)".
    public var displayName: String {
        let name = preset?.name ?? presetID
        let effort = reasoningEffort.map { " (\($0))" } ?? ""
        return "\(name) \(model)\(effort)"
    }
}

public enum ProviderError: LocalizedError, Equatable {
    case missingKey(String)
    case http(status: Int, message: String)
    case invalidResponse(String)
    case refused(String)
    /// The answer hit the output limit before it was complete.
    case truncated
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "\(provider) needs an API key: save one in Settings ▸ AI, and allow Pankapture to use it if macOS asks."
        case let .http(status, _) where status == 401 || status == 403:
            "The provider rejected the API key (\(status)). It may be mistyped, expired, or revoked: save a new one in Settings ▸ AI."
        case let .http(status, message): "The provider answered \(status): \(message)"
        case .invalidResponse(let detail): "The provider's answer couldn't be read: \(detail)"
        case .refused(let detail): "The model declined the request\(detail.isEmpty ? "" : ": \(detail)")."
        case .truncated: "The model's answer was cut off before it was complete."
        case .network(let detail): "Couldn't reach the provider: \(detail)"
        }
    }
}
