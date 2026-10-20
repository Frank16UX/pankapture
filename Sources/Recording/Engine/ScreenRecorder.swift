import AppCore
import AppKit
import AVFoundation
import Observation
import os
import ScreenCaptureKit

/// The recording engine's main-actor facade (M3). Drives one `SCStream` into a
/// `RecordingWriter`, publishes observable state for the HUD and menu bar, logs
/// clicks for the sidecar, and finalizes files.
///
/// Typical use (the app usually goes through `RecordingController` instead):
/// ```swift
/// let recorder = ScreenRecorder()
/// try await recorder.start(configuration)   // countdown, then recording
/// recorder.pause(); recorder.resume()
/// let result = try await recorder.stop()     // final MP4 in the save folder
/// ```
@MainActor
@Observable
public final class ScreenRecorder {
    public enum State: Equatable, Sendable {
        case idle
        /// Seconds left before capture starts. `0` while preparing the stream
        /// (permission checks, source lookup) or when there's no countdown.
        case countingDown(remaining: Int)
        case recording
        case paused
        /// Stopping the stream and finalizing the file.
        case finishing

        public var isActive: Bool { self != .idle }
        public var isCapturing: Bool { self == .recording || self == .paused }
    }

    public private(set) var state: State = .idle
    /// Recorded seconds, excluding pauses. Updated ~4× per second while recording.
    public private(set) var elapsed: TimeInterval = 0
    /// `elapsed` as `m:ss` / `h:mm:ss`, for the HUD and the menu bar.
    public var formattedElapsed: String { RecordingHUD.format(elapsed) }
    /// Microphone meter, 0…1 (perceptual), ~15 Hz while recording with the mic on.
    public private(set) var microphoneLevel: Float = 0
    public private(set) var isMicrophoneMuted = false
    /// The configuration of the current (or last) recording.
    public private(set) var configuration: RecordingConfiguration?
    /// Set when the system or the writer ended a recording on its own.
    public private(set) var lastError: RecordingError?
    /// ID of the in-progress file, so recovery can skip it.
    public private(set) var activeRecordingID: UUID?

    /// Called when a recording ends without `stop()` being called (display
    /// disconnected, permission revoked, disk full, …). Whatever was captured is
    /// finalized first; `result` is `nil` if nothing could be saved.
    @ObservationIgnored public var onInterrupted: ((RecordingError, RecordingResult?) -> Void)?

    @ObservationIgnored private let inProgressDirectory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let namer: CaptureFileNamer

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: StreamOutput?
    @ObservationIgnored private var writer: RecordingWriter?
    @ObservationIgnored private var writerCommands: Task<Void, Never>?
    @ObservationIgnored private var manifest: RecordingManifest?
    @ObservationIgnored private var setup: StreamSetup?
    @ObservationIgnored private var timeline = PauseTimeline()
    @ObservationIgnored private var startHostTime: CMTime = .zero
    @ObservationIgnored private var clicks: [LoggedClick] = []
    @ObservationIgnored private var clickMonitors: [Any] = []
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var filterRefreshTimer: Timer?
    @ObservationIgnored private var countdown: CountdownOverlay?
    @ObservationIgnored private var signpostState: OSSignpostIntervalState?

    private struct LoggedClick {
        var hostTime: CMTime
        var location: CGPoint
        var isRightClick: Bool
    }

    public init(
        inProgressDirectory: URL = AppPaths.recordingsInProgress,
        defaults: UserDefaults = .standard,
        namer: CaptureFileNamer = CaptureFileNamer()
    ) {
        self.inProgressDirectory = inProgressDirectory
        self.defaults = defaults
        self.namer = namer
    }

    // MARK: Start

