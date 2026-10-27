import AIProviders
import Foundation
import Transcription

/// A provider the user can add in Settings ▸ AI (PRD AI-8): a vendor account
/// or a server on this Mac, with one key, offering language models (auto-edit's
/// judgments), transcription (AI-5), or both.
public struct AIProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// How it answers language-model requests, if it has language models.
    public let chat: ProviderPreset?
    /// Its speech-to-text API, if it transcribes.
    public let transcription: CloudTranscriptionService?
    /// Models the pickers offer first. Prices come from OpenRouter's public
    /// list where the maker sells the same model there (`catalogID`).
    public let chatModels: [CuratedModel]
    public let transcriptionModels: [CuratedModel]
    /// Where to get a key.
    public let keysURL: URL?
    /// Keychain accounts older builds saved this vendor's key under (cloud
    /// transcription kept its own); read as a fallback, removed on save.
    public let legacyKeyAccounts: [String]

    /// Lists every model OpenRouter has, with live prices.
    public var browsesCatalog: Bool { id == ProviderPreset.openRouter.id }
    public var needsKey: Bool { chat?.needsKey ?? true }
    public var isLocal: Bool { chat?.isLocal ?? false }
    /// Only local servers and custom endpoints have a URL worth editing.
    public var editsURL: Bool { isLocal || id == ProviderPreset.custom.id }
    /// Custom endpoints may or may not want a key.
    public var takesKey: Bool { needsKey || id == ProviderPreset.custom.id }
    /// Keychain account of its key: the preset ID, as before (ADR-45).
    public var keyAccount: String { id }

    /// "Language models and transcription".
    public var offers: String {
        switch (chat != nil, transcription != nil) {
        case (true, true): "Language models and transcription"
        case (false, true): "Transcription"
        default: isLocal ? "Language models on this Mac, free and private" : "Language models"
        }
    }

    public struct CuratedModel: Hashable, Sendable {
        public var info: ModelInfo
        /// The same model in OpenRouter's list, for its live price.
        public var catalogID: String?

        init(_ info: ModelInfo, catalogID: String? = nil) {
            self.info = info
            self.catalogID = catalogID
        }
    }

    public static let all: [AIProvider] = [openRouter, anthropic, openAI, gemini, groq, elevenLabs, lmStudio, ollama, custom]

    public static func provider(id: String) -> AIProvider? {
        all.first { $0.id == id }
    }

    /// Transcription models are the ones that answered a probe clip with word
    /// timings (2026-10-27); GPT Transcribe, Chirp 3, and Voxtral didn't.
    public static let openRouter = AIProvider(
        id: ProviderPreset.openRouter.id, name: "OpenRouter", chat: .openRouter, transcription: .openRouter,
        chatModels: [
            .init(ModelInfo(id: "openai/gpt-6-luna", name: "GPT-6 Luna", recommendedEffort: "low"), catalogID: "openai/gpt-6-luna"),
            .init(ModelInfo(id: "anthropic/claude-haiku-5.5", name: "Claude Haiku 5.5", recommendedEffort: "low"), catalogID: "anthropic/claude-haiku-5.5"),
            .init(ModelInfo(id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"), catalogID: "google/gemini-2.5-flash-lite"),
            .init(ModelInfo(id: "deepseek/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", recommendedEffort: "low"), catalogID: "deepseek/deepseek-v4.1-flash"),
            .init(ModelInfo(id: "openai/gpt-oss-120b", name: "gpt-oss-120b", recommendedEffort: "low"), catalogID: "openai/gpt-oss-120b"),
            .init(ModelInfo(id: "qwen/qwen3.5-35b-a3b", name: "Qwen3.5 35B A3B"), catalogID: "qwen/qwen3.5-35b-a3b"),
            .init(ModelInfo(id: "anthropic/claude-sonnet-5.5", name: "Claude Sonnet 5.5", recommendedEffort: "low"), catalogID: "anthropic/claude-sonnet-5.5"),
        ],
        transcriptionModels: [
            .init(ModelInfo(id: "elevenlabs/scribe-v2", name: "ElevenLabs Scribe v2", isVerbatim: true), catalogID: "elevenlabs/scribe-v2"),
            .init(ModelInfo(id: "assemblyai/universal-3-6-pro", name: "AssemblyAI Universal-3.6 Pro", isVerbatim: true), catalogID: "assemblyai/universal-3-6-pro"),
            .init(ModelInfo(id: "openai/whisper-large-v3-turbo", name: "Whisper large-v3 turbo"), catalogID: "openai/whisper-large-v3-turbo"),
            .init(ModelInfo(id: "nvidia/parakeet-tdt-0.6b-v3", name: "NVIDIA Parakeet v3"), catalogID: "nvidia/parakeet-tdt-0.6b-v3"),
            .init(ModelInfo(id: "deepgram/nova-3", name: "Deepgram Nova-3"), catalogID: "deepgram/nova-3"),
        ],
        keysURL: URL(string: "https://openrouter.ai/settings/keys"), legacyKeyAccounts: []
    )
    public static let anthropic = AIProvider(
        id: ProviderPreset.anthropic.id, name: "Anthropic", chat: .anthropic, transcription: nil,
        chatModels: [
            .init(ModelInfo(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", efforts: ["low", "medium", "high"], recommendedEffort: "low"), catalogID: "anthropic/claude-haiku-5.5"),
            .init(ModelInfo(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", efforts: ["low", "medium", "high"], recommendedEffort: "low"), catalogID: "anthropic/claude-sonnet-5.5"),
        ],
        transcriptionModels: [],
        keysURL: URL(string: "https://platform.claude.com/settings/keys"), legacyKeyAccounts: []
    )
    public static let openAI = AIProvider(
        id: ProviderPreset.openAI.id, name: "OpenAI", chat: .openAI, transcription: .openAI,
        chatModels: [
            .init(ModelInfo(id: "gpt-6-luna", name: "GPT-6 Luna", recommendedEffort: "none"), catalogID: "openai/gpt-6-luna"),
            .init(ModelInfo(id: "gpt-6.1-terra", name: "GPT-6.1 Terra", recommendedEffort: "low"), catalogID: "openai/gpt-6.1-terra"),
        ],
        transcriptionModels: [
            .init(ModelInfo(id: "whisper-1", name: "Whisper"), catalogID: "openai/whisper-1"),
        ],
        keysURL: URL(string: "https://platform.openai.com/api-keys"), legacyKeyAccounts: ["stt.openAI"]
    )
    public static let gemini = AIProvider(
        id: ProviderPreset.gemini.id, name: "Google Gemini", chat: .gemini, transcription: nil,
        chatModels: [
            .init(ModelInfo(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash-Lite"), catalogID: "google/gemini-2.5-flash-lite"),
            .init(ModelInfo(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite", recommendedEffort: "minimal"), catalogID: "google/gemini-3.5-flash-lite"),
        ],
        transcriptionModels: [],
        keysURL: URL(string: "https://aistudio.google.com/apikey"), legacyKeyAccounts: []
    )
    /// Groq hosts open models at its own prices (AUTO-EDIT §5.2, 2026-10-26),
    /// so OpenRouter's don't apply.
    public static let groq = AIProvider(
        id: ProviderPreset.groq.id, name: "Groq", chat: .groq, transcription: .groq,
        chatModels: [
            .init(ModelInfo(id: "openai/gpt-oss-20b", name: "gpt-oss-20b", inputPrice: 0.075, outputPrice: 0.30, efforts: ["low", "medium", "high"], recommendedEffort: "low")),
            .init(ModelInfo(id: "openai/gpt-oss-120b", name: "gpt-oss-120b", inputPrice: 0.15, outputPrice: 0.60, efforts: ["low", "medium", "high"], recommendedEffort: "low")),
        ],
        transcriptionModels: [
            .init(ModelInfo(id: "whisper-large-v3-turbo", name: "Whisper large-v3 turbo", hourPrice: 0.04)),
        ],
        keysURL: URL(string: "https://console.groq.com/keys"), legacyKeyAccounts: ["stt.groq"]
    )
    public static let elevenLabs = AIProvider(
        id: "elevenlabs", name: "ElevenLabs", chat: nil, transcription: .elevenLabs,
        chatModels: [],
        transcriptionModels: [
            .init(ModelInfo(id: "scribe_v2", name: "Scribe v2", hourPrice: 0.22, isVerbatim: true), catalogID: "elevenlabs/scribe-v2"),
        ],
        keysURL: URL(string: "https://elevenlabs.io/app/settings/api-keys"), legacyKeyAccounts: ["stt.elevenLabs"]
    )
    public static let lmStudio = AIProvider(
        id: ProviderPreset.lmStudio.id, name: "LM Studio", chat: .lmStudio, transcription: nil,
        chatModels: [.init(ModelInfo(id: "qwen3.5-9b", name: "Qwen3.5 9B", inputPrice: 0, outputPrice: 0))],
        transcriptionModels: [], keysURL: nil, legacyKeyAccounts: []
    )
    public static let ollama = AIProvider(
        id: ProviderPreset.ollama.id, name: "Ollama", chat: .ollama, transcription: nil,
        chatModels: [.init(ModelInfo(id: "qwen3.5:9b", name: "Qwen3.5 9B", inputPrice: 0, outputPrice: 0))],
        transcriptionModels: [], keysURL: nil, legacyKeyAccounts: []
    )
    public static let custom = AIProvider(
        id: ProviderPreset.custom.id, name: "Custom (OpenAI-compatible)", chat: .custom, transcription: nil,
        chatModels: [], transcriptionModels: [], keysURL: nil, legacyKeyAccounts: []
    )

    /// A readable name for a transcript's engine ("ElevenLabs Scribe v2 via
    /// OpenRouter" for "OpenRouter elevenlabs/scribe-v2"); `nil` if unknown.
    public static func transcriptSource(_ engine: String) -> String? {
        for provider in all {
            guard let service = provider.transcription else { continue }
            for model in provider.transcriptionModels
            where CloudTranscription(service: service, model: model.info.id, apiKey: "").displayName == engine {
                if provider.browsesCatalog { return "\(model.info.name) via \(provider.name)" }
                return model.info.name.hasPrefix(provider.name) ? model.info.name : "\(provider.name) \(model.info.name)"
            }
        }
        return nil
    }

    /// Efforts a model accepts: its own list when known, else the API's usual one.
    public func efforts(for model: ModelInfo?) -> [String] {
        if let efforts = model?.efforts, !efforts.isEmpty { return efforts }
        switch chat?.api {
        case .anthropic: return ["low", "medium", "high"]
        case .openAICompatible: return ["none", "low", "medium", "high"]
        case nil: return []
        }
    }
}
