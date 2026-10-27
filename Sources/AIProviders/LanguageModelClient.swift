import Foundation

/// A request for JSON that follows `schema` (structured output).
public struct StructuredRequest: Sendable {
    public var system: String
    public var user: String
    /// Identifier for the schema (OpenAI requires one), e.g. "auto_edit".
    public var schemaName: String
    /// A JSON Schema object. Every object needs `additionalProperties: false`
    /// and every property listed in `required` (strict mode on both APIs).
    public var schema: JSONValue
    /// Anthropic requires a cap; OpenAI-compatible requests leave it to the
    /// provider (reasoning models reject `max_tokens`).
    public var maxOutputTokens: Int

    public init(system: String, user: String, schemaName: String, schema: JSONValue, maxOutputTokens: Int = 16_000) {
        self.system = system
        self.user = user
        self.schemaName = schemaName
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct TokenUsage: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int

    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public struct StructuredResponse: Sendable {
    /// The JSON text, cleaned of reasoning tags and code fences.
    public var content: String
    public var usage: TokenUsage
    /// Seconds from sending the request to having the answer.
    public var latency: Double
}

/// Sends structured-output requests to any supported provider over plain
/// HTTPS (no SDKs, ADR-10). Request building and response parsing are static
/// and pure, so they're unit-tested without a network.
public struct LanguageModelClient: Sendable {
    /// The Anthropic API version this client speaks.
    public static let anthropicVersion = "2026-10-21"
    /// Local models can take minutes on a long transcript.
    public static let timeout: TimeInterval = 600

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func complete(_ request: StructuredRequest, configuration: ProviderConfiguration, apiKey: String?) async throws -> StructuredResponse {
        let urlRequest = try Self.urlRequest(for: request, configuration: configuration, apiKey: apiKey)
        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
        let latency = (ContinuousClock.now - started) / .seconds(1)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, message: Self.errorMessage(in: data))
        }
        let parsed = try Self.parse(data, api: configuration.api)
        return StructuredResponse(content: parsed.content, usage: parsed.usage, latency: latency)
    }

    // MARK: Requests

    public static func urlRequest(for request: StructuredRequest, configuration: ProviderConfiguration, apiKey: String?) throws -> URLRequest {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty, configuration.preset?.needsKey == true {
            throw ProviderError.missingKey(configuration.preset?.name ?? configuration.presetID)
        }
        var urlRequest: URLRequest
        switch configuration.api {
        case .anthropic:
            urlRequest = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
            urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            urlRequest = URLRequest(url: configuration.baseURL.appending(path: "chat/completions"))
            if !key.isEmpty { urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body(for: request, configuration: configuration).data()
        return urlRequest
    }

    public static func body(for request: StructuredRequest, configuration: ProviderConfiguration) -> JSONValue {
        switch configuration.api {
        case .anthropic:
            // No temperature/top_p/top_k: API version 2026-10-21 rejects them.
            var outputConfig: JSONValue = ["format": ["type": "json_schema", "schema": request.schema]]
            if let effort = configuration.reasoningEffort { outputConfig = outputConfig.setting("effort", to: .string(effort)) }
            return [
                "model": .string(configuration.model),
                "max_tokens": .number(Double(request.maxOutputTokens)),
                "system": .string(request.system),
                "messages": [["role": "user", "content": .string(request.user)]],
                "output_config": outputConfig,
            ]
        case .openAICompatible:
            var body: JSONValue = [
                "model": .string(configuration.model),
                "messages": [
                    ["role": "system", "content": .string(request.system)],
                    ["role": "user", "content": .string(request.user)],
                ],
                "response_format": [
                    "type": "json_schema",
                    "json_schema": ["name": .string(request.schemaName), "strict": true, "schema": request.schema],
                ],
                "stream": false,
            ]
            if let effort = configuration.reasoningEffort { body = body.setting("reasoning_effort", to: .string(effort)) }
            return body
        }
    }

    // MARK: Responses

    public static func parse(_ data: Data, api: ProviderAPI) throws -> (content: String, usage: TokenUsage) {
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            throw ProviderError.invalidResponse("not JSON")
        }
        switch api {
        case .anthropic:
            let stopReason = json["stop_reason"]?.stringValue
            if stopReason == "refusal" {
                throw ProviderError.refused(json["stop_details"]?["explanation"]?.stringValue ?? "")
            }
            if stopReason == "max_tokens" { throw ProviderError.truncated }
            let text = (json["content"]?.arrayValue ?? [])
                .filter { $0["type"]?.stringValue == "text" }
                .compactMap { $0["text"]?.stringValue }
                .joined()
            guard !text.isEmpty else { throw ProviderError.invalidResponse("no text in the answer") }
            let usage = TokenUsage(
                input: Int(json["usage"]?["input_tokens"]?.numberValue ?? 0),
                output: Int(json["usage"]?["output_tokens"]?.numberValue ?? 0)
            )
            return (extractJSON(from: text), usage)
        case .openAICompatible:
            guard let choice = json["choices"]?.arrayValue?.first else {
                throw ProviderError.invalidResponse("no choices in the answer")
            }
            if let refusal = choice["message"]?["refusal"]?.stringValue, !refusal.isEmpty {
                throw ProviderError.refused(refusal)
            }
            if choice["finish_reason"]?.stringValue == "length" { throw ProviderError.truncated }
            guard let text = choice["message"]?["content"]?.stringValue, !text.isEmpty else {
                throw ProviderError.invalidResponse("empty answer")
            }
            let usage = TokenUsage(
                input: Int(json["usage"]?["prompt_tokens"]?.numberValue ?? 0),
                output: Int(json["usage"]?["completion_tokens"]?.numberValue ?? 0)
            )
            return (extractJSON(from: text), usage)
        }
    }

    /// The JSON object inside a model's text: drops `<think>…</think>` blocks
    /// (local reasoning models) and code fences, then takes the outermost
    /// `{…}`. Returns the input trimmed when there's no object.
    public static func extractJSON(from text: String) -> String {
        var text = text
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) {
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(text[first...last])
    }

    /// The most useful message in an error body.
    static func errorMessage(in data: Data) -> String {
        if let json = try? JSONValue.parse(data) {
            if let message = json["error"]?["message"]?.stringValue { return message }
            if let message = json["error"]?.stringValue { return message }
            if let message = json["message"]?.stringValue { return message }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no details" : text
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
