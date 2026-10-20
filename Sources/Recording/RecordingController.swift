import AppCore
import AppKit
import Observation

/// An area chosen by the app's selection overlay: display-local points, top-left origin.
public struct AreaSelection: Equatable, Sendable {
    public var displayID: CGDirectDisplayID
    public var rect: CGRect

    public init(displayID: CGDirectDisplayID, rect: CGRect) {
        self.displayID = displayID
        self.rect = rect
    }
}

/// How a recording session ended.
public enum RecordingOutcome: Sendable {
    /// Saved. For `.gif` output the app converts `result.url` afterwards (REC-14).
    case finished(RecordingResult, outputKind: RecordingOptions.OutputKind)
    /// The system or writer ended it early; whatever was captured was saved if possible.
    case interrupted(RecordingError, RecordingResult?)
    case failed(RecordingError)
    /// The user cancelled (picker, countdown, or discard).
    case cancelled
}

/// One-stop recording flow for the app (M3 + M4): source picking, overlays
/// (webcam, click rings, keystrokes, area frame), countdown, HUD, and cleanup.
///
/// ```swift
/// let recording = RecordingController()
/// recording.areaProvider = { await overlay.selectRecordingArea() }
/// recording.onFinish = { outcome in … }
/// // UI: RecordingOptionsView(controller: recording) in a popover/panel.
/// // Hotkey: recording.toggle()
/// ```
@MainActor
@Observable
public final class RecordingController {
    public let recorder: ScreenRecorder
    public let optionsModel: RecordingOptionsModel
    public let webcam: WebcamBubble

    /// True from the moment Record is pressed until capture starts (source
    /// picking, countdown). Use `isBusy` to grey out menu items.
    public private(set) var isPreparing = false
    public var isBusy: Bool { isPreparing || recorder.state.isActive }

    /// Supplies an area for `.area` recordings (the app's selection overlay).
    /// Return `nil` if the user cancels. Without a provider, `.area` falls back
    /// to picking a display.
    @ObservationIgnored public var areaProvider: (@MainActor () async -> AreaSelection?)?
    /// Every session ends here exactly once.
    @ObservationIgnored public var onFinish: (@MainActor (RecordingOutcome) -> Void)?

    @ObservationIgnored private let clickHighlighter = ClickHighlighter()
    @ObservationIgnored private let keystrokes = KeystrokeDisplay()
    @ObservationIgnored private let areaFrame = AreaFrameIndicator()
    @ObservationIgnored private let picker = WindowPicker()
    @ObservationIgnored private var controlBar: RecordingControlBar?
    @ObservationIgnored private var optionsVisible = false
    @ObservationIgnored private var hudScreen: NSScreen?
    @ObservationIgnored private var sessionOutputKind: RecordingOptions.OutputKind = .video

    public init(defaults: UserDefaults = .standard, recorder: ScreenRecorder? = nil) {
        let optionsModel = RecordingOptionsModel(defaults: defaults)
        self.optionsModel = optionsModel
        self.recorder = recorder ?? ScreenRecorder(defaults: defaults)
        webcam = WebcamBubble(appearance: .init(optionsModel.options))

        controlBar = RecordingControlBar(recorder: self.recorder, actions: .init(
            stop: { [weak self] in Task { await self?.stop() } },
            discard: { [weak self] in self?.cancel() },
            restart: { [weak self] in Task { await self?.restart() } }
        ))
        optionsModel.onChange = { [weak self] old, new in self?.optionsChanged(from: old, to: new) }
        webcam.onAppearanceChange = { [weak self] appearance in
            guard let self else { return }
            var options = self.optionsModel.options
            options.cameraShape = appearance.shape
            options.cameraMirrored = appearance.isMirrored
            options.cameraSize = appearance.size
            options.cameraDeviceID = appearance.deviceID
            self.optionsModel.options = options
        }
        self.recorder.onInterrupted = { [weak self] error, result in
            self?.tearDownOverlays()
            self?.onFinish?(.interrupted(error, result))
        }
    }

    // MARK: Entry points

    /// Starts the flow for a source kind: pick the window/display/area, then record.
    public func record(_ kind: RecordingOptions.SourceKind) {
        guard !isBusy else {
            Log.recording.notice("Record ignored: busy (preparing: \(self.isPreparing), state: \(String(describing: self.recorder.state), privacy: .public))")
            return
        }
        isPreparing = true
        Task { await pickAndRecord(kind) }
    }

    /// Records a known source (skips picking).
    public func record(source: RecordingConfiguration.Source) {
        guard !isBusy else { return }
        isPreparing = true
        Task { await begin(source: source) }
    }

    /// For the Record Screen shortcut: stops an active recording, otherwise
    /// starts one with the last-used source kind.
    public func toggle() {
        if recorder.state.isCapturing {
            Task { await stop() }
        } else if case .countingDown = recorder.state {
            cancel()
        } else {
            record(optionsModel.selectedSource)
        }
    }

    public func stop() async {
        guard recorder.state.isCapturing else { return }
        controlBar?.hide()
        let kind = sessionOutputKind
        do {
            let result = try await recorder.stop()
            tearDownOverlays()
            onFinish?(.finished(result, outputKind: kind))
        } catch {
            tearDownOverlays()
            onFinish?(.failed(error as? RecordingError ?? .writerFailed(error.localizedDescription)))
        }
    }

    /// Cancels picking/countdown or discards the current recording.
    public func cancel() {
        if isPreparing, recorder.state == .idle {
            picker.cancel() // the pending flow reports `.cancelled`
            return
        }
        if case .countingDown = recorder.state {
            recorder.cancel() // `start` throws `.cancelled`; `begin` reports it
            return
        }
        guard recorder.state.isCapturing else { return }
        recorder.cancel()
        tearDownOverlays()
        onFinish?(.cancelled)
    }

