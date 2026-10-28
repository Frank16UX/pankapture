import Foundation
import Testing
@testable import AIProviders

@Suite("JSONValue")
struct JSONValueTests {
    @Test func serializesWithKeysInOrder() {
        let value: JSONValue = ["b": 1, "a": ["x": true, "y": nil], "c": [1.5, "two"]]
        #expect(value.serialized() == #"{"b":1,"a":{"x":true,"y":null},"c":[1.5,"two"]}"#)
    }

    @Test func escapesStrings() {
        let value: JSONValue = .string("say \"hi\"\n\\ ⟨p1⟩ \u{01}")
        #expect(value.serialized() == #""say \"hi\"\n\\ ⟨p1⟩ \u0001""#)
    }

    @Test func parsesAndReadsValues() throws {
        let value = try JSONValue.parse(Data(#"{"choices":[{"message":{"content":"ok"}}],"n":3,"flag":false}"#.utf8))
        #expect(value["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue == "ok")
        #expect(value["n"]?.numberValue == 3)
        #expect(value["flag"] == .bool(false))
    }

    @Test func settingReplacesOrAppends() {
        let value: JSONValue = ["a": 1]
        #expect(value.setting("a", to: 2).serialized() == #"{"a":2}"#)
        #expect(value.setting("b", to: "x").serialized() == #"{"a":1,"b":"x"}"#)
    }
}

@Suite("Language model client")
struct LanguageModelClientTests {
    private let request = StructuredRequest(
        system: "Be brief.", user: "Hello", schemaName: "answer",
        schema: ["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false]
    )

    @Test func openAICompatibleRequest() throws {
        let configuration = ProviderConfiguration(preset: .openAI, reasoningEffort: "low")
        let urlRequest = try LanguageModelClient.urlRequest(for: request, configuration: configuration, apiKey: "sk-test")
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = LanguageModelClient.body(for: request, configuration: configuration)
        #expect(body["model"]?.stringValue == "gpt-6-luna")
        #expect(body["reasoning_effort"]?.stringValue == "low")
        #expect(body["messages"]?.arrayValue?.first?["role"]?.stringValue == "system")
        #expect(body["response_format"]?["json_schema"]?["strict"] == .bool(true))
        #expect(body["max_tokens"] == nil)
        #expect(body["temperature"] == nil)
    }

    @Test func localProvidersNeedNoKeyAndSendNoEffort() throws {
        let configuration = ProviderConfiguration(preset: .lmStudio)
        let urlRequest = try LanguageModelClient.urlRequest(for: request, configuration: configuration, apiKey: nil)
        #expect(urlRequest.url?.absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(LanguageModelClient.body(for: request, configuration: configuration)["reasoning_effort"] == nil)
        #expect(configuration.isLocal)
    }

    @Test func anthropicRequest() throws {
        let configuration = ProviderConfiguration(preset: .anthropic)
        let urlRequest = try LanguageModelClient.urlRequest(for: request, configuration: configuration, apiKey: "key")
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "key")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        let body = LanguageModelClient.body(for: request, configuration: configuration)
        #expect(body["model"]?.stringValue == "claude-haiku-5-5")
        #expect(body["system"]?.stringValue == "Be brief.")
        #expect(body["max_tokens"]?.numberValue == 16_000)
        #expect(body["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["output_config"]?["effort"]?.stringValue == "low")
        #expect(body["temperature"] == nil)
    }

    @Test func cloudProvidersRequireAKey() {
        #expect(throws: ProviderError.missingKey("OpenAI")) {
            try LanguageModelClient.urlRequest(for: request, configuration: ProviderConfiguration(preset: .openAI), apiKey: " ")
        }
    }

    @Test func parsesOpenAIAnswers() throws {
        let data = Data(#"{"choices":[{"message":{"content":"{\"ok\":true}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#.utf8)
        let parsed = try LanguageModelClient.parse(data, api: .openAICompatible)
        #expect(parsed.content == #"{"ok":true}"#)
        #expect(parsed.usage == TokenUsage(input: 12, output: 3))

        let truncated = Data(#"{"choices":[{"message":{"content":"{\"ok\""},"finish_reason":"length"}]}"#.utf8)
        #expect(throws: ProviderError.truncated) { try LanguageModelClient.parse(truncated, api: .openAICompatible) }
        let refused = Data(#"{"choices":[{"message":{"content":null,"refusal":"no"}}]}"#.utf8)
        #expect(throws: ProviderError.refused("no")) { try LanguageModelClient.parse(refused, api: .openAICompatible) }
    }

    @Test func parsesAnthropicAnswers() throws {
        let data = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"ok\":true}"}],"stop_reason":"end_turn","usage":{"input_tokens":20,"output_tokens":5}}"#.utf8)
        let parsed = try LanguageModelClient.parse(data, api: .anthropic)
        #expect(parsed.content == #"{"ok":true}"#)
        #expect(parsed.usage == TokenUsage(input: 20, output: 5))

        let refused = Data(#"{"content":[],"stop_reason":"refusal","stop_details":{"explanation":"policy"}}"#.utf8)
        #expect(throws: ProviderError.refused("policy")) { try LanguageModelClient.parse(refused, api: .anthropic) }
        let truncated = Data(#"{"content":[{"type":"text","text":"{"}],"stop_reason":"max_tokens"}"#.utf8)
        #expect(throws: ProviderError.truncated) { try LanguageModelClient.parse(truncated, api: .anthropic) }
    }

    @Test func extractsJSONFromChattyAnswers() {
        #expect(LanguageModelClient.extractJSON(from: "<think>hmm {no}</think>\n```json\n{\"a\":1}\n```") == #"{"a":1}"#)
        #expect(LanguageModelClient.extractJSON(from: #"Here you go: {"a":{"b":2}} done"#) == #"{"a":{"b":2}}"#)
        #expect(LanguageModelClient.extractJSON(from: "nothing") == "nothing")
    }

    @Test func errorMessagesComeFromTheBody() {
        #expect(LanguageModelClient.errorMessage(in: Data(#"{"error":{"message":"bad key"}}"#.utf8)) == "bad key")
        #expect(LanguageModelClient.errorMessage(in: Data(#"{"type":"error","error":{"type":"x","message":"overloaded"}}"#.utf8)) == "overloaded")
        #expect(LanguageModelClient.errorMessage(in: Data("Bad Gateway".utf8)) == "Bad Gateway")
    }

    @Test func presetsAreComplete() {
        #expect(Set(ProviderPreset.all.map(\.id)).count == ProviderPreset.all.count)
        for preset in ProviderPreset.all where preset.needsKey {
            #expect(preset.keyEnvironmentVariable != nil)
        }
        #expect(ProviderConfiguration(preset: .openAI, reasoningEffort: "none").displayName == "OpenAI gpt-6-luna (none)")
        #expect(!ProviderConfiguration(preset: .openAI).isLocal)
    }

    /// A rejected key says so and where to fix it, not just the status.
    @Test func rejectedKeyIsExplained() {
        for status in [401, 403] {
            let message = ProviderError.http(status: status, message: "invalid x-api-key").errorDescription ?? ""
            #expect(message.contains("rejected the API key") && message.contains("Settings ▸ AI"))
        }
        #expect(ProviderError.http(status: 500, message: "overloaded").errorDescription == "The provider answered 500: overloaded")
    }
}
