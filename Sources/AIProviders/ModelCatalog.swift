import Foundation

/// A model the pickers offer (PRD AI-8): its ID, a readable name, and what
/// it costs, when that's known.
public struct ModelInfo: Codable, Hashable, Identifiable, Sendable {
    /// The ID sent to the API.
    public var id: String
    public var name: String
    /// USD per million input tokens (language models, and token-billed transcription).
    public var inputPrice: Double?
    /// USD per million output tokens.
    public var outputPrice: Double?
    /// USD per hour of audio (transcription billed by the second).
    public var hourPrice: Double?
    /// Reasoning efforts the model accepts; `nil` = unknown (the API's usual list).
    public var efforts: [String]?
    /// The effort auto-edit should send: enough for its judgments, without
    /// paying for long reasoning (AUTO-EDIT §5.2). `nil` = the provider's default.
    public var recommendedEffort: String?
    /// Keeps "um" and stutters (transcription).
    public var isVerbatim: Bool

    public init(
        id: String, name: String, inputPrice: Double? = nil, outputPrice: Double? = nil, hourPrice: Double? = nil,
        efforts: [String]? = nil, recommendedEffort: String? = nil, isVerbatim: Bool = false
    ) {
        self.id = id
        self.name = name
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.hourPrice = hourPrice
        self.efforts = efforts
        self.recommendedEffort = recommendedEffort
        self.isVerbatim = isVerbatim
    }

    /// A 15-minute recording is about 5k input tokens and 1k output tokens
    /// (AUTO-EDIT §5.2); reasoning adds output tokens on top.
    public static let tokensPerRecording = (input: 5_000.0, output: 1_000.0)

    /// What judging one 15-minute recording costs, in USD.
    public var costPerRecording: Double? {
        guard let inputPrice, let outputPrice else { return nil }
        return (inputPrice * Self.tokensPerRecording.input + outputPrice * Self.tokensPerRecording.output) / 1_000_000
    }

    /// "$0.05 in · $0.25 out per 1M tokens", "$0.22 per hour of audio", or `nil`.
    public var priceSummary: String? {
        if let hourPrice { return "\(Self.dollars(hourPrice)) per hour of audio" }
        guard let inputPrice, let outputPrice else { return nil }
        return "\(Self.dollars(inputPrice)) in · \(Self.dollars(outputPrice)) out per 1M tokens"
    }

    /// "≈ $0.0005 per 15-minute recording".
    public var recordingCostSummary: String? {
        if let hourPrice { return "≈ \(Self.dollars(hourPrice / 4)) per 15-minute recording" }
        return costPerRecording.map { "≈ \(Self.dollars($0)) per 15-minute recording" }
    }

    /// Two significant digits for small amounts, cents otherwise; "free" for zero.
    public static func dollars(_ amount: Double) -> String {
        if amount <= 0 { return "free" }
        if amount >= 1 { return String(format: "$%.2f", amount) }
        let digits = max(2, Int(-floor(log10(amount))) + 1)
        var text = String(format: "$%.\(digits)f", amount)
        // "$0.050" → "$0.05", keeping at least cents.
        while text.hasSuffix("0"), let dot = text.firstIndex(of: "."), text.distance(from: dot, to: text.endIndex) > 3 {
            text.removeLast()
        }
        return text
    }
}

/// The models OpenRouter lists, with live prices. The list is public: fetching
/// it sends no key and nothing about the user.
public enum OpenRouterCatalog {
    /// Language models that follow a JSON schema, which auto-edit needs.
    public static let chatURL = URL(string: "https://openrouter.ai/api/v1/models?supported_parameters=structured_outputs")!
    public static let transcriptionURL = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")!

    public struct Models: Codable, Hashable, Sendable {
        public var chat: [ModelInfo]
        public var transcription: [ModelInfo]
        public var fetched: Date

        public init(chat: [ModelInfo], transcription: [ModelInfo], fetched: Date) {
            self.chat = chat
            self.transcription = transcription
            self.fetched = fetched
        }

        public func chatModel(_ id: String) -> ModelInfo? { chat.first { $0.id == id } }
        public func transcriptionModel(_ id: String) -> ModelInfo? { transcription.first { $0.id == id } }
    }

    public static func fetch(session: URLSession = .shared) async throws -> Models {
        async let chat = session.data(from: chatURL)
        async let transcription = session.data(from: transcriptionURL)
        return Models(chat: try parse(try await chat.0, transcription: false),
                      transcription: try parse(try await transcription.0, transcription: true),
                      fetched: Date())
    }

    /// Reads `/api/v1/models`. Prices there are USD per token (or per second
    /// of audio, for transcription models billed by time).
    public static func parse(_ data: Data, transcription: Bool) throws -> [ModelInfo] {
        struct Response: Decodable {
            struct Model: Decodable {
                struct Pricing: Decodable {
                    var prompt: String?
                    var completion: String?
                }
                struct Reasoning: Decodable {
                    var supported_efforts: [String]?
                }
                var id: String
                var name: String?
                var pricing: Pricing?
                var reasoning: Reasoning?
            }
            var data: [Model]
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data.compactMap { model in
            // Batch variants don't answer chat requests; negative prices mark routers.
            guard !model.id.hasSuffix(":batch") else { return nil }
            let prompt = model.pricing?.prompt.flatMap(Double.init)
            let completion = model.pricing?.completion.flatMap(Double.init)
            if let prompt, prompt < 0 { return nil }
            let name = shortName(model.name ?? model.id)
            if transcription, let prompt, (completion ?? 0) == 0 {
                return ModelInfo(id: model.id, name: name, hourPrice: prompt * 3_600)
            }
            return ModelInfo(id: model.id, name: name,
                             inputPrice: prompt.map { $0 * 1_000_000 }, outputPrice: completion.map { $0 * 1_000_000 },
                             efforts: model.reasoning?.supported_efforts.map(ordered))
        }
    }

    /// "OpenAI: GPT-6 Luna" → "GPT-6 Luna" (the pickers show the maker apart).
    static func shortName(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else { return name }
        let rest = name[name.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The maker in a model ID: "openai/gpt-6-luna" → "openai".
    public static func maker(of id: String) -> String {
        id.split(separator: "/").first.map(String.init) ?? id
    }

    /// Efforts from least to most reasoning.
    static func ordered(_ efforts: [String]) -> [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        return efforts.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
    }
}
