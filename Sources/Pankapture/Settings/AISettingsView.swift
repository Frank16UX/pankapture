import AIProviders
import AppCore
import AutoEdit
import DesignSystem
import SwiftUI
import Transcription

/// Settings ▸ AI (PRD §5.12): an optional provider for auto-edit's judgments,
/// with the user's own key or a model on this Mac. Off by default (AI-1).
struct AISettingsView: View {
    @AppStorage(PreferenceKey.aiProviderEnabled) private var isEnabled = false

    @State private var presetID = ProviderSettings.configuration?.presetID ?? ProviderPreset.lmStudio.id
    @State private var model = ProviderSettings.configuration?.model ?? ProviderPreset.lmStudio.defaultModel
    @State private var baseURL = ProviderSettings.configuration?.baseURL.absoluteString ?? ProviderPreset.lmStudio.baseURL.absoluteString
    @State private var effort = ProviderSettings.configuration?.reasoningEffort ?? ""
    @State private var keyInput = ""
    @State private var hasStoredKey = false
    @State private var test: TestState = .idle
    @State private var cloudService = CloudTranscriptionSettings.service
    @State private var cloudKeyInput = ""
    @State private var hasCloudKey = false

    private enum TestState: Equatable {
        case idle
        case running
        case passed(Double)
        case failed(String)
    }

    private var preset: ProviderPreset { ProviderPreset.preset(id: presetID) ?? .lmStudio }
    /// Only local servers and custom endpoints have a URL worth editing.
    private var editsURL: Bool { preset.isLocal || preset.id == ProviderPreset.custom.id }

    private var configuration: ProviderConfiguration? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespaces)
        return ProviderConfiguration(preset: preset, model: trimmedModel, baseURL: url, reasoningEffort: .some(effort.isEmpty ? nil : effort))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Use an AI provider for auto-edit", isOn: $isEnabled)
            } footer: {
                Text("Without one, auto-edit's built-in rules judge pauses and mistakes on this Mac. A provider judges them better. Pankapture never pays for AI: use your own key, or a model running on this Mac (free and private).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Picker("Provider", selection: $presetID) {
                    ForEach(ProviderPreset.all) { preset in
                        Text(preset.isLocal ? "\(preset.name) (on this Mac)" : preset.name).tag(preset.id)
                    }
                }
                .onChange(of: presetID) { _, _ in applyPresetDefaults() }

                TextField("Model", text: $model, prompt: Text(preset.defaultModel.isEmpty ? "model name" : preset.defaultModel))
                if editsURL {
                    TextField("Server URL", text: $baseURL, prompt: Text(preset.baseURL.absoluteString))
                }
                Picker("Reasoning effort", selection: $effort) {
                    Text("Provider default").tag("")
                    ForEach(effortOptions, id: \.self) { Text($0).tag($0) }
                }

                if preset.needsKey || preset.id == ProviderPreset.custom.id {
                    HStack {
                        SecureField(hasStoredKey ? "Saved in your Keychain" : "API key", text: $keyInput)
                        Button(hasStoredKey && keyInput.isEmpty ? "Remove" : "Save") { saveKey() }
                            .disabled(keyInput.isEmpty && !hasStoredKey)
                    }
                }
            }
            .disabled(!isEnabled)
            .onChange(of: model) { _, _ in persist() }
            .onChange(of: baseURL) { _, _ in persist() }
            .onChange(of: effort) { _, _ in persist() }

            Section {
                Picker("Service", selection: $cloudService) {
                    Text("Off: transcribe on this Mac").tag(CloudTranscriptionService?.none)
                    ForEach(CloudTranscriptionService.allCases) { Text($0.name).tag(Optional($0)) }
                }
                .onChange(of: cloudService) { _, service in
                    CloudTranscriptionSettings.service = service
                    cloudKeyInput = ""
                    hasCloudKey = service.map { APIKeyStore.key(for: $0.keyAccount) != nil } ?? false
                }
                if let service = cloudService {
                    HStack {
                        SecureField(hasCloudKey ? "Saved in your Keychain" : "\(service.name) API key", text: $cloudKeyInput)
                        Button(hasCloudKey && cloudKeyInput.isEmpty ? "Remove" : "Save") {
                            try? APIKeyStore.setKey(cloudKeyInput, for: service.keyAccount)
                            cloudKeyInput = ""
                            hasCloudKey = APIKeyStore.key(for: service.keyAccount) != nil
                        }
                        .disabled(cloudKeyInput.isEmpty && !hasCloudKey)
                    }
                }
            } header: {
                Text("Cloud Transcription")
            } footer: {
                Text(cloudNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    testStatus
                    Spacer()
                    Button("Test Connection") { runTest() }
                        .disabled(!isEnabled || configuration == nil || test == .running)
                }
            } footer: {
                Text(privacyNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            hasStoredKey = APIKeyStore.key(for: presetID) != nil
            hasCloudKey = cloudService.map { APIKeyStore.key(for: $0.keyAccount) != nil } ?? false
            persist()
        }
    }

    private var cloudNote: String {
        guard let service = cloudService else {
            return "Transcription runs on this Mac and nothing is sent. A cloud service can catch filler words and stutters the on-device one drops; it receives the recording's microphone audio."
        }
        let fillers = service.isVerbatim
            ? "It keeps filler words and stutters, so auto-edit finds more of them."
            : "It's inexpensive but drops most filler words."
        return "When you analyze a recording, its microphone audio is sent to \(service.name). \(fillers) The key is stored in your Keychain."
    }

    private var effortOptions: [String] {
        switch preset.api {
        case .anthropic: ["low", "medium", "high"]
        case .openAICompatible: ["none", "low", "medium", "high"]
        }
    }

    private var privacyNote: String {
        if preset.isLocal {
            return "Auto-edit sends the transcript text and pause timings to \(preset.name) on this Mac when you click Analyze. Nothing leaves your Mac."
        }
        return "When you click Analyze, auto-edit sends the transcript text and pause timings to \(preset.name), never audio or video. The key is stored in your Keychain."
    }

    @ViewBuilder private var testStatus: some View {
        switch test {
        case .idle:
            Text("Checks the URL, key, and model.").foregroundStyle(.secondary)
        case .running:
            HStack(spacing: PK.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Asking \(preset.name)…")
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

    private func applyPresetDefaults() {
        model = preset.defaultModel
        baseURL = preset.baseURL.absoluteString
        effort = preset.defaultReasoningEffort ?? ""
        keyInput = ""
        hasStoredKey = APIKeyStore.key(for: presetID) != nil
        test = .idle
        persist()
    }

    private func persist() {
        if let configuration { ProviderSettings.configuration = configuration }
    }

    private func saveKey() {
        do {
            try APIKeyStore.setKey(keyInput, for: presetID)
            keyInput = ""
            hasStoredKey = APIKeyStore.key(for: presetID) != nil
            test = .idle
        } catch {
            test = .failed(error.localizedDescription)
        }
    }

    private func runTest() {
        guard let configuration else { return }
        persist()
        let key = APIKeyStore.key(for: presetID)
        test = .running
        Task {
            do {
                let seconds = try await LanguageModelClient().testConnection(configuration: configuration, apiKey: key)
                test = .passed(seconds)
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
