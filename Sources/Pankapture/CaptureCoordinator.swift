import Annotation
import AppCore
import AppKit
import Capture
import Library
import Observation
import Overlay
import QuickAccess
import Recording
import Synchronization
import VideoEditor

/// Routes user intents (shortcuts, menu items, URLs) to capture flows and owns
/// post-capture behaviour: output actions, history, thumbnails, pins, editor.
@MainActor
@Observable
final class CaptureCoordinator {
    private(set) var lastCaptureURL: URL?
    /// The newest recording (MP4) still on disk, for "Edit Last Recording".
    private(set) var lastRecordingURL: URL?
    /// Recordings whose webcam is being drawn into the saved copy (ADR-25).
    private(set) var recordingsBeingPrepared = 0
    /// 0…1 for the newest of them, `nil` when none is being prepared.
    private(set) var cameraCompositeProgress: Double?
    private(set) var lastErrorMessage: String?
    /// Actions whose shortcut couldn't be registered (taken by another app).
    private(set) var shortcutConflicts: Set<ShortcutAction> = []

    /// Screen recording (options panel, controller, recovery).
    let recording = RecordingCoordinator()
    /// Video editor windows (M5).
    @ObservationIgnored let videoEditor = VideoEditorWindowController()

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

        PinController.shared.onAction = { [weak self] action, image, scale, libraryID in
            self?.handlePin(action, image: image, scale: scale, libraryID: libraryID)
        }
        QuickAccessController.shared.onAction = { [weak self] action, item in
            self?.handleThumbnail(action, item: item)
        }
        recording.controller.onFinish = { [weak self] outcome in
            self?.handleRecording(outcome)
        }
        videoEditor.onExportFinished = { [weak self] result in
            self?.videoExported(result)
        }
        CaptureNotifier.shared.onEditRecording = { [weak self] url in
            self?.openRecording(url)
        }
        Task { [weak self] in
            await self?.recording.recoverInterruptedRecordings { url in
                self?.recordingSaved(at: url, videoSize: .zero)
            }
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
        case .scrollingCapture:
            rememberSourceApp()
            Task { [weak self] in
                await ScrollingCaptureController.start { image, scale in
                    Task {
                        await self?.deliverStill(Capture(image: image, original: image, annotations: AnnotationDocument(),
                                                         scale: scale, screenRect: nil))
                    }
                }
            }
        case .openHistory:
            showLibrary()
        case .recordScreen:
            recording.toggleFromShortcut()
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
        let windows = WindowList.onScreenWindows(keeping: OwnWindows.capturableIDs())
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
        let windows = WindowList.onScreenWindows(keeping: OwnWindows.capturableIDs())
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

        rememberSourceApp()
        let windows = WindowList.onScreenWindows(keeping: OwnWindows.capturableIDs())
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
            OutputService.copy(capture.image, scale: capture.scale)
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: nil, copied: true, image: capture.image)
            Task { await record(capture, exportedURL: nil) }
        case .save:
            let url = OutputService.save(capture.image, scale: capture.scale)
            if let url { lastCaptureURL = url }
            OutputService.playCaptureSound()
            CaptureNotifier.shared.notify(savedURL: url, copied: false, image: capture.image)
            Task { await record(capture, exportedURL: url) }
        case .saveAs:
            let url = OutputService.saveAs(capture.image, scale: capture.scale)
            if let url {
                lastCaptureURL = url
                CaptureNotifier.shared.notify(savedURL: url, copied: false, image: capture.image)
            }
            Task { await record(capture, exportedURL: url) }
        case .print:
            OutputService.print(capture.image, scale: capture.scale)
            Task { await record(capture, exportedURL: nil) }
        case .pin:
            Task {
                let id = await record(capture, exportedURL: nil)
                PinController.shared.pin(capture.image, scale: capture.scale, at: capture.screenRect, libraryID: id)
            }
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
            OutputService.copy(capture.image, scale: capture.scale)
        }
        var savedURL: URL?
        if defaults.bool(forKey: PreferenceKey.saveAfterCapture) {
            savedURL = OutputService.save(capture.image, scale: capture.scale)
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
                // Record once (even if several outputs fire quickly), then treat
                // every output as a re-edit of that item.
                let recording = session.recordTask ?? Task { await self.record(capture, exportedURL: nil) }
                session.recordTask = recording
                Task {
                    session.libraryID = await recording.value
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
        var recordTask: Task<UUID?, Never>?
        init(libraryID: UUID?) { self.libraryID = libraryID }
    }

    /// Opens the newest recording in the video editor.
    func editLastRecording() {
        guard let url = lastRecordingURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastRecordingURL = nil
            return
        }
        openRecording(url)
    }

    /// Opens a recording in the video editor (GIFs open in the default app).
    func openRecording(_ url: URL) {
        if url.pathExtension.lowercased() == "gif" {
            NSWorkspace.shared.open(url)
        } else {
            videoEditor.open(url: url)
        }
    }

    private func videoExported(_ result: VideoExportResult) {
        let kind: CaptureKind = result.format == .gif ? .gif : .recording
        lastCaptureURL = result.url
        CaptureNotifier.shared.notifyRecording(savedURL: result.url)
        Task { await library?.recordRecording(fileURL: result.url, kind: kind, sourceAppName: nil) }
    }

    // MARK: Recording results (M3, QA-5)

    private func handleRecording(_ outcome: RecordingOutcome) {
        switch outcome {
        case let .finished(result, outputKind):
            let opensEditor = UserDefaults.standard.bool(forKey: PreferenceKey.videoEditorOpenAfterRecording)
            if outputKind == .gif {
                convertToGIF(result)
            } else if result.hasCameraTrack {
                compositeCamera(result, opensEditor: opensEditor)
            } else {
                recordingSaved(at: result.url, videoSize: result.videoSize)
                if opensEditor { videoEditor.open(url: result.url) }
            }
        case let .interrupted(error, result):
            if let result {
                if result.hasCameraTrack {
                    compositeCamera(result, opensEditor: false)
                } else {
                    recordingSaved(at: result.url, videoSize: result.videoSize)
                }
            }
            OutputService.presentError("The recording stopped early", error)
        case let .failed(error):
            OutputService.presentError("Couldn't record the screen", error)
        case .cancelled:
            break
        }
    }

    /// - Parameter thumbnail: the card already showing this recording while
    ///   it was being prepared; it switches to the saved file.
    private func recordingSaved(at url: URL, videoSize: CGSize, kind: CaptureKind = .recording, thumbnail: QuickAccessItem? = nil) {
        lastCaptureURL = url
        if kind == .recording { lastRecordingURL = url }
        if let thumbnail {
            thumbnail.content = .video(url, size: videoSize)
            thumbnail.fileURL = url
            thumbnail.progress = nil
        } else if UserDefaults.standard.bool(forKey: PreferenceKey.showThumbnail) {
            QuickAccessController.shared.show(.video(url, size: videoSize), fileURL: url)
        }
        CaptureNotifier.shared.notifyRecording(savedURL: url)
        Task { await library?.recordRecording(fileURL: url, kind: kind, sourceAppName: nil) }
    }

    /// The webcam was recorded as its own track (ADR-25), which players don't
    /// show. Keep that layered file as the editable original (Application
    /// Support) and save a copy with the webcam drawn in under the same name.
    /// The editor opens the original when asked for the copy.
    ///
    /// Drawing the copy re-encodes every frame, which is bound by the hardware
    /// encoder (roughly real time for a 60 fps Retina recording), so nothing
    /// waits for it: the thumbnail appears at once with a progress bar, and
    /// the editor opens on the original.
    private func compositeCamera(_ result: RecordingResult, opensEditor: Bool) {
        let destination = result.url
        let source = AppPaths.recordingSources.appendingPathComponent(destination.lastPathComponent)
        do {
            try AppPaths.ensure(AppPaths.recordingSources)
            try FileManager.default.moveItem(at: destination, to: source)
        } catch {
            Log.recording.error("Couldn't keep the layered recording: \(error.localizedDescription, privacy: .public)")
            Task {
                // Separate tracks only: give players a mixed one before saving.
                _ = try? await AudioMixdown.addMixedTrack(to: destination)
                recordingSaved(at: destination, videoSize: result.videoSize)
                if opensEditor { videoEditor.open(url: destination) }
            }
            return
        }

        lastRecordingURL = destination
        // The progress card shows even with thumbnails turned off, so it's
        // clear the recording is still being saved; it then goes away.
        let showsThumbnail = UserDefaults.standard.bool(forKey: PreferenceKey.showThumbnail)
        let thumbnail = QuickAccessController.shared.show(.video(source, size: result.videoSize))
        thumbnail.progressTitle = "Saving with camera"
        thumbnail.progress = 0
        if opensEditor { videoEditor.open(url: source) }

        recordingsBeingPrepared += 1
        cameraCompositeProgress = 0
        let reporter = ProgressReporter { [weak self] fraction in
            if thumbnail.isProcessing { thumbnail.progress = fraction }
            self?.cameraCompositeProgress = fraction
        }
        Task {
            defer {
                recordingsBeingPrepared -= 1
                if recordingsBeingPrepared == 0 { cameraCompositeProgress = nil }
            }
            do {
                let start = ContinuousClock.now
                let resolution = UserDefaults.standard.string(forKey: PreferenceKey.recordingCameraCompositeResolution)
                    .flatMap(ExportResolution.init(rawValue:)) ?? .original
                let exported = try await CameraComposite.export(recordingAt: source, to: destination, resolution: resolution) {
                    reporter.report($0)
                }
                Log.recording.info("Webcam composited in \((ContinuousClock.now - start).formatted(.units(allowed: [.seconds])), privacy: .public)")
                recordingSaved(at: destination, videoSize: exported.pixelSize, thumbnail: thumbnail)
                if !showsThumbnail { QuickAccessController.shared.dismiss(thumbnail) }
            } catch {
                // Give the user the layered file rather than nothing, with a
                // mixed audio track so every player has the mic.
                Log.recording.error("Webcam composite failed: \(error.localizedDescription, privacy: .public)")
                _ = try? await AudioMixdown.addMixedTrack(to: source)
                try? FileManager.default.moveItem(at: source, to: destination)
                recordingSaved(at: destination, videoSize: result.videoSize, thumbnail: thumbnail)
                if !showsThumbnail { QuickAccessController.shared.dismiss(thumbnail) }
                OutputService.presentError("The camera couldn't be added to the saved video. Open it in the editor and export it to include the camera.", error)
            }
        }
    }

    /// GIF mode (REC-14) records an MP4 and converts it here; the MP4 goes to the Trash.
    private func convertToGIF(_ result: RecordingResult) {
        Task {
            do {
                let gif = try await GIFExporter.convert(videoAt: result.url, options: GIFOptions(width: 800, fps: 15))
                _ = try? await NSWorkspace.shared.recycle([result.url])
                recordingSaved(at: gif.url, videoSize: gif.pixelSize, kind: .gif)
            } catch {
                Log.recording.error("GIF conversion failed: \(error.localizedDescription, privacy: .public)")
                recordingSaved(at: result.url, videoSize: result.videoSize)
                OutputService.presentError("Couldn't make a GIF; the MP4 was kept", error)
            }
        }
    }

    // MARK: Pins and thumbnails

    private func handlePin(_ action: PinAction, image: CGImage, scale: CGFloat, libraryID: UUID?) {
        let capture = Capture(image: image, original: image, annotations: AnnotationDocument(), scale: scale, screenRect: nil)
        switch action {
        case .copy:
            OutputService.copy(image, scale: scale)
            CaptureNotifier.shared.notify(savedURL: nil, copied: true, image: image)
        case .save:
            if let url = OutputService.save(image, scale: scale) {
                lastCaptureURL = url
                CaptureNotifier.shared.notify(savedURL: url, copied: false, image: image)
            }
        case .edit:
            // Re-edit the history item (original + live annotations) when we have one.
            if let libraryID, let library {
                Task {
                    if let shot = await library.screenshotForEditing(id: libraryID) {
                        openEditor(original: shot.original, scale: shot.scale, annotations: shot.annotations, libraryID: libraryID)
                    } else {
                        openEditor(original: image, scale: scale, annotations: capture.annotations, libraryID: nil)
                    }
                }
            } else {
                openEditor(original: capture.original, scale: scale, annotations: capture.annotations, libraryID: nil)
            }
        }
    }

    private func handleThumbnail(_ action: ThumbnailAction, item: QuickAccessItem) {
        let quickAccess = QuickAccessController.shared
        switch (action, item.content) {
        case let (.copy, .image(image, scale)):
            OutputService.copy(image, scale: scale)
            quickAccess.dismiss(item)
        case let (.copy, .video(url, _)):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            quickAccess.dismiss(item)
        case let (.save, .image(image, scale)):
            guard let url = OutputService.save(image, scale: scale) else { return }
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
            if let url = item.fileURL {
                // A recording's layered original (ADR-25) goes with it.
                let source = AppPaths.editableRecording(for: url)
                NSWorkspace.shared.recycle(source == url ? [url] : [url, source])
            }
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
                ownWindowIDs: OwnWindows.capturableIDs(),
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

/// Forwards export progress (called on an encoder queue, once per frame) to
/// the main actor in whole-percent steps.
private final class ProgressReporter: Sendable {
    private let lastPercent = Mutex(-1)
    private let update: @MainActor (Double) -> Void

    init(_ update: @escaping @MainActor (Double) -> Void) {
        self.update = update
    }

    func report(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded(.down))
        let changed = lastPercent.withLock { last in
            guard percent > last else { return false }
            last = percent
            return true
        }
        guard changed else { return }
        let update = self.update
        Task { @MainActor in update(Double(percent) / 100) }
    }
}
