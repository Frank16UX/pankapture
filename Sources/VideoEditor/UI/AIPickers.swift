import AIProviders
import AutoEdit
import DesignSystem
import SwiftUI

// Pickers for what judges and transcribes auto-edit (PRD AI-8): the editor's
// Analyze section uses them for one recording, Settings ▸ AI for the defaults.

/// The chosen model's price under its picker; the menus show names only,
/// and More Models… compares prices.
private struct PriceRow: View {
    let model: ModelInfo

    var body: some View {
        if let price = model.priceSummary {
            LabeledContent("Price") {
                VStack(alignment: .trailing, spacing: PK.Spacing.xxs) {
                    Text(price)
                    if let cost = model.recordingCostSummary {
                        Text(cost).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A model in a picker, without its effort.
private struct ModelKey: Hashable {
    var providerID: String
    var model: String
}

/// "Judged by": the built-in rules or a model from an added provider, with
/// its reasoning effort, and a browser for every model OpenRouter lists.
public struct JudgePicker: View {
    let title: String
    @Binding var judge: Judge
    @Bindable var settings: AISettings
    /// Picks a model with the effort recommended for it.
    let pick: (ModelInfo, String) -> Void

    @State private var isBrowsing = false

    public init(_ title: String, judge: Binding<Judge>, settings: AISettings, pick: @escaping (ModelInfo, String) -> Void) {
        self.title = title
        _judge = judge
        self.settings = settings
        self.pick = pick
    }

    private var choice: ModelChoice? {
        if case .model(let choice) = judge { choice } else { nil }
    }

    private var selection: Binding<ModelKey?> {
        Binding {
            choice.map { ModelKey(providerID: $0.providerID, model: $0.model) }
        } set: { key in
            guard let key else {
                judge = .rules
                return
            }
            pick(settings.chatModel(ModelChoice(providerID: key.providerID, model: key.model)), key.providerID)
        }
    }

    /// The curated models, and the chosen one when it came from the browser.
    private func models(for provider: AIProvider) -> [ModelInfo] {
        var models = settings.chatModels(for: provider.id)
        if let choice, choice.providerID == provider.id, !models.contains(where: { $0.id == choice.model }) {
            models.append(settings.chatModel(choice))
        }
        return models
    }

    public var body: some View {
        Picker(title, selection: selection) {
            Text("Built-in rules (on this Mac)").tag(ModelKey?.none)
            ForEach(settings.chatProviders) { provider in
                Section(provider.name) {
                    ForEach(models(for: provider)) { model in
                        Text(model.name).tag(Optional(ModelKey(providerID: provider.id, model: model.id)))
                    }
                }
            }
        }

        if let choice, let provider = AIProvider.provider(id: choice.providerID) {
            let info = settings.chatModel(choice)
            let efforts = provider.efforts(for: info)
            if !efforts.isEmpty {
                Picker("Reasoning effort", selection: Binding(
                    get: { choice.effort ?? "" },
                    set: { value in
                        var changed = choice
                        changed.effort = value.isEmpty ? nil : value
                        judge = .model(changed)
                    }
                )) {
                    Text("Provider default").tag("")
                    ForEach(efforts, id: \.self) { Text($0).tag($0) }
                }
                .help("More reasoning can judge better, but takes longer and bills more output tokens.")
            }
            PriceRow(model: info)
        }

        if !settings.chatProviders.isEmpty {
            Button("More Models…", systemImage: "list.bullet.rectangle") {
                settings.refreshCatalogIfNeeded()
                isBrowsing = true
            }
            .help("Every model your providers offer, with prices, or any model ID")
            .sheet(isPresented: $isBrowsing) {
                ModelBrowser(settings: settings, current: choice) { model, providerID in
                    pick(model, providerID)
                }
            }
        }
    }
}

/// "Transcription": on this Mac, or a model from an added provider that
/// transcribes. A cloud one receives the microphone audio (AI-5).
public struct TranscriberPicker: View {
    let title: String
    @Binding var transcriber: Transcriber
    @Bindable var settings: AISettings

    public init(_ title: String, transcriber: Binding<Transcriber>, settings: AISettings) {
        self.title = title
        _transcriber = transcriber
        self.settings = settings
    }

    public var body: some View {
        Picker(title, selection: $transcriber) {
            Text("On this Mac").tag(Transcriber.onDevice)
            ForEach(settings.transcriptionProviders) { provider in
                Section(provider.name) {
                    ForEach(models(for: provider)) { model in
                        Text(model.name).tag(Transcriber.cloud(providerID: provider.id, model: model.id))
                    }
                }
            }
        }
        if case .cloud(let providerID, let model) = settings.usable(transcriber) {
            PriceRow(model: settings.transcriptionModel(providerID: providerID, model: model))
        }
    }

    private func models(for provider: AIProvider) -> [ModelInfo] {
        var models = settings.transcriptionModels(for: provider.id)
        if case .cloud(let id, let model) = transcriber, id == provider.id, !models.contains(where: { $0.id == model }) {
            models.append(settings.transcriptionModel(providerID: id, model: model))
        }
        return models
    }
}

/// Every language model the added providers offer, with prices, searchable
/// and sortable; or any model ID typed in (AI-2: the model is always editable).
struct ModelBrowser: View {
    @Bindable var settings: AISettings
    let current: ModelChoice?
    let pick: (ModelInfo, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var providerID = ""
    @State private var search = ""
    @State private var selectedID: String?
    @State private var typedID = ""
    /// Empty until a column is clicked: the recommended models come first.
    @State private var sortOrder: [KeyPathComparator<Row>] = []

    struct Row: Identifiable {
        var info: ModelInfo
        var isRecommended: Bool
        var id: String { info.id }
        var name: String { info.name }
        /// Unknown prices sort last.
        var input: Double { info.inputPrice ?? .infinity }
        var output: Double { info.outputPrice ?? .infinity }
        var perRecording: Double { info.costPerRecording ?? .infinity }
    }

    private var provider: AIProvider? { AIProvider.provider(id: providerID) }

    private var rows: [Row] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let recommended = Set(settings.chatModels(for: providerID).map(\.id))
        let rows = settings.allChatModels(for: providerID)
            .filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.id.lowercased().contains(query) }
            .map { Row(info: $0, isRecommended: recommended.contains($0.id)) }
        return sortOrder.isEmpty ? rows : rows.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            HStack {
                if settings.chatProviders.count > 1 {
                    Picker("Provider", selection: $providerID) {
                        ForEach(settings.chatProviders) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                }
                TextField("Search models", text: $search)
                    .textFieldStyle(.roundedBorder)
            }

            Table(rows, selection: $selectedID, sortOrder: $sortOrder) {
                TableColumn("Model", value: \.name) { row in
                    VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                        Text(row.name)
                        Text(row.isRecommended ? "\(row.id) · Recommended" : row.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TableColumn("Input / 1M", value: \.input) { row in
                    Text(row.info.inputPrice.map(ModelInfo.dollars) ?? "—").monospacedDigit()
                }
                .width(80)
                TableColumn("Output / 1M", value: \.output) { row in
                    Text(row.info.outputPrice.map(ModelInfo.dollars) ?? "—").monospacedDigit()
                }
                .width(80)
                TableColumn("15 min", value: \.perRecording) { row in
                    Text(row.info.costPerRecording.map(ModelInfo.dollars) ?? "—").monospacedDigit()
                }
                .width(70)
            }
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                if let id = ids.first { choose(id) }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Or a model ID", text: $typedID, prompt: Text(typedPrompt))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { chooseTyped() }
                Button("Use ID") { chooseTyped() }
                    .disabled(typedID.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose") { selectedID.map(choose) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil)
            }
        }
        .padding(PK.Spacing.l)
        .frame(width: PK.Metrics.listSheetSize.width, height: PK.Metrics.listSheetSize.height)
        .onAppear {
            providerID = current?.providerID ?? settings.chatProviders.first(where: \.browsesCatalog)?.id ?? settings.chatProviders.first?.id ?? ""
            selectedID = current?.providerID == providerID ? current?.model : nil
        }
    }

    private var typedPrompt: String {
        let model = provider?.chat?.defaultModel ?? ""
        return model.isEmpty ? "model ID" : model
    }

    private var footnote: String {
        var lines = ["“15 min” estimates one 15-minute recording (about 5k tokens in and 1k out, before reasoning)."]
        if provider?.browsesCatalog == true {
            if settings.isLoadingCatalog { lines.append("Loading OpenRouter's models…") }
            if let error = settings.catalogError { lines.append(error) }
            lines.append("Lists every OpenRouter model that can answer in auto-edit's JSON format, at OpenRouter's current prices.")
        } else if provider?.isLocal == false {
            lines.append("Prices are the maker's, from OpenRouter's public list.")
        }
        return lines.joined(separator: " ")
    }

    private func choose(_ id: String) {
        guard let info = settings.allChatModels(for: providerID).first(where: { $0.id == id }) else { return }
        pick(info, providerID)
        dismiss()
    }

    private func chooseTyped() {
        let id = typedID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        pick(settings.chatModel(ModelChoice(providerID: providerID, model: id)), providerID)
        dismiss()
    }
}
