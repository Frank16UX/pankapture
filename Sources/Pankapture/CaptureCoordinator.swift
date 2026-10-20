import Annotation
import AppCore
import AppKit
import Capture
import Observation
import Overlay

/// Routes user intents (shortcuts, menu items, URLs) to capture flows and owns
/// post-capture behaviour (copy, save, sound, history).
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
        case .captureArea:
            Task { await captureArea() }
        case .capturePreviousArea:
            Task { await captureArea(usePreviousArea: true) }
        case .captureFullscreen:
            Task { await captureDisplayUnderCursor() }
        default:
            Log.app.info("\(action.title, privacy: .public) is not implemented yet (see docs/ROADMAP.md)")
            NSSound.beep()
        }
    }

    // MARK: Area capture (SC-1…SC-5, AN-*, OUT-*)

    /// - Parameter preselect: initial selection in display-local points on the display under the cursor.
    func captureArea(usePreviousArea: Bool = false, preselect: CGRect? = nil) async {
        guard !isCapturing, OverlayController.current == nil else { return }
        isCapturing = true
        defer { isCapturing = false }

        let signpost = Log.signposter.beginInterval("hotkey → overlay")
        let windows = WindowList.onScreenWindows()
        guard let snapshots = await takeSnapshots() else {
            Log.signposter.endInterval("hotkey → overlay", signpost)
            return
        }

        var initial: (displayID: CGDirectDisplayID, rect: CGRect)?
        if usePreviousArea, let last = LastSelection.load() {
            initial = (last.displayID, last.rect)
        } else if let preselect, let displayID = Self.displayIDUnderCursor() {
            initial = (displayID, preselect)
        }

        OverlayController.present(snapshots: snapshots, windows: windows, mode: .annotate, preselect: initial) { [weak self] outcome in
            self?.handle(outcome)
        }
        Log.signposter.endInterval("hotkey → overlay", signpost)
    }

    private func handle(_ outcome: OverlayOutcome) {
        guard case let .output(action, result) = outcome else { return }
        switch action {
        case .copy:
            OutputService.copy(result.image)
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: nil, copied: true, image: result.image)
        case .save:
            let url = OutputService.save(result.image)
            if let url { lastCaptureURL = url }
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: url, copied: false, image: result.image)
        case .saveAs:
            if let url = OutputService.saveAs(result.image) {
                lastCaptureURL = url
                CaptureNotifier.shared.notify(savedURL: url, copied: false, image: result.image)
            }
        case .print:
            OutputService.print(result.image, scale: result.scale)
        case .done:
            deliver(result.image)
        case .pin:
            OutputService.copy(result.image)
        case .shared:
            break
        }
    }

    // MARK: Fullscreen capture

    func captureDisplayUnderCursor() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let snapshots = await takeSnapshots() else { return }
        let targetID = Self.displayIDUnderCursor()
        guard let snapshot = snapshots.first(where: { $0.displayID == targetID }) ?? snapshots.first else { return }
        deliver(snapshot.image)
    }

    // MARK: Helpers

    private func takeSnapshots() async -> [DisplaySnapshot]? {
        do {
            let snapshots = try await ScreenshotService.snapshotDisplays()
            lastErrorMessage = nil
            return snapshots
        } catch ScreenshotError.permissionDenied {
            lastErrorMessage = "Pankapture needs Screen Recording permission."
            await Permissions.request(.screenRecording)
        } catch {
            lastErrorMessage = error.localizedDescription
            Log.capture.error("Capture failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Applies the user's after-capture preferences (GL-9).
    private func deliver(_ image: CGImage) {
        let defaults = UserDefaults.standard
        let copies = defaults.bool(forKey: PreferenceKey.copyToClipboardAfterCapture)
        if copies {
            OutputService.copy(image)
        }
        var savedURL: URL?
        if defaults.bool(forKey: PreferenceKey.saveAfterCapture) {
            savedURL = OutputService.save(image)
            if let savedURL { lastCaptureURL = savedURL }
        }
        OutputService.playCaptureSound()
        CaptureNotifier.shared.notify(savedURL: savedURL, copied: copies, image: image)
    }

    static func displayIDUnderCursor() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID
    }
}