    public func restart() async {
        guard recorder.state.isCapturing else { return }
        controlBar?.hide()
        do {
            try await recorder.restart()
            controlBar?.show(on: hudScreen)
        } catch {
            tearDownOverlays()
            let failure = error as? RecordingError ?? .streamStopped(error.localizedDescription)
            onFinish?(failure == .cancelled ? .cancelled : .failed(failure))
        }
    }

    // MARK: Options UI lifecycle

    /// Call when the options UI appears: refreshes devices, starts the mic
    /// meter, and shows the webcam preview if the camera is on.
    public func optionsDidAppear() {
        optionsVisible = true
        optionsModel.refresh()
        optionsModel.setMeterActive(true)
        if optionsModel.options.showsCamera, !webcam.isVisible {
            Task { await webcam.show() }
        }
    }

    /// Call when the options UI closes. Keeps the webcam bubble if a recording is starting.
    public func optionsDidDisappear() {
        optionsVisible = false
        optionsModel.setMeterActive(false)
        if !isBusy { webcam.hide() }
    }

    private func optionsChanged(from old: RecordingOptions, to new: RecordingOptions) {
        webcam.update(.init(new))
        if new.showsCamera != old.showsCamera {
            if new.showsCamera {
                Task {
                    if await !webcam.show() { optionsModel.options.showsCamera = false }
                }
            } else if !recorder.state.isActive {
                webcam.hide()
            }
        }
    }

    // MARK: Flow

    private func pickAndRecord(_ kind: RecordingOptions.SourceKind) async {
        let source: RecordingConfiguration.Source?
        switch kind {
        case .display:
            source = await picker.pickDisplay().map { .display($0) }
        case .window:
            source = await picker.pickWindow().map { .window($0) }
        case .area:
            if let areaProvider {
                source = await areaProvider().map { .area(displayID: $0.displayID, rect: $0.rect) }
            } else {
                Log.recording.notice("No area provider set; falling back to display picking")
                source = await picker.pickDisplay().map { .display($0) }
            }
        }
        guard let source else {
            Log.recording.notice("No \(String(describing: kind), privacy: .public) picked; recording cancelled")
            isPreparing = false
            if !optionsVisible { webcam.hide() }
            onFinish?(.cancelled)
            return
        }
        await begin(source: source)
    }

    private func begin(source: RecordingConfiguration.Source) async {
        defer { isPreparing = false }
        optionsModel.setMeterActive(false) // ScreenCaptureKit opens the mic itself
        let options = optionsModel.options
        sessionOutputKind = options.outputKind

        let screen = targetScreen(for: source)
        hudScreen = screen
        let recordedFrame = recordedAppKitFrame(for: source, screen: screen)
        // Window recordings include overlays by capturing the window's area of
        // its display (`StreamSetup.windowWithOverlays`).
        var overlayIDs: [CGWindowID] = []

        // The camera is its own track (ADR-25): the bubble stays on screen as
        // a preview but out of the screen capture, so the editor can move it.
        recorder.cameraSource = nil
        recorder.cameraLayoutProvider = nil
        if options.showsCamera, await webcam.show(on: screen) {
            if let recordedFrame {
                webcam.keepInside(recordedFrame)
                recorder.cameraLayoutProvider = { [weak webcam] in webcam?.layout(in: recordedFrame) }
            }
            recorder.cameraSource = webcam
        }
        if options.highlightsClicks {
            clickHighlighter.style = .init(color: options.clickColor, diameter: options.clickSize)
            clickHighlighter.start(on: (source.displayID ?? screen?.displayID).map { [$0] })
            overlayIDs += clickHighlighter.windowIDs
        }
        if options.showsKeystrokes, let recordedFrame {
            keystrokes.showsAllKeys = options.keystrokesShowAllKeys
            if keystrokes.start(in: recordedFrame), let id = keystrokes.windowID { overlayIDs.append(id) }
        }
        if case .area(let displayID, let rect) = source {
            areaFrame.show(area: rect, on: displayID)
        }

        let config = options.makeConfiguration(source: source, overlayWindowIDs: overlayIDs)
        do {
            try await recorder.start(config)
            controlBar?.show(on: screen)
        } catch {
            Log.recording.error("Recording didn't start: \(String(describing: error), privacy: .public)")
            tearDownOverlays()
            let failure = error as? RecordingError ?? .streamStopped(error.localizedDescription)
            onFinish?(failure == .cancelled ? .cancelled : .failed(failure))
        }
    }

    private func tearDownOverlays() {
        controlBar?.hide()
        clickHighlighter.stop()
        keystrokes.stop()
        areaFrame.hide()
        if !optionsVisible { webcam.hide() }
    }

    private func targetScreen(for source: RecordingConfiguration.Source) -> NSScreen? {
        switch source {
        case .display(let id), .area(let id, _):
            ScreenGeometry.screen(for: id)
        case .window(let id):
            ScreenGeometry.windowBounds(id).flatMap(ScreenGeometry.screen(containingQuartzRect:))
        }
    }

    /// The recorded region in AppKit global coordinates.
    private func recordedAppKitFrame(for source: RecordingConfiguration.Source, screen: NSScreen?) -> CGRect? {
        switch source {
        case .display:
            screen?.frame
        case .area(let id, let rect):
            ScreenGeometry.appKitRect(forArea: rect, on: id)
        case .window(let id):
            ScreenGeometry.windowBounds(id).map {
                RecordingGeometry.appKitRect(fromQuartz: $0, primaryDisplayHeight: ScreenGeometry.primaryDisplayHeight)
            }
        }
    }
}