    /// Checks permissions, resolves the source, shows the countdown, and starts
    /// capturing. Throws `RecordingError.cancelled` if the countdown is cancelled.
    public func start(_ config: RecordingConfiguration) async throws {
        guard state == .idle else { throw RecordingError.invalidState }
        lastError = nil
        configuration = config
        state = .countingDown(remaining: config.countdown)

        do {
            try await checkPermissions(for: config)
            let setup = try await StreamSetup.make(for: config)
            guard state != .idle else { throw RecordingError.cancelled }

            if config.countdown > 0 {
                let overlay = CountdownOverlay()
                countdown = overlay
                let completed = await overlay.run(
                    seconds: config.countdown,
                    on: countdownScreen(for: config, setup: setup)
                ) { [weak self] remaining in
                    self?.state = .countingDown(remaining: remaining)
                }
                countdown = nil
                guard completed, state != .idle else { throw RecordingError.cancelled }
            }

            try await beginCapture(config: config, setup: setup)
        } catch {
            countdown?.cancel()
            countdown = nil
            if state != .idle { state = .idle }
            throw (error as? RecordingError) ?? RecordingError.streamStopped(error.localizedDescription)
        }
    }

    private func checkPermissions(for config: RecordingConfiguration) async throws {
        if config.capturesMicrophone {
            var status = Permissions.status(.microphone)
            if status == .notDetermined { status = await Permissions.request(.microphone) }
            guard status == .granted else { throw RecordingError.microphonePermissionDenied }
        }
    }

