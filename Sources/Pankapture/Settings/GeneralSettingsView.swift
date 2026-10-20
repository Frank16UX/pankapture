import AppCore
import DesignSystem
import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(PreferenceKey.playSounds) private var playSounds = true
    @AppStorage(PreferenceKey.showNotifications) private var showNotifications = true
    @AppStorage(PreferenceKey.saveDirectory) private var saveDirectory = Preferences.defaultSaveDirectory.path
    @AppStorage(PreferenceKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PreferenceKey.copyToClipboardAfterCapture) private var copyAfterCapture = true
    @AppStorage(PreferenceKey.saveAfterCapture) private var saveAfterCapture = true

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, newValue in
                    withAnimation(PK.Motion.standard) {
                        (AppearanceMode(rawValue: newValue) ?? .system).apply()
                    }
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }

                Toggle("Play sounds", isOn: $playSounds)
            }

            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $copyAfterCapture)
                Toggle("Save to folder", isOn: $saveAfterCapture)
                Toggle("Show a notification", isOn: $showNotifications)
            }

            Section("Output") {
                LabeledContent("Save to") {
                    HStack(spacing: PK.Spacing.s) {
                        Text(abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Image format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var abbreviatedPath: String {
        (saveDirectory as NSString).abbreviatingWithTildeInPath
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (saveDirectory as NSString).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Fails when running outside an .app bundle (e.g. `swift run`).
            launchAtLoginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
