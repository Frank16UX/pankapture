import AIProviders
import AppCore
import Foundation
import Observation
import Transcription

/// What judges auto-edit's pauses and mistakes (PRD AI-1, AI-8).
public enum Judge: Codable, Hashable, Sendable {
    /// The built-in rules, on this Mac (the default).
    case rules
    case model(ModelChoice)
}

/// A language model with its reasoning effort.
public struct ModelChoice: Codable, Hashable, Sendable {
    public var providerID: String
    public var model: String
    /// `nil` = the provider's default.
    public var effort: String?

    public init(providerID: String, model: String, effort: String? = nil) {
        self.providerID = providerID
        self.model = model
        self.effort = effort
    }
}

/// What transcribes the microphone (PRD AE-1, AI-5). Chosen per editor,
/// starting from `AISettings.defaultTranscriber` (ADR-45).
public enum Transcriber: Codable, Hashable, Sendable {
    /// `SpeechTranscriber`, on this Mac (the default).
    case onDevice
    /// A cloud service: it receives the microphone audio.
    case cloud(providerID: String, model: String)
}

/// A provider the user added in Settings ▸ AI. Holds no secrets: its key is
/// in the Keychain (AI-3).
public struct ProviderAccount: Codable, Hashable, Identifiable, Sendable {
    public var providerID: String
    /// Local servers and custom endpoints; `nil` = the provider's usual URL.
    public var baseURL: URL?

    public var id: String { providerID }
    public var provider: AIProvider? { AIProvider.provider(id: providerID) }

    public init(providerID: String, baseURL: URL? = nil) {
        self.providerID = providerID
        self.baseURL = baseURL
    }
}

/// The providers the user added and the defaults each editor starts with
/// (PRD AI-8, ADR-45). Settings ▸ AI and every editor observe the one shared
/// instance, so a change in either shows everywhere at once.
///
/// Never reads a key: `savedKeys` comes from Keychain attributes, which don't
/// prompt; `apiKey(for:)` reads a key off the main actor when a request is
/// about to be made (ADR-41).
@MainActor @Observable
public final class AISettings {
    public static let shared = AISettings(defaults: .standard, hasKey: APIKeyStore.hasKey(for:))

    public private(set) var accounts: [ProviderAccount]
    /// Providers with a key saved.
    public private(set) var savedKeys: Set<String>
    /// What judges auto-edit in a new editor.
    public var defaultJudge: Judge {
        didSet { store(defaultJudge, PreferenceKey.aiDefaultJudge) }
    }
    /// What transcribes in a new editor.
    public var defaultTranscriber: Transcriber {
        didSet { store(defaultTranscriber, PreferenceKey.aiDefaultTranscriber) }
    }
    /// OpenRouter's model list with live prices (also the price reference for
    /// models their makers sell directly).
    public internal(set) var catalog: OpenRouterCatalog.Models?
    public private(set) var isLoadingCatalog = false
    public private(set) var catalogError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let hasKey: (String) -> Bool
    @ObservationIgnored private let catalogFile: URL?

    /// `hasKey` checks a Keychain account without reading it.
    public init(defaults: UserDefaults, hasKey: @escaping (String) -> Bool, catalogFile: URL? = AppPaths.modelCatalog) {
        self.defaults = defaults
        self.hasKey = hasKey
        self.catalogFile = catalogFile
        let savedKeys = Set(AIProvider.all.filter { provider in
            ([provider.keyAccount] + provider.legacyKeyAccounts).contains(where: hasKey)
        }.map(\.id))
        self.savedKeys = savedKeys
        if let data = defaults.data(forKey: PreferenceKey.aiProviders),
           let accounts = try? JSONDecoder().decode([ProviderAccount].self, from: data) {
            self.accounts = accounts
            defaultJudge = Self.load(Judge.self, PreferenceKey.aiDefaultJudge, from: defaults) ?? .rules
            defaultTranscriber = Self.load(Transcriber.self, PreferenceKey.aiDefaultTranscriber, from: defaults) ?? .onDevice
        } else {
            let migrated = Self.migrate(defaults, savedKeys: savedKeys)
            accounts = migrated.accounts
            defaultJudge = migrated.judge
            defaultTranscriber = migrated.transcriber
            saveAccounts()
            store(defaultJudge, PreferenceKey.aiDefaultJudge)
            store(defaultTranscriber, PreferenceKey.aiDefaultTranscriber)
        }
        if let catalogFile, let data = try? Data(contentsOf: catalogFile) {
            catalog = try? JSONDecoder.iso8601.decode(OpenRouterCatalog.Models.self, from: data)
        }
    }

