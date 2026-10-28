import AIProviders
import Foundation

/// A provider to evaluate, from a command-line spec:
/// `preset[:model][@effort]`, e.g. `lmstudio:qwen3.5-9b`, `openai:gpt-6-luna@low`.
struct ProviderSpec: Sendable {
    var label: String
    var configuration: ProviderConfiguration
    var apiKey: String?

    struct SpecError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func parse(_ text: String, environment: [String: String]) throws -> ProviderSpec {
        var body = Substring(text)
        var effort: String??
        if let at = body.lastIndex(of: "@") {
            let value = String(body[body.index(after: at)...])
            effort = value == "default" ? nil : .some(value)
            body = body[..<at]
        }
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard let presetID = parts.first, let preset = ProviderPreset.preset(id: presetID) else {
            let known = ProviderPreset.all.map(\.id).joined(separator: ", ")
            throw SpecError(message: "Unknown provider “\(text)”. Use one of: \(known).")
        }
        let model = parts.count > 1 && !parts[1].isEmpty ? parts[1] : preset.defaultModel
        guard !model.isEmpty else { throw SpecError(message: "“\(text)” needs a model, like \(presetID):my-model.") }

        var baseURL: URL?
        if preset.id == ProviderPreset.custom.id {
            guard let value = environment["CUSTOM_BASE_URL"], let url = URL(string: value) else {
                throw SpecError(message: "Set CUSTOM_BASE_URL (e.g. http://localhost:8080/v1) to use the custom provider.")
            }
            baseURL = url
        }
        let configuration = ProviderConfiguration(preset: preset, model: model, baseURL: baseURL, reasoningEffort: effort)
        let key = preset.keyEnvironmentVariable.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        if preset.needsKey, key == nil {
            throw SpecError(message: "\(preset.name) needs an API key: export \(preset.keyEnvironmentVariable ?? "its key") first.")
        }
        return ProviderSpec(label: text, configuration: configuration, apiKey: key)
    }

    /// USD per million input / output tokens, for the report's cost column.
    /// Local models are free; unknown models show "—".
    var price: (input: Double, output: Double)? {
        if configuration.isLocal { return (0, 0) }
        return Self.prices[configuration.model]
    }

    static let prices: [String: (input: Double, output: Double)] = [
        "gpt-6-luna": (0.10, 0.50),
        "claude-haiku-5-5": (0.10, 0.50),
        "gemini-2.5-flash-lite": (0.10, 0.40),
        "gemini-3.5-flash-lite": (0.30, 2.50),
        "openai/gpt-oss-20b": (0.075, 0.30),
        "openai/gpt-oss-120b": (0.15, 0.60),
    ]

    /// File-name-safe label for raw output folders.
    var slug: String {
        String(label.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }
}
