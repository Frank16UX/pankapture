import Library
import SwiftUI

struct SettingsView: View {
    @Environment(CaptureCoordinator.self) private var coordinator

    @Bindable private var window = SettingsWindow.shared

    var body: some View {
        TabView(selection: $window.tab) {
            Tab("General", systemImage: "gearshape", value: .general) {
                GeneralSettingsView()
            }
            Tab("Screenshots", systemImage: "camera.viewfinder", value: .screenshots) {
                ScreenshotSettingsView()
            }
            Tab("Recording", systemImage: "record.circle", value: .recording) {
                RecordingSettingsView()
            }
            Tab("Shortcuts", systemImage: "command", value: .shortcuts) {
                ShortcutsSettingsView()
            }
            if let library = coordinator.library {
                Tab("History", systemImage: "clock.arrow.circlepath", value: .history) {
                    HistorySettingsView(library: library) { coordinator.showLibrary() }
                }
            }
            Tab("AI", systemImage: "sparkles", value: .ai) {
                AISettingsView()
            }
            Tab("Permissions", systemImage: "lock.shield", value: .permissions) {
                PermissionsSettingsView()
            }
            Tab("Updates", systemImage: "arrow.down.circle", value: .updates) {
                UpdatesSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 520)
        .frame(minHeight: 380)
    }
}