    // MARK: Providers

    public func account(_ providerID: String) -> ProviderAccount? {
        accounts.first { $0.providerID == providerID }
    }

    /// Added, and with a key saved when it needs one.
    public func isReady(_ providerID: String) -> Bool {
        guard let account = account(providerID), let provider = account.provider else { return false }
        return !provider.needsKey || savedKeys.contains(providerID)
    }

    /// Providers not added yet, for Add Provider.
    public var addableProviders: [AIProvider] {
        AIProvider.all.filter { account($0.id) == nil }
    }

    /// Adds `provider` (or updates it), saving `key` when one is given. The
    /// first language model added becomes the default judge: adding a
    /// provider is the opt-in (AI-1). Transcription stays on this Mac until
    /// the user picks a service, because that sends audio (AI-5).
    public func add(_ provider: AIProvider, key: String, baseURL: URL?) throws {
        if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try setKey(key, for: provider.id) }
        let account = ProviderAccount(providerID: provider.id, baseURL: provider.editsURL ? baseURL : nil)
        if let index = accounts.firstIndex(where: { $0.providerID == provider.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        saveAccounts()
        if defaultJudge == .rules, isReady(provider.id), let model = chatModels(for: provider.id).first {
            defaultJudge = .model(ModelChoice(providerID: provider.id, model: model.id, effort: recommendedEffort(model, provider: provider)))
        }
    }

    /// Removes the provider and its key. Defaults that used it fall back to
    /// the rules and on-device transcription.
    public func remove(_ providerID: String) {
        guard let provider = AIProvider.provider(id: providerID) else { return }
        for account in [provider.keyAccount] + provider.legacyKeyAccounts { APIKeyStore.deleteKey(for: account) }
        savedKeys.remove(providerID)
        accounts.removeAll { $0.providerID == providerID }
        saveAccounts()
        if case .model(let choice) = defaultJudge, choice.providerID == providerID { defaultJudge = .rules }
        if case .cloud(let id, _) = defaultTranscriber, id == providerID { defaultTranscriber = .onDevice }
    }

    /// Saves (or, when empty, deletes) the provider's key.
    public func setKey(_ key: String, for providerID: String) throws {
        guard let provider = AIProvider.provider(id: providerID) else { return }
        try APIKeyStore.setKey(key, for: provider.keyAccount)
        for legacy in provider.legacyKeyAccounts { APIKeyStore.deleteKey(for: legacy) }
        if hasKey(provider.keyAccount) { savedKeys.insert(providerID) } else { savedKeys.remove(providerID) }
    }

    public func setBaseURL(_ url: URL, for providerID: String) {
        guard let index = accounts.firstIndex(where: { $0.providerID == providerID }) else { return }
        accounts[index].baseURL = url
        saveAccounts()
    }

    /// The key for a request about to be made, `nil` when there's none (or
    /// the Keychain wouldn't give it). May wait on a Keychain prompt, so call
    /// it off the main actor (ADR-41).
    public nonisolated static func apiKey(for providerID: String) -> String? {
        guard let provider = AIProvider.provider(id: providerID) else { return nil }
        for account in [provider.keyAccount] + provider.legacyKeyAccounts {
            if let key = APIKeyStore.key(for: account) { return key }
        }
        return nil
    }

    // MARK: Choices

    /// `judge` if it can run now, else the rules.
    public func usable(_ judge: Judge) -> Judge {
        guard case .model(let choice) = judge else { return .rules }
        return configuration(for: choice) == nil ? .rules : judge
    }

    /// `transcriber` if it can run now, else on device.
    public func usable(_ transcriber: Transcriber) -> Transcriber {
        guard case .cloud(let providerID, let model) = transcriber else { return .onDevice }
        return isReady(providerID) && !model.isEmpty && AIProvider.provider(id: providerID)?.transcription != nil ? transcriber : .onDevice
    }

    /// The request settings for `choice`, `nil` if its provider isn't ready.
    public func configuration(for choice: ModelChoice) -> ProviderConfiguration? {
        guard isReady(choice.providerID), !choice.model.isEmpty,
              let preset = AIProvider.provider(id: choice.providerID)?.chat else { return nil }
        return ProviderConfiguration(preset: preset, model: choice.model, baseURL: account(choice.providerID)?.baseURL,
                                     reasoningEffort: .some(choice.effort))
    }

    /// The service and model for a cloud `transcriber`.
    public func cloudService(for transcriber: Transcriber) -> (service: CloudTranscriptionService, model: String)? {
        guard case .cloud(let providerID, let model) = usable(transcriber),
              let service = AIProvider.provider(id: providerID)?.transcription else { return nil }
        return (service, model)
    }

    /// Ready providers with language models, in Add Provider's order.
    public var chatProviders: [AIProvider] {
        AIProvider.all.filter { $0.chat != nil && isReady($0.id) }
    }

    /// Ready providers that transcribe.
    public var transcriptionProviders: [AIProvider] {
        AIProvider.all.filter { $0.transcription != nil && isReady($0.id) }
    }

    // MARK: Models

    /// The provider's curated language models, with live prices where known.
    public func chatModels(for providerID: String) -> [ModelInfo] {
        AIProvider.provider(id: providerID)?.chatModels.map { priced($0, in: catalog?.chat) } ?? []
    }

    public func transcriptionModels(for providerID: String) -> [ModelInfo] {
        AIProvider.provider(id: providerID)?.transcriptionModels.map { priced($0, in: catalog?.transcription) } ?? []
    }

    /// Every language model the provider lists: OpenRouter's whole catalog,
    /// else the curated ones.
    public func allChatModels(for providerID: String) -> [ModelInfo] {
        let curated = chatModels(for: providerID)
        guard AIProvider.provider(id: providerID)?.browsesCatalog == true, let catalog else { return curated }
        let curatedIDs = Set(curated.map(\.id))
        return curated + catalog.chat.filter { !curatedIDs.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// What's known about a chosen model, curated or from the catalog; a bare
    /// entry for a model ID the user typed.
    public func chatModel(_ choice: ModelChoice) -> ModelInfo {
        chatModels(for: choice.providerID).first { $0.id == choice.model }
            ?? (AIProvider.provider(id: choice.providerID)?.browsesCatalog == true ? catalog?.chatModel(choice.model) : nil)
            ?? ModelInfo(id: choice.model, name: choice.model)
    }

    public func transcriptionModel(providerID: String, model: String) -> ModelInfo {
        transcriptionModels(for: providerID).first { $0.id == model }
            ?? ModelInfo(id: model, name: model,
                         isVerbatim: AIProvider.provider(id: providerID)?.transcription?.isVerbatim(model: model) ?? false)
    }

    /// The effort to start a newly picked model with.
    public func recommendedEffort(_ model: ModelInfo, provider: AIProvider) -> String? {
        let efforts = provider.efforts(for: model)
        if let effort = model.recommendedEffort, efforts.contains(effort) { return effort }
        if model.efforts != nil { return nil }
        return provider.chat?.defaultReasoningEffort.flatMap { efforts.contains($0) ? $0 : nil }
    }

    /// The curated model with the catalog's price and efforts, when it has them.
    private func priced(_ curated: AIProvider.CuratedModel, in models: [ModelInfo]?) -> ModelInfo {
        var info = curated.info
        guard let id = curated.catalogID, let live = models?.first(where: { $0.id == id }) else { return info }
        if let hourPrice = live.hourPrice {
            info.hourPrice = hourPrice
        } else {
            info.inputPrice = live.inputPrice
            info.outputPrice = live.outputPrice
        }
        if info.efforts == nil, curated.catalogID == info.id { info.efforts = live.efforts }
        return info
    }

    // MARK: Catalog

    /// Fetches OpenRouter's public model list when it's missing or a day old.
    /// Only once a cloud provider is added: the list prices its models.
    public func refreshCatalogIfNeeded(force: Bool = false) {
        guard !isLoadingCatalog, accounts.contains(where: { $0.provider?.isLocal == false }) else { return }
        if !force, let fetched = catalog?.fetched, Date().timeIntervalSince(fetched) < 24 * 3_600 { return }
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                let models = try await OpenRouterCatalog.fetch()
                catalog = models
                if let catalogFile {
                    try? FileManager.default.createDirectory(at: catalogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? JSONEncoder.iso8601.encode(models).write(to: catalogFile, options: .atomic)
                }
            } catch {
                catalogError = "OpenRouter's model list couldn't be loaded: \(error.localizedDescription)"
                Log.editor.error("Model list: \(error.localizedDescription, privacy: .public)")
            }
            isLoadingCatalog = false
        }
    }

    // MARK: Storage

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: PreferenceKey.aiProviders) }
    }

    private func store(_ value: some Encodable, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<Value: Decodable>(_ type: Value.Type, _ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Settings from before ADR-45: one provider (maybe switched off) and a
    /// cloud transcription service with its own key. Every saved key becomes
    /// an added provider; the old choices become the defaults.
    static func migrate(_ defaults: UserDefaults, savedKeys: Set<String>) -> (accounts: [ProviderAccount], judge: Judge, transcriber: Transcriber) {
        var accounts: [ProviderAccount] = []
        var judge = Judge.rules
        var transcriber = Transcriber.onDevice
        if let data = defaults.data(forKey: PreferenceKey.legacyAIProviderConfiguration),
           let configuration = try? JSONDecoder().decode(ProviderConfiguration.self, from: data),
           let provider = AIProvider.provider(id: configuration.presetID) {
            let customURL = provider.editsURL && configuration.baseURL != provider.chat?.baseURL ? configuration.baseURL : nil
            if !provider.needsKey || savedKeys.contains(provider.id) {
                accounts.append(ProviderAccount(providerID: provider.id, baseURL: customURL))
                if defaults.bool(forKey: PreferenceKey.legacyAIProviderEnabled), !configuration.model.isEmpty {
                    judge = .model(ModelChoice(providerID: provider.id, model: configuration.model, effort: configuration.reasoningEffort))
                }
            }
        }
        for provider in AIProvider.all where savedKeys.contains(provider.id) && !accounts.contains(where: { $0.providerID == provider.id }) {
            accounts.append(ProviderAccount(providerID: provider.id))
        }
        if let raw = defaults.string(forKey: PreferenceKey.legacyCloudTranscriptionService),
           let service = CloudTranscriptionService(rawValue: raw),
           let provider = AIProvider.all.first(where: { $0.transcription == service }),
           savedKeys.contains(provider.id) {
            transcriber = .cloud(providerID: provider.id, model: service.defaultModel)
        }
        let order = AIProvider.all.map(\.id)
        accounts.sort { (order.firstIndex(of: $0.providerID) ?? 0) < (order.firstIndex(of: $1.providerID) ?? 0) }
        return (accounts, judge, transcriber)
    }
}

public extension AISettings {
    /// The cloud request with its key. Reads the key, so call it off the main
    /// actor, when the audio is about to be sent (ADR-41).
    nonisolated static func cloudTranscription(
        service: CloudTranscriptionService, model: String, providerID: String
    ) -> CloudTranscription? {
        apiKey(for: providerID).map { CloudTranscription(service: service, model: model, apiKey: $0) }
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
