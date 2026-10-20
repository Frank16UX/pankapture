import AppCore
import AppKit
import DesignSystem

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = CaptureCoordinator()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One instance only: a second copy (another build, or a second
        // install location) would fight over the global hot keys.
        if handOffToRunningInstance() { exit(0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()

        // Menu bar utility: no Dock icon until a standard window opens.
        // Info.plist sets LSUIElement for the bundled app; this also covers
        // `swift run` during development.
        DockPresence.shared.start()
        DistributedNotificationCenter.default().addObserver(
            forName: .showSettingsRequest, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in SettingsWindow.show() }
        }

        let stored = UserDefaults.standard.string(forKey: PreferenceKey.appearance)
        (stored.flatMap(AppearanceMode.init(rawValue:)) ?? .system).apply()

        coordinator.start()
        CaptureNotifier.shared.configure()
        OnboardingWindow.showIfNeeded()

        if Permissions.status(.screenRecording) != .granted {
            Log.permissions.notice("Screen Recording not granted yet; first capture will prompt.")
        }
        Log.app.info("Pankapture launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush unsaved video edits.
        coordinator.videoEditor.closeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLCommands.handle(url, coordinator: coordinator) }
    }

    /// Opening the app again (Finder, Spotlight, Dock) with no window shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindow.show() }
        return true
    }

    /// If another instance is running, passes focus to it, asks it to show
    /// Settings, and returns true so this one exits before creating anything.
    private func handOffToRunningInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ownPID }) else { return false }
        Log.app.notice("Another instance is running (pid \(running.processIdentifier)); handing off.")
        NSApp.yieldActivation(to: running)
        DistributedNotificationCenter.default().postNotificationName(
            .showSettingsRequest, object: nil, userInfo: nil, deliverImmediately: true
        )
        return true
    }
}

private extension Notification.Name {
    static let showSettingsRequest = Notification.Name("com.franklinperez.Pankapture.showSettings")
}
