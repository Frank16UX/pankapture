import SwiftUI

@main
struct PankaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.coordinator)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.coordinator)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.coordinator)
        }
    }
}
