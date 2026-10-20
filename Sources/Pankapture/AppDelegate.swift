import AppCore
import AppKit
import DesignSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = CaptureCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()

        // Menu bar utility: no Dock icon. Info.plist sets LSUIElement for the
        // bundled app; this also covers `swift run` during development.
        NSApp.setActivationPolicy(.accessory)

        let stored = UserDefaults.standard.string(forKey: PreferenceKey.appearance)
        (stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system).apply()

        coordinator.start()
        CaptureNotifier.shared.configure()

        if Permissions.status(.screenRecording) != .granted {
            Log.permissions.notice("Screen Recording not granted yet; first capture will prompt.")
        }
        Log.app.info("Pankapture launched")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLCommands.handle(url, coordinator: coordinator) }
    }
}
