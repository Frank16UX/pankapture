import AppCore
import Foundation
import Testing
@testable import AIProviders
@testable import AutoEdit
@testable import Transcription

@Suite("Model catalog")
struct ModelCatalogTests {
    private let chatJSON = #"""
    {"data":[
      {"id":"openai/gpt-6-luna","name":"OpenAI: GPT-6 Luna","pricing":{"prompt":"0.00000005","completion":"0.00000025"},
       "reasoning":{"supported_efforts":["max","high","medium","low","none"]}},
      {"id":"openai/gpt-6-luna:batch","name":"OpenAI: GPT-6 Luna (batch)","pricing":{"prompt":"0.00000002","completion":"0.0000001"}},
      {"id":"openrouter/auto","name":"Auto Router","pricing":{"prompt":"-1","completion":"-1"}},
      {"id":"qwen/qwen3.5-35b-a3b","name":"Qwen: Qwen3.5-35B-A3B","pricing":{"prompt":"0.00000014","completion":"0.000001"}}]}
    """#

    @Test func readsPricesPerMillionTokens() throws {
        let models = try OpenRouterCatalog.parse(Data(chatJSON.utf8), transcription: false)
        #expect(models.map(\.id) == ["openai/gpt-6-luna", "qwen/qwen3.5-35b-a3b"])
        let luna = try #require(models.first)
        #expect(luna.name == "GPT-6 Luna")
        #expect(abs((luna.inputPrice ?? 0) - 0.05) < 1e-9)
        #expect(abs((luna.outputPrice ?? 0) - 0.25) < 1e-9)
        #expect(luna.efforts == ["none", "low", "medium", "high", "max"])
        #expect(models[1].efforts == nil)
    }

    @Test func transcriptionBilledBySecondIsPricedPerHour() throws {
        let json = #"""
        {"data":[{"id":"elevenlabs/scribe-v2","name":"ElevenLabs: Scribe v2","pricing":{"prompt":"0.0000611111111111","completion":"0"}},
                 {"id":"openai/gpt-4o-transcribe","name":"OpenAI: GPT-4o Transcribe","pricing":{"prompt":"0.0000025","completion":"0.00001"}}]}
        """#
        let models = try OpenRouterCatalog.parse(Data(json.utf8), transcription: true)
        #expect(abs((models[0].hourPrice ?? 0) - 0.22) < 1e-6)
        #expect(models[1].hourPrice == nil)
        #expect(models[1].inputPrice == 2.5)
    }

    @Test func pricesReadWell() {
        #expect(ModelInfo.dollars(0) == "free")
        #expect(ModelInfo.dollars(0.05) == "$0.05")
        #expect(ModelInfo.dollars(0.075) == "$0.075")
        #expect(ModelInfo.dollars(0.0005) == "$0.0005")
        #expect(ModelInfo.dollars(2) == "$2.00")
        let luna = ModelInfo(id: "m", name: "M", inputPrice: 0.05, outputPrice: 0.25)
        #expect(luna.costPerRecording == 0.0005)
        #expect(luna.priceSummary == "$0.05 in · $0.25 out per 1M tokens")
        #expect(ModelInfo(id: "s", name: "S", hourPrice: 0.22).recordingCostSummary == "≈ $0.055 per 15-minute recording")
    }

    @Test func everyProviderIsComplete() {
        #expect(Set(AIProvider.all.map(\.id)).count == AIProvider.all.count)
        for provider in AIProvider.all {
            #expect(provider.chat != nil || provider.transcription != nil, "\(provider.id) offers nothing")
            if provider.chat?.isLocal == false, provider.id != ProviderPreset.custom.id {
                #expect(!provider.chatModels.isEmpty, "\(provider.id) has no models to pick")
            }
            if provider.transcription != nil { #expect(!provider.transcriptionModels.isEmpty) }
        }
        // Keys saved before ADR-45 keep working under the same accounts.
        #expect(AIProvider.openRouter.keyAccount == "openrouter")
        #expect(AIProvider.elevenLabs.legacyKeyAccounts == ["stt.elevenLabs"])
    }

    @Test func transcriptSourcesReadWell() {
        #expect(AIProvider.transcriptSource("OpenRouter elevenlabs/scribe-v2") == "ElevenLabs Scribe v2 via OpenRouter")
        #expect(AIProvider.transcriptSource("ElevenLabs scribe_v2") == "ElevenLabs Scribe v2")
        #expect(AIProvider.transcriptSource("Groq whisper-large-v3-turbo") == "Groq Whisper large-v3 turbo")
        #expect(AIProvider.transcriptSource("ElevenLabs Scribe") == nil)
    }
}

@MainActor
@Suite("AI settings")
struct AISettingsTests {
    private func defaults() -> UserDefaults {
        let name = "AISettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func settings(_ defaults: UserDefaults, keys: Set<String>) -> AISettings {
        AISettings(defaults: defaults, hasKey: { keys.contains($0) }, catalogFile: nil)
    }

    @Test func startsWithNothingAdded() {
        let settings = settings(defaults(), keys: [])
        #expect(settings.accounts.isEmpty)
        #expect(settings.defaultJudge == .rules)
        #expect(settings.defaultTranscriber == .onDevice)
    }

    @Test func migratesTheOneProviderAndTheCloudService() throws {
        let defaults = defaults()
        let old = ProviderConfiguration(preset: .openRouter, model: "openai/gpt-6-luna", reasoningEffort: "low")
        defaults.set(try JSONEncoder().encode(old), forKey: PreferenceKey.legacyAIProviderConfiguration)
        defaults.set(true, forKey: PreferenceKey.legacyAIProviderEnabled)
        defaults.set("elevenLabs", forKey: PreferenceKey.legacyCloudTranscriptionService)

        let settings = settings(defaults, keys: ["openrouter", "stt.elevenLabs", "stt.groq"])
        #expect(settings.accounts.map(\.providerID) == ["openrouter", "groq", "elevenlabs"])
        #expect(settings.defaultJudge == .model(ModelChoice(providerID: "openrouter", model: "openai/gpt-6-luna", effort: "low")))
        #expect(settings.defaultTranscriber == .cloud(providerID: "elevenlabs", model: "scribe_v2"))
        #expect(settings.savedKeys == ["openrouter", "elevenlabs", "groq"])

        // Migrated once: a second launch reads the new settings.
        let again = self.settings(defaults, keys: ["openrouter", "stt.elevenLabs", "stt.groq"])
        #expect(again.accounts == settings.accounts)
        #expect(again.defaultJudge == settings.defaultJudge)
    }

    @Test func aSwitchedOffProviderMigratesWithoutBeingUsed() throws {
        let defaults = defaults()
        defaults.set(try JSONEncoder().encode(ProviderConfiguration(preset: .lmStudio)), forKey: PreferenceKey.legacyAIProviderConfiguration)
        let settings = settings(defaults, keys: [])
        #expect(settings.accounts.map(\.providerID) == ["lmstudio"])
        #expect(settings.defaultJudge == .rules)
    }

    @Test func choicesFallBackWhenTheProviderIsntReady() {
        let settings = settings(defaults(), keys: [])
        let choice = ModelChoice(providerID: "openrouter", model: "openai/gpt-6-luna")
        #expect(settings.usable(.model(choice)) == .rules)
        #expect(settings.usable(.cloud(providerID: "elevenlabs", model: "scribe_v2")) == .onDevice)
        #expect(settings.configuration(for: choice) == nil)
    }

    @Test func addingTheFirstModelProviderMakesItTheJudge() throws {
        let settings = settings(defaults(), keys: [])
        try settings.add(.lmStudio, key: "", baseURL: URL(string: "http://localhost:1234/v1"))
        #expect(settings.defaultJudge == .model(ModelChoice(providerID: "lmstudio", model: "qwen3.5-9b", effort: nil)))
        // Transcription stays on this Mac: a cloud one sends audio (AI-5).
        #expect(settings.defaultTranscriber == .onDevice)
        let configuration = try #require(settings.configuration(for: ModelChoice(providerID: "lmstudio", model: "qwen3.5-9b", effort: "low")))
        #expect(configuration.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(configuration.reasoningEffort == "low")
        #expect(settings.addableProviders.allSatisfy { $0.id != "lmstudio" })
    }

    @Test func curatedModelsTakeLivePricesFromTheirMaker() throws {
        let settings = settings(defaults(), keys: ["openai"])
        let catalog = OpenRouterCatalog.Models(
            chat: [ModelInfo(id: "openai/gpt-6-luna", name: "GPT-6 Luna", inputPrice: 0.05, outputPrice: 0.25, efforts: ["low", "high"])],
            transcription: [], fetched: Date()
        )
        settings.catalog = catalog
        let direct = try #require(settings.chatModels(for: "openai").first)
        #expect(direct.inputPrice == 0.05)
        // The direct API's efforts aren't OpenRouter's.
        #expect(direct.efforts == nil)
        let routed = try #require(settings.chatModels(for: "openrouter").first)
        #expect(routed.efforts == ["low", "high"])
        #expect(settings.recommendedEffort(routed, provider: .openRouter) == "low")
        // Groq's prices are its own.
        #expect(settings.chatModels(for: "groq").first?.inputPrice == 0.075)
    }
}
