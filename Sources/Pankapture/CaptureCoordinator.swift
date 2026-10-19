import AppCore
import AppKit
import Capture
import Observation

/// Routes user intents (shortcuts, menu items) to capture flows and owns
/// post-capture behaviour (copy, save, sound).
@MainActor
@Observable
final class CaptureCoordinator {
    private(set) var lastCaptureURL: URL?
    private(set) var lastErrorMessage: String?
    /// Actions whose shortcut couldn't be registered (taken by another app).
    private(set) var shortcutConflicts: Set<ShortcutAction> = []

    @ObservationIgnored private var isCapturing = false

    // MARK: Shortcuts

    func registerShortcuts() {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        shortcutConflicts = []

        let store = ShortcutStore()
        for action in ShortcutAction.allCases {
            guard let combo = store.combo(for: action) else { continue }
            let result = center.register(combo) { [weak self] in self?.perform(action) }
            if case .failure = result { shortcutConflicts.insert(action) }
        }
    }

    func perform(_ action: ShortcutAction) {
        Log.app.debug("Action: \(action.rawValue, privacy: .public)")
        switch action {
        case .captureArea, .captureFullscreen:
            // M0 walking skeleton: area capture falls back to the display under
            // the cursor. M1 replaces this with the selection overlay + inline editor.
            Task { await captureDisplayUnderCursor() }
        default:
            Log.app.info("\(action.title, privacy: .public) is not implemented yet (see docs/ROADMAP.md)")
            NSSound.beep()
        }
    }

    // MARK: Capture flows

    func captureDisplayUnderCursor() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let snapshots = try await ScreenshotService.snapshotDisplays()
            let targetID = Self.displayIDUnderCursor()
            guard let snapshot = snapshots.first(where: { $0.displayID == targetID }) ?? snapshots.first else { return }
            try deliver(snapshot.image)
            lastErrorMessage = nil
        } catch ScreenshotError.permissionDenied {
            lastErrorMessage = "Pankapture needs Screen Recording permission."
            await Permissions.request(.screenRecording)
        } catch {
            lastErrorMessage = error.localizedDescription
            Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies the user's after-capture preferences.
    private func deliver(_ image: CGImage) throws {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: PreferenceKey.copyToClipboardAfterCapture) {
            try ImageOutput.copyToClipboard(image)
        }
        if defaults.bool(forKey: PreferenceKey.saveAfterCapture) {
            lastCaptureURL = try ImageOutput.write(
                image,
                to: Preferences.saveDirectory(in: defaults),
                format: Preferences.imageFormat(in: defaults)
            )
        }
        if defaults.bool(forKey: PreferenceKey.playSounds) {
            NSSound(named: "Tink")?.play()
        }
    }

    private static func displayIDUnderCursor() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