    private func beginCapture(config: RecordingConfiguration, setup: StreamSetup) async throws {
        let manifest = RecordingManifest(
            configuration: config,
            destinationDirectory: Preferences.saveDirectory(in: defaults)
        )
        try manifest.write(in: inProgressDirectory)
        let movieURL = RecordingManifest.movieURL(for: manifest.id, in: inProgressDirectory)

        let micFormat = Self.microphoneFormat(deviceID: config.microphoneDeviceID)
        let writer = RecordingWriter(
            settings: .init(
                url: movieURL,
                codec: config.codec,
                quality: config.quality,
                framesPerSecond: config.framesPerSecond,
                capturesSystemAudio: config.capturesSystemAudio,
                capturesMicrophone: config.capturesMicrophone,
                microphoneSampleRate: micFormat.sampleRate,
                microphoneChannels: micFormat.channels
            ),
            levelHandler: { [weak self] level in
                Task { @MainActor in self?.microphoneLevel = level }
            },
            failureHandler: { [weak self] error in
                let reason = (error as? RecordingError) ?? .writerFailed(error.localizedDescription)
                Task { @MainActor in await self?.handleInterruption(reason) }
            }
        )
        let output = StreamOutput(writer: writer) { [weak self] error in
            Task { @MainActor in await self?.handleInterruption(.streamStopped(error.localizedDescription)) }
        }

        let stream = SCStream(filter: setup.filter, configuration: setup.configuration, delegate: output)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: writer.queue)
            if config.capturesSystemAudio {
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: writer.queue)
            }
            if config.capturesMicrophone {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: writer.queue)
            }
            try await stream.startCapture()
        } catch {
            await writer.cancel()
            try? FileManager.default.removeItem(at: RecordingManifest.manifestURL(for: manifest.id, in: inProgressDirectory))
            Log.recording.error("Stream failed to start: \(error.localizedDescription, privacy: .public)")
            if (error as NSError).domain == SCStreamErrorDomain,
               (error as NSError).code == SCStreamError.userDeclined.rawValue {
                throw RecordingError.screenRecordingPermissionDenied
            }
            throw RecordingError.streamStopped(error.localizedDescription)
        }

        // `cancel()` while the stream was starting.
        guard state != .idle else {
            try? await stream.stopCapture()
            await writer.cancel()
            try? FileManager.default.removeItem(at: RecordingManifest.manifestURL(for: manifest.id, in: inProgressDirectory))
            throw RecordingError.cancelled
        }

        self.stream = stream
        self.output = output
        self.writer = writer
        self.manifest = manifest
        self.setup = setup
        activeRecordingID = manifest.id
        timeline = PauseTimeline()
        startHostTime = .hostNow
        clicks = []
        elapsed = 0
        microphoneLevel = 0
        isMicrophoneMuted = false
        state = .recording
        signpostState = Log.signposter.beginInterval("Recording")

        startTicking()
        startClickLogging()
        if config.hidesDesktopIcons, config.source.displayID != nil { startFilterRefresh() }
        Log.recording.info("Recording started: \(Int(setup.outputSize.width))×\(Int(setup.outputSize.height))")
    }

    // MARK: Controls

    public func pause() {
        guard state == .recording else { return }
        let now = CMTime.hostNow
        timeline.pause(at: now)
        sendToWriter { await $0.pause(at: now) }
        state = .paused
        tick()
    }

    public func resume() {
        guard state == .paused else { return }
        let now = CMTime.hostNow
        timeline.resume(at: now)
        sendToWriter { await $0.resume(at: now) }
        state = .recording
    }

    public func togglePause() {
        state == .paused ? resume() : pause()
    }

    public func toggleMicrophoneMute() {
        guard state.isCapturing, configuration?.capturesMicrophone == true else { return }
        isMicrophoneMuted.toggle()
        let muted = isMicrophoneMuted
        if muted { microphoneLevel = 0 }
        sendToWriter { await $0.setMicrophoneMuted(muted) }
    }

    /// Stops capturing, finalizes the MP4, moves it to the save folder, and
    /// writes the sidecar (video size, duration, clicks).
    @discardableResult
    public func stop() async throws -> RecordingResult {
        guard state.isCapturing else { throw RecordingError.invalidState }
        return try await finalize()
    }

    /// Discards the current recording (or cancels the countdown). Nothing is saved.
    public func cancel() {
        if case .countingDown = state {
            countdown?.cancel()
            state = .idle
            return
        }
        guard state.isCapturing else { return }
        let stream = self.stream
        let writer = self.writer
        let manifest = self.manifest
        let directory = inProgressDirectory
        tearDown()
        state = .idle
        Task {
            try? await stream?.stopCapture()
            await writer?.cancel()
            if let manifest {
                try? FileManager.default.removeItem(at: RecordingManifest.manifestURL(for: manifest.id, in: directory))
            }
        }
        Log.recording.info("Recording cancelled")
    }

    /// Discards the current take and starts again with the same configuration
    /// (including the countdown).
    public func restart() async throws {
        guard let config = configuration, state.isCapturing else { throw RecordingError.invalidState }
        let stream = self.stream
        let writer = self.writer
        let manifest = self.manifest
        tearDown()
        state = .idle
        try? await stream?.stopCapture()
        await writer?.cancel()
        if let manifest {
            try? FileManager.default.removeItem(at: RecordingManifest.manifestURL(for: manifest.id, in: inProgressDirectory))
        }
        try await start(config)
    }

    // MARK: Finishing

    private func finalize() async throws -> RecordingResult {
        guard let writer, let manifest, let config = configuration else { throw RecordingError.invalidState }
        let stopTime = CMTime.hostNow
        state = .finishing
        let stream = self.stream
        let pendingCommands = writerCommands
        let loggedClicks = clicks
        let clickTimeline = timeline
        tearDown()

        try? await stream?.stopCapture()
        await pendingCommands?.value

        defer {
            try? FileManager.default.removeItem(at: RecordingManifest.manifestURL(for: manifest.id, in: inProgressDirectory))
            state = .idle
        }

        let summary: RecordingWriter.Summary
        do {
            summary = try await writer.finish(at: stopTime)
        } catch {
            await writer.cancel()
            throw (error as? RecordingError) ?? RecordingError.writerFailed(error.localizedDescription)
        }
        // Players that play only the first audio track would miss the mic.
        do {
            try await AudioMixdown.addMixedTrack(to: summary.url)
        } catch {
            Log.recording.error("Audio mixdown failed; keeping separate tracks: \(error.localizedDescription, privacy: .public)")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: manifest.destinationDirectory, withIntermediateDirectories: true)
        let finalURL = namer.uniqueURL(in: manifest.destinationDirectory, for: manifest.startDate, fileExtension: "mp4")
        do {
            try fm.moveItem(at: summary.url, to: finalURL)
        } catch {
            throw RecordingError.writerFailed("Couldn't move the recording to \(manifest.destinationDirectory.path): \(error.localizedDescription)")
        }

        let sessionStart = await writer.sessionStartTime ?? startHostTime
        let sidecarClicks: [RecordingSidecar.Click] = loggedClicks.compactMap { click in
            guard let output = clickTimeline.outputTime(for: click.hostTime),
                  let start = clickTimeline.outputTime(for: sessionStart) else { return nil }
            let time = (output - start).seconds
            guard time >= 0, time <= summary.duration else { return nil }
            return RecordingSidecar.Click(time: time, location: click.location, isRightClick: click.isRightClick)
        }
        let sidecar = RecordingSidecar(videoSize: summary.videoSize, duration: summary.duration, clicks: sidecarClicks)
        do { try sidecar.save(for: finalURL) } catch {
            Log.recording.error("Sidecar save failed: \(error.localizedDescription, privacy: .public)")
        }

        let size = (try? fm.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        Log.recording.info("Saved \(finalURL.lastPathComponent, privacy: .public)")
        return RecordingResult(
            url: finalURL,
            duration: summary.duration,
            fileSize: size,
            videoSize: summary.videoSize,
            clickCount: sidecarClicks.count,
            configuration: config
        )
    }

    /// The system (or the writer) ended the recording: save what we have.
    private func handleInterruption(_ error: RecordingError) async {
        guard state.isCapturing else { return }
        Log.recording.error("Recording interrupted: \(error.localizedDescription, privacy: .public)")
        lastError = error
        let result = try? await finalize()
        onInterrupted?(error, result)
    }

    private func tearDown() {
        tickTimer?.invalidate()
        tickTimer = nil
        filterRefreshTimer?.invalidate()
        filterRefreshTimer = nil
        for monitor in clickMonitors { NSEvent.removeMonitor(monitor) }
        clickMonitors = []
        if let signpostState { Log.signposter.endInterval("Recording", signpostState) }
        signpostState = nil
        stream = nil
        output = nil
        writer = nil
        writerCommands = nil
        activeRecordingID = nil
        microphoneLevel = 0
    }

    /// Writer commands run strictly in order (a resume must never overtake its pause).
    private func sendToWriter(_ command: @escaping @Sendable (RecordingWriter) async -> Void) {
        guard let writer else { return }
        let previous = writerCommands
        writerCommands = Task {
            await previous?.value
            await command(writer)
        }
    }

    // MARK: Timer, clicks, filter refresh

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        elapsed = timeline.elapsedSeconds(from: startHostTime, to: .hostNow)
    }

    /// Logs every click (independent of click highlighting) so the editor can
    /// auto-zoom (VE-5). Locations are normalized to the recorded frame.
    private func startClickLogging() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.logClick(isRight: event.type == .rightMouseDown) }
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func logClick(isRight: Bool) {
        guard state == .recording, let config = configuration else { return }
        let hostTime = CMTime.hostNow
        guard let frame = ScreenGeometry.capturedFrame(for: config.source, sourceRect: setup?.sourceRect),
              let location = RecordingGeometry.normalizedLocation(
                ofAppKitPoint: NSEvent.mouseLocation,
                inQuartzFrame: frame,
                primaryDisplayHeight: ScreenGeometry.primaryDisplayHeight
              ) else { return }
        clicks.append(LoggedClick(hostTime: hostTime, location: location, isRightClick: isRight))
    }

    /// While desktop icons are hidden, Finder is excluded wholesale and its
    /// regular windows are excepted by ID; refresh that list so Finder windows
    /// opened mid-recording still appear.
    private func startFilterRefresh() {
        filterRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFilter() }
        }
    }

    private func refreshFilter() {
        guard state.isCapturing, let config = configuration, let stream else { return }
        Task {
            guard let filter = await StreamSetup.refreshedFilter(for: config) else { return }
            try? await stream.updateContentFilter(filter)
        }
    }

    // MARK: Helpers

    private func countdownScreen(for config: RecordingConfiguration, setup: StreamSetup) -> NSScreen? {
        switch config.source {
        case .display(let id), .area(let id, _):
            return ScreenGeometry.screen(for: id)
        case .window(let id):
            return ScreenGeometry.windowBounds(id).flatMap(ScreenGeometry.screen(containingQuartzRect:))
        }
    }

    /// The mic's native format, used to configure the AAC track before the
    /// first mic sample arrives.
    static func microphoneFormat(deviceID: String?) -> (sampleRate: Double, channels: Int) {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let description = device?.activeFormat.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0 else { return (48_000, 1) }
        return (asbd.mSampleRate, Int(max(asbd.mChannelsPerFrame, 1)))
    }
}
