import AIProviders
import AppCore
import AutoEdit
import DesignSystem
import SwiftUI
import Transcription
import VideoEditor

/// Settings ▸ AI (PRD §5.12, AI-8): the providers the user added, each with
/// its key or server, and the defaults every editor starts with. Nothing is
/// used until a provider is added and picked (AI-1).
struct AISettingsView: View {
    @Bindable private var settings = AISettings.shared
    @State private var isAdding = false

    var body: some View {
        Form {
            Section {
                Text("A provider judges pauses and mistakes better than auto-edit's built-in rules, and some transcribe keeping filler words and stutters. Pankapture never pays for AI: use your own key, or a model running on this Mac (free and private).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(settings.accounts) { account in
                if let provider = account.provider {
                    ProviderCard(provider: provider, account: account, settings: settings)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Add Provider…", systemImage: "plus") { isAdding = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(settings.addableProviders.isEmpty)
                    Spacer()
                }
            } footer: {
                Text("Keys are stored in your Keychain, never in settings files or projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                JudgePicker("Auto-edit judged by", judge: Binding(
                    get: { settings.usable(settings.defaultJudge) },
                    set: { settings.defaultJudge = $0 }
                ), settings: settings) { model, providerID in
                    guard let provider = AIProvider.provider(id: providerID) else { return }
                    settings.defaultJudge = .model(ModelChoice(providerID: providerID, model: model.id,
                                                               effort: settings.recommendedEffort(model, provider: provider)))
                }
                TranscriberPicker("Transcription", transcriber: Binding(
                    get: { settings.usable(settings.defaultTranscriber) },
                    set: { settings.defaultTranscriber = $0 }
                ), settings: settings)
            } header: {
                Text("Defaults")
            } footer: {
                Text(defaultsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isAdding) {
            AddProviderSheet(settings: settings)
        }
        .onAppear { settings.refreshCatalogIfNeeded() }
    }

    private var defaultsNote: String {
        var lines = ["Each editor starts with these; change them in its Auto-Edit pane for one recording."]
        if case .model(let choice) = settings.usable(settings.defaultJudge), let provider = AIProvider.provider(id: choice.providerID) {
            lines.append(provider.isLocal
                ? "Auto-edit sends the transcript text and pause timings to \(provider.name) on this Mac. Nothing leaves your Mac."
                : "When you click Analyze, auto-edit sends the transcript text and pause timings to \(provider.name), never audio or video.")
        }
        if case .cloud(let providerID, let modelID) = settings.usable(settings.defaultTranscriber),
           let provider = AIProvider.provider(id: providerID) {
            let model = settings.transcriptionModel(providerID: providerID, model: modelID)
            lines.append("Transcribing sends the recording's microphone audio to \(provider.name).")
            lines.append(model.isVerbatim ? "This model keeps filler words and stutters, so auto-edit finds more of them." : "This model drops most filler words.")
        } else {
            lines.append("Transcription runs on this Mac and sends nothing.")
        }
        return lines.joined(separator: " ")
    }
}

/// One added provider: what it offers, its key or server, and a connection test.
private struct ProviderCard: View {
    let provider: AIProvider
    let account: ProviderAccount
    @Bindable var settings: AISettings

    @State private var keyInput = ""
    @State private var isReplacingKey = false
    @State private var urlInput = ""
    @State private var test: TestState = .idle
    @State private var error: String?

    private enum TestState: Equatable {
        case idle
        case running
        case passed(Double)
        case failed(String)
    }

    private var hasKey: Bool { settings.savedKeys.contains(provider.id) }

    var body: some View {
        Section {
            LabeledContent {
                Button("Remove", role: .destructive) { settings.remove(provider.id) }
                    .help("Remove \(provider.name) and delete its key from the Keychain")
                    .accessibilityLabel("Remove \(provider.name)")
            } label: {
                Text(provider.name).font(.headline)
                Text(provider.offers)
            }

            if provider.editsURL {
                TextField("Server URL", text: $urlInput, prompt: Text(provider.chat?.baseURL.absoluteString ?? "http://localhost:8080/v1"))
                    .onSubmit(saveURL)
                    .onChange(of: urlInput) { _, _ in test = .idle }
            }

            if provider.takesKey {
                if hasKey && !isReplacingKey {
                    LabeledContent("API key") {
                        HStack {
                            Text("Saved in your Keychain").foregroundStyle(.secondary)
                            Button("Replace…") { isReplacingKey = true }
                                .accessibilityLabel("Replace \(provider.name) API key")
                        }
                    }
                } else {
                    HStack {
                        SecureField(provider.needsKey ? "API key" : "API key (optional)", text: $keyInput, prompt: Text("Paste your key"))
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        if isReplacingKey {
                            Button("Cancel") {
                                keyInput = ""
                                isReplacingKey = false
                            }
                        }
                    }
                }
                if provider.needsKey && !hasKey {
                    Label("Needs a key before it can be used.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let error {
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if provider.chat != nil {
                HStack {
                    testStatus
                    Spacer()
                    Button("Test Connection", action: runTest)
                        .disabled(test == .running || !settings.isReady(provider.id))
                }
            }
        }
        .onAppear { urlInput = account.baseURL?.absoluteString ?? provider.chat?.baseURL.absoluteString ?? "" }
    }

    @ViewBuilder private var testStatus: some View {
        switch test {
        case .idle:
            Text(provider.editsURL ? (provider.takesKey ? "Checks the URL, key, and model." : "Checks the URL and model.") : "Checks the key and model.")
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: PK.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Asking \(provider.name)…")
            }
        case .passed(let seconds):
            Label(String(format: "Connected (answered in %.1f s)", seconds), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try settings.setKey(key, for: provider.id)
            keyInput = ""
            isReplacingKey = false
            error = nil
            test = .idle
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveURL() {
        guard let url = URL(string: urlInput.trimmingCharacters(in: .whitespaces)), url.scheme != nil else {
            error = "That isn't a URL. It looks like http://localhost:1234/v1."
            return
        }
        error = nil
        settings.setBaseURL(url, for: provider.id)
    }

    /// Tests with the model the defaults use for this provider, else its first one.
    private func runTest() {
        if provider.editsURL { saveURL() }
        let choice: ModelChoice = if case .model(let choice) = settings.defaultJudge, choice.providerID == provider.id {
            choice
        } else {
            ModelChoice(providerID: provider.id, model: settings.chatModels(for: provider.id).first?.id ?? provider.chat?.defaultModel ?? "",
                        effort: settings.chatModels(for: provider.id).first.flatMap { settings.recommendedEffort($0, provider: provider) })
        }
        guard let configuration = settings.configuration(for: choice) else {
            test = .failed("Choose a model first: it has none to test with.")
            return
        }
        let providerID = provider.id
        test = .running
        Task {
            do {
                // Off the main actor: the first read after an update can wait on a Keychain prompt (ADR-41).
                let key = await Task.detached { AISettings.apiKey(for: providerID) }.value
                let seconds = try await LanguageModelClient().testConnection(configuration: configuration, apiKey: key)
                test = .passed(seconds)
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}

/// Add Provider: pick one, paste its key (or a server URL for one on this Mac).
private struct AddProviderSheet: View {
    @Bindable var settings: AISettings

    @Environment(\.dismiss) private var dismiss
    @State private var providerID = ""
    @State private var key = ""
    @State private var url = ""
    @State private var error: String?

    private var provider: AIProvider? { AIProvider.provider(id: providerID) }

    private var canAdd: Bool {
        guard let provider else { return false }
        if provider.needsKey, key.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if provider.editsURL, URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme == nil { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Provider", selection: $providerID) {
                        ForEach(settings.addableProviders) { provider in
                            Text(provider.name).tag(provider.id)
                        }
                    }
                    .onChange(of: providerID) { _, _ in
                        key = ""
                        url = provider?.chat?.baseURL.absoluteString ?? ""
                        error = nil
                    }
                    if let provider {
                        Text(provider.offers)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Add a Provider")
                }

                if let provider {
                    Section {
                        if provider.editsURL {
                            TextField("Server URL", text: $url, prompt: Text(provider.chat?.baseURL.absoluteString ?? ""))
                        }
                        if provider.takesKey {
                            SecureField(provider.needsKey ? "API key" : "API key (optional)", text: $key, prompt: Text("Paste your key"))
                                .onSubmit(add)
                        }
                        if let keysURL = provider.keysURL {
                            Link("Get a key from \(provider.name)", destination: keysURL)
                                .font(.caption)
                        }
                        if let error {
                            Label(error, systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } footer: {
                        Text(note(for: provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Provider", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(PK.Spacing.l)
        }
        .frame(width: PK.Metrics.listSheetSize.width * 0.75)
        .onAppear {
            providerID = settings.addableProviders.first?.id ?? ""
            url = provider?.chat?.baseURL.absoluteString ?? ""
        }
    }

    private func note(for provider: AIProvider) -> String {
        if provider.isLocal {
            return "Start \(provider.name)'s server and load a model first. Requests stay on this Mac."
        }
        var parts = ["The key is stored in your Keychain."]
        if provider.chat != nil { parts.append("Auto-edit sends it only the transcript text and pause timings.") }
        if provider.transcription != nil { parts.append("Transcribing with it sends the microphone audio, only when you choose it.") }
        return parts.joined(separator: " ")
    }

    private func add() {
        guard canAdd, let provider else { return }
        do {
            let baseURL = provider.editsURL ? URL(string: url.trimmingCharacters(in: .whitespaces)) : nil
            try settings.add(provider, key: key, baseURL: baseURL)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
