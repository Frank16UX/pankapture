import SwiftUI

@main
struct PankaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Pankapture", systemImage: "viewfinder") {
            MenuBarContent()
                .environment(appDelegate.coordinator)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.coordinator)
        }
    }
}
