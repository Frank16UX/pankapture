import Library
import SwiftUI

struct SettingsView: View {
    @Environment(CaptureCoordinator.self) private var coordinator

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsView()
            }
            Tab("Screenshots", systemImage: "camera.viewfinder") {
                ScreenshotSettingsView()
            }
            Tab("Recording", systemImage: "record.circle") {
                RecordingSettingsView()
            }
            Tab("Shortcuts", systemImage: "command") {
                ShortcutsSettingsView()
            }
            if let library = coordinator.library {
                Tab("History", systemImage: "clock.arrow.circlepath") {
                    HistorySettingsView(library: library) { coordinator.showLibrary() }
                }
            }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsSettingsView()
            }
            Tab("Updates", systemImage: "arrow.down.circle") {
                UpdatesSettingsView()
            }
        }
        .scenePadding()
        .frame(width: 520)
        .frame(minHeight: 380)
    }
}
