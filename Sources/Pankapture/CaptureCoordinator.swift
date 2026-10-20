import Annotation
import AppCore
import AppKit
import Capture
import Library
import Observation
import Overlay
import QuickAccess

/// Routes user intents (shortcuts, menu items, URLs) to capture flows and owns
/// post-capture behaviour: output actions, history, thumbnails, pins, editor.
@MainActor
@Observable
final class CaptureCoordinator {
    private(set) var lastCaptureURL: URL?
    private(set) var lastErrorMessage: String?
    /// Actions whose shortcut couldn't be registered (taken by another app).
    private(set) var shortcutConflicts: Set<ShortcutAction> = []

    /// Capture history (nil only if the store couldn't be opened).
    @ObservationIgnored let library: CaptureLibrary?
    @ObservationIgnored private var libraryWindowController: LibraryWindowController?
    @ObservationIgnored private var isCapturing = false
    /// The app that was frontmost when the capture started (for history).
    @ObservationIgnored private var sourceAppName: String?

    init() {
        do {
            library = try CaptureLibrary()
        } catch {
            Log.library.error("Capture history unavailable: \(error.localizedDescription, privacy: .public)")
            library = nil
        }
    }

    /// Call once at launch.
    func start() {
        library?.start()
        registerShortcuts()

        PinController.shared.onAction = { [weak self] action, image, scale in
            self?.handlePin(action, image: image, scale: scale)
        }
        QuickAccessController.shared.onAction = { [weak self] action, item in
            self?.handleThumbnail(action, item: item)
        }
    }

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
            Task { await captureFullscreen() }
        case .captureWindow:
            Task { await captureWindow() }
        case .captureText:
            Task { await captureText() }
        case .openHistory:
            showLibrary()
        default:
            Log.app.info("\(action.title, privacy: .public) is not implemented yet (see docs/ROADMAP.md)")
            NSSound.beep()
        }
    }

    /// Self-timer (SC-9): count down, then open the area overlay, so menus and
    /// hover states opened during the countdown are frozen in the capture.
    func captureAreaAfterDelay(_ seconds: Int) {
        CountdownHUD.run(seconds: seconds) { [weak self] in
            Task { await self?.captureArea() }
        }
    }

    // MARK: Area capture (SC-1…SC-5, AN-*, OUT-*)

    /// - Parameter preselect: initial selection in display-local points on the display under the cursor.
    func captureArea(usePreviousArea: Bool = false, preselect: CGRect? = nil) async {
        guard !isCapturing, OverlayController.current == nil else { return }
        isCapturing = true
        defer { isCapturing = false }

        let signpost = Log.signposter.beginInterval("hotkey → overlay")
        rememberSourceApp()
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
        switch outcome {
        case let .cancelled(discarded?):
            // Closed without saving: still recoverable from history (OUT-8).
            Task { await record(original: discarded.original, scale: discarded.scale, annotations: discarded.annotations,
                                exportedURL: nil, discarded: true) }
        case let .output(action, result):
            let capture = Capture(image: result.image, original: result.original, annotations: result.annotations,
                                  scale: result.scale, screenRect: result.screenRect)
            apply(action, to: capture)
        default:
            break
        }
    }

    // MARK: Window capture (SC-6)

    func captureWindow() async {
        guard !isCapturing, OverlayController.current == nil else { return }
        isCapturing = true
        defer { isCapturing = false }

        rememberSourceApp()
        let windows = WindowList.onScreenWindows()
        guard let snapshots = await takeSnapshots() else { return }
        OverlayController.present(snapshots: snapshots, windows: windows, mode: .pickWindow) { [weak self] outcome in
            guard case let .pickedWindow(window) = outcome else { return }
            Task { await self?.finishWindowCapture(window) }
        }
    }

    private func finishWindowCapture(_ window: WindowInfo) async {
        let defaults = UserDefaults.standard
        do {
            let (image, scale) = try await ScreenshotService.captureWindow(
                id: window.id,
                includeShadow: defaults.bool(forKey: PreferenceKey.windowCaptureShadow),
                showsCursor: defaults.bool(forKey: PreferenceKey.captureShowsCursor)
            )
            await deliverStill(Capture(image: image, original: image, annotations: AnnotationDocument(), scale: scale, screenRect: nil))
        } catch {
            Log.capture.error("Window capture failed: \(error.localizedDescription, privacy: .public)")
            lastErrorMessage = "Couldn't capture that window."
            NSSound.beep()
        }
    }

    // MARK: Fullscreen capture (SC-7)

    func captureFullscreen() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        rememberSourceApp()
        guard let snapshots = await takeSnapshots() else { return }
        let targets: [DisplaySnapshot]
        if UserDefaults.standard.bool(forKey: PreferenceKey.fullscreenAllDisplays) {
            targets = snapshots
        } else {
            let targetID = Self.displayIDUnderCursor()
            targets = [snapshots.first { $0.displayID == targetID } ?? snapshots[0]]
        }
        for snapshot in targets {
            await deliverStill(Capture(image: snapshot.image, original: snapshot.image, annotations: AnnotationDocument(),
                                       scale: snapshot.scale, screenRect: nil))
        }
    }

    // MARK: Capture text / OCR (SC-12)

    func captureText() async {
        guard !isCapturing, OverlayController.current == nil else { return }
        isCapturing = true
        defer { isCapturing = false }

        let windows = WindowList.onScreenWindows()
        guard let snapshots = await takeSnapshots() else { return }
        OverlayController.present(snapshots: snapshots, windows: windows, mode: .pick(confirmTitle: nil)) { outcome in
            guard case let .picked(area) = outcome, let image = area.image else { return }
            Task {
                do {
                    let text = try await TextRecognizer.recognizeText(in: image)
                    if text.isEmpty {
                        CaptureNotifier.shared.notifyText(nil)
                        NSSound.beep()
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        OutputService.playCaptureSound()
                        CaptureNotifier.shared.notifyText(text)
                    }
                } catch {
                    Log.capture.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: Output

    /// A finished still capture on its way out.
    struct Capture {
        /// Final pixels (annotations burned in).
        var image: CGImage
        /// Without annotations, for re-editing.
        var original: CGImage
        /// Capture-local points.
        var annotations: AnnotationDocument
        var scale: CGFloat
        /// Where it was on screen (AppKit global), to pin in place.
        var screenRect: CGRect?
        /// History item, when this is a re-edit.
        var libraryID: UUID?
    }

    private func apply(_ action: OutputAction, to capture: Capture) {
        switch action {
        case .copy:
            OutputService.copy(capture.image)
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: nil, copied: true, image: capture.image)
            Task { await record(capture, exportedURL: nil) }
        case .save:
            let url = OutputService.save(capture.image)
            if let url { lastCaptureURL = url }
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: url, copied: false, image: capture.image)
            Task { await record(capture, exportedURL: url) }
        case .saveAs:
            let url = OutputService.saveAs(capture.image)
            if let url {
                lastCaptureURL = url
                CaptureNotifier.shared.notify(savedURL: url, copied: false, image: capture.image)
            }
            Task { await record(capture, exportedURL: url) }
        case .print:
            OutputService.print(capture.image, scale: capture.scale)
            Task { await record(capture, exportedURL: nil) }
        case .pin:
            PinController.shared.pin(capture.image, scale: capture.scale, at: capture.screenRect)
            Task { await record(capture, exportedURL: nil) }
        case .done:
            Task { await deliverStill(capture, showsThumbnail: false) }
        case .openEditor:
            Task {
                let id = await record(capture, exportedURL: nil)
                openEditor(original: capture.original, scale: capture.scale, annotations: capture.annotations, libraryID: id)
            }
        case .shared:
            Task { await record(capture, exportedURL: nil) }
        }
    }

    /// Applies the after-capture preferences (GL-9): copy, save, thumbnail, editor.
    private func deliverStill(_ capture: Capture, showsThumbnail: Bool = true) async {
        let defaults = UserDefaults.standard
        let copies = defaults.bool(forKey: PreferenceKey.copyToClipboardAfterCapture)
        if copies {
            OutputService.copy(capture.image)
        }
        var savedURL: URL?
        if defaults.bool(forKey: PreferenceKey.saveAfterCapture) {
            savedURL = OutputService.save(capture.image)
            if let savedURL { lastCaptureURL = savedURL }
        }
        OutputService.playCaptureSound()
        CaptureNotifier.shared.notify(savedURL: savedURL, copied: copies, image: capture.image)

        let id = await record(capture, exportedURL: savedURL)
        if showsThumbnail, defaults.bool(forKey: PreferenceKey.showThumbnail) {
            QuickAccessController.shared.show(.image(capture.image, scale: capture.scale), fileURL: savedURL, libraryID: id)
        }
        if defaults.bool(forKey: PreferenceKey.openEditorAfterCapture) {
            openEditor(original: capture.original, scale: capture.scale, annotations: capture.annotations, libraryID: id)
        }
    }

    // MARK: History

    @discardableResult
    private func record(_ capture: Capture, exportedURL: URL?) async -> UUID? {
        if let id = capture.libraryID {
            await library?.updateAnnotations(for: id, annotations: capture.annotations, exportedURL: exportedURL)
            return id
        }
        return await record(original: capture.original, scale: capture.scale, annotations: capture.annotations,
                            exportedURL: exportedURL, discarded: false)
    }

    @discardableResult
    private func record(original: CGImage, scale: CGFloat, annotations: AnnotationDocument,
                        exportedURL: URL?, discarded: Bool) async -> UUID? {
        await library?.recordScreenshot(original: original, scale: scale, annotations: annotations,
                                        exportedURL: exportedURL, sourceAppName: sourceAppName, wasDiscarded: discarded)
    }

    func showLibrary() {
        guard let library else {
            NSSound.beep()
            return
        }
        if libraryWindowController == nil {
            libraryWindowController = LibraryWindowController(
                library: library,
                onReEditScreenshot: { [weak self] shot in
                    self?.openEditor(original: shot.original, scale: shot.scale, annotations: shot.annotations, libraryID: shot.id)
                },
                onOpenRecording: { [weak self] url in self?.openRecording(url) }
            )
        }
        libraryWindowController?.show()
    }

    /// Opens a recent capture from the menu bar (HI-6).
    func open(_ recent: RecentCapture) {
        if recent.kind == .screenshot, let library {
            Task {
                if let shot = await library.screenshotForEditing(id: recent.id) {
                    openEditor(original: shot.original, scale: shot.scale, annotations: shot.annotations, libraryID: shot.id)
                }
            }
        } else if let url = recent.exportURL {
            openRecording(url)
        } else {
            showLibrary()
        }
    }

    // MARK: Editor (ED-1…ED-3)

    func openEditor(original: CGImage, scale: CGFloat, annotations: AnnotationDocument, libraryID: UUID?) {
        // The editor may produce several outputs; the first one records the item.
        let session = EditSession(libraryID: libraryID)
        ImageEditorWindowController.open(image: original, scale: scale, annotations: annotations) { [weak self] action, edited in
            guard let self else { return }
            let capture = Capture(image: edited.image, original: edited.original, annotations: edited.annotations,
                                  scale: edited.scale, screenRect: nil, libraryID: session.libraryID)
            let mapped: OutputAction = switch action {
            case .copy: .copy
            case .save: .save
            case .saveAs: .saveAs
            case .print: .print
            case .pin: .pin
            case .shared: .shared
            }
            if session.libraryID == nil {
                // Record once, then treat later outputs as re-edits of that item.
                Task {
                    session.libraryID = await self.record(capture, exportedURL: nil)
                    var updated = capture
                    updated.libraryID = session.libraryID
                    self.apply(mapped, to: updated)
                }
            } else {
                self.apply(mapped, to: capture)
            }
        }
    }

    private final class EditSession {
        var libraryID: UUID?
        init(libraryID: UUID?) { self.libraryID = libraryID }
    }

    func openRecording(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    // MARK: Pins and thumbnails

    private func handlePin(_ action: PinAction, image: CGImage, scale: CGFloat) {
        let capture = Capture(image: image, original: image, annotations: AnnotationDocument(), scale: scale, screenRect: nil)
        switch action {
        case .copy:
            OutputService.copy(image)
            CaptureNotifier.shared.notify(savedURL: nil, copied: true, image: image)
        case .save:
            if let url = OutputService.save(image) {
                lastCaptureURL = url
                CaptureNotifier.shared.notify(savedURL: url, copied: false, image: image)
            }
        case .edit:
            openEditor(original: capture.original, scale: scale, annotations: capture.annotations, libraryID: nil)
        }
    }

    private func handleThumbnail(_ action: ThumbnailAction, item: QuickAccessItem) {
        let quickAccess = QuickAccessController.shared
        switch (action, item.content) {
        case let (.copy, .image(image, _)):
            OutputService.copy(image)
            quickAccess.dismiss(item)
        case let (.copy, .video(url, _)):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            quickAccess.dismiss(item)
        case let (.save, .image(image, _)):
            guard let url = OutputService.save(image) else { return }
            item.fileURL = url
            lastCaptureURL = url
            if let id = item.libraryID { Task { await library?.setExportURL(url, for: id) } }
            CaptureNotifier.shared.notify(savedURL: url, copied: false, image: image)
        case let (.edit, .image(image, scale)):
            quickAccess.dismiss(item)
            if let id = item.libraryID, let library {
                Task {
                    if let shot = await library.screenshotForEditing(id: id) {
                        openEditor(original: shot.original, scale: shot.scale, annotations: shot.annotations, libraryID: id)
                    } else {
                        openEditor(original: image, scale: scale, annotations: AnnotationDocument(), libraryID: nil)
                    }
                }
            } else {
                openEditor(original: image, scale: scale, annotations: AnnotationDocument(), libraryID: nil)
            }
        case let (.edit, .video(url, _)):
            quickAccess.dismiss(item)
            openRecording(url)
        case let (.pin, .image(image, scale)):
            quickAccess.dismiss(item)
            PinController.shared.pin(image, scale: scale)
        case (.delete, _):
            quickAccess.dismiss(item)
            if let url = item.fileURL { NSWorkspace.shared.recycle([url]) }
            if let id = item.libraryID { Task { await library?.delete(ids: [id]) } }
        case (.reveal, _):
            if let url = item.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case (.open, _):
            if let url = item.fileURL { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    // MARK: Helpers

    private func takeSnapshots() async -> [DisplaySnapshot]? {
        let defaults = UserDefaults.standard
        do {
            let snapshots = try await ScreenshotService.snapshotDisplays(
                showsCursor: defaults.bool(forKey: PreferenceKey.captureShowsCursor),
                hidesDesktopIcons: defaults.bool(forKey: PreferenceKey.captureHidesDesktopIcons)
            )
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

    private func rememberSourceApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        sourceAppName = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost?.localizedName
    }

    static func displayIDUnderCursor() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        return screen?.displayID
    }
}
