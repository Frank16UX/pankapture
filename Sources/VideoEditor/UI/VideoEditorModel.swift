import AppCore
import AppKit
import AVFoundation
import Observation
import Synchronization

/// State and actions of one editor window. Owns the preview player and keeps
/// it in sync with the edit project: timeline edits rebuild the player item,
/// zoom/background edits swap its video composition, volume edits swap its
/// audio mix, so every change previews live without re-encoding.
@MainActor
@Observable
final class VideoEditorModel {
    enum ExportState: Equatable {
        case idle
        case running(progress: Double)
        case finished(VideoExportResult)
        case failed(String)
    }

    let sourceURL: URL
    let player = AVPlayer()

    private(set) var media: SourceMedia?
    private(set) var loadError: String?
    private(set) var project: VideoEditProject
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Playhead in **source** seconds (the timeline shows the whole source).
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    /// Range selected on the timeline (source seconds), for Cut and Speed.
    var selection: TimeRange?
    var selectedCut: TimeRange?
    /// The zoom being edited. While set, the preview shows the unzoomed frame
    /// so the user can position the zoom rectangle over it.
    var selectedZoomID: ZoomSegment.ID? {
        didSet {
            guard oldValue != selectedZoomID else { return }
            updatePreviewVideoComposition()
        }
    }

    private(set) var filmstrip: [FilmstripFrame] = []
    private(set) var waveforms: [CMPersistentTrackID: Waveform] = [:]
    private(set) var sidecar: RecordingSidecar?

    var exportSettings: ExportSettings {
        didSet { Self.saveExportSettings(exportSettings) }
    }
    private(set) var exportState: ExportState = .idle
    var isShowingExportSheet = false

    @ObservationIgnored var onExportFinished: ((VideoExportResult) -> Void)?
    @ObservationIgnored private var history = UndoHistory<VideoEditProject>()
    @ObservationIgnored private var tracks: LoadedTracks?
    @ObservationIgnored private var currentEdit: EditComposition?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var analysisTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var isContinuousEdit = false
    @ObservationIgnored private let store: ProjectStore

    init(url: URL, store: ProjectStore = ProjectStore()) {
        sourceURL = url
        self.store = store
        project = VideoEditProject(sourceURL: url, sourceDuration: 0)
        exportSettings = Self.loadExportSettings()
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
    }

    // MARK: Loading

    var duration: Double { project.sourceDuration }
    var timeline: Timeline { currentEdit?.timeline ?? project.timeline }
    var outputDuration: Double { project.timeline.outputDuration }
    var audioTracks: [AudioTrackInfo] { media?.audioTracks ?? [] }
    var clickCount: Int { sidecar?.clicks.count ?? 0 }
    var selectedZoom: ZoomSegment? { project.zooms.first { $0.id == selectedZoomID } }

    /// Preview render plan (for overlay geometry: canvas and video rect).
    var previewPlan: RenderPlan? {
        guard let media else { return nil }
        return RenderPlan(project: project, sourceSize: media.size, orientation: media.orientation, shortSideCap: 1080)
    }

    func load() async {
        do {
            let media = try await SourceMedia.load(url: sourceURL)
            tracks = try await media.loadTracks()
            self.media = media
            if var saved = store.load(for: sourceURL, sourceDuration: media.duration) {
                saved.adapt(toSourceDuration: media.duration)
                project = saved
            } else {
                project = VideoEditProject(sourceURL: sourceURL, sourceDuration: media.duration)
            }
            sidecar = RecordingSidecar.load(for: sourceURL)
            rebuildPlayerItem(seekToSource: project.trim.start)
            startAnalysis(media)
            Log.editor.info("Opened \(self.sourceURL.lastPathComponent, privacy: .public): \(media.duration)s, \(media.audioTracks.count) audio track(s)")
        } catch {
            loadError = error.localizedDescription
            Log.editor.error("Couldn't open \(self.sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startAnalysis(_ media: SourceMedia) {
        let asset = media.asset
        let duration = media.duration
        let aspect = media.size.height > 0 ? media.size.width / media.size.height : 16.0 / 9.0
        // Detached so the work stays off the main actor; the handlers forward
        // cancellation (closing the window) to the detached tasks.
        let filmstrip = Task.detached(priority: .userInitiated) {
            await FilmstripGenerator.frames(
                asset: asset, duration: duration, count: 40,
                maximumSize: CGSize(width: 160 * aspect, height: 160)
            )
        }
        analysisTasks.append(Task { [weak self] in
            let frames = await withTaskCancellationHandler { await filmstrip.value } onCancel: { filmstrip.cancel() }
            self?.filmstrip = frames
        })
        for track in media.audioTracks {
            let extraction = Task.detached(priority: .utility) {
                try await WaveformExtractor.waveform(asset: asset, trackID: track.trackID)
            }
            analysisTasks.append(Task { [weak self] in
                let waveform = try? await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
                if let waveform { self?.waveforms[track.trackID] = waveform }
            })
        }
    }

    // MARK: Editing

    /// Applies one undoable change. Edits with the same `coalescingKey` less
    /// than a second apart share one undo step (e.g. the color panel, which
    /// reports every tick of a drag with no begin/end).
    func edit(coalescingKey: String? = nil, _ change: (inout VideoEditProject) -> Void) {
        var updated = project
        change(&updated)
        guard updated != project else { return }
        if isContinuousEdit {
            // Record lazily, so a click that changes nothing costs no undo step.
            if let snapshot = continuousSnapshot {
                history.record(snapshot)
                continuousSnapshot = nil
            }
        } else if let key = coalescingKey, key == lastCoalescingKey, Date().timeIntervalSince(lastCoalescedEdit) < 1 {
            lastCoalescedEdit = Date()
        } else {
            history.record(project)
            lastCoalescingKey = coalescingKey
            lastCoalescedEdit = Date()
        }
        apply(updated)
    }

    /// Starts a drag/slider gesture: one undo step for the whole gesture.
    func beginContinuousEdit() {
        guard !isContinuousEdit else { return }
        continuousSnapshot = project
        isContinuousEdit = true
    }

    func endContinuousEdit() {
        isContinuousEdit = false
        continuousSnapshot = nil
        rebuildIfTimelineChanged(force: true)
    }

    func undo() {
        cancelContinuousEdit()
        guard let previous = history.undo(current: project) else { return }
        apply(previous)
    }

    func redo() {
        cancelContinuousEdit()
        guard let next = history.redo(current: project) else { return }
        apply(next)
    }

    /// A gesture whose view disappeared never reports its end; don't let
    /// that swallow later undo steps.
    func cancelContinuousEdit() {
        isContinuousEdit = false
        continuousSnapshot = nil
        lastCoalescingKey = nil
    }

    @ObservationIgnored private var continuousSnapshot: VideoEditProject?
    @ObservationIgnored private var lastCoalescingKey: String?
    @ObservationIgnored private var lastCoalescedEdit = Date.distantPast

    private func apply(_ updated: VideoEditProject) {
        let old = project
        project = updated
        refreshUndoState()
        if let id = selectedZoomID, !updated.zooms.contains(where: { $0.id == id }) { selectedZoomID = nil }
        if let cut = selectedCut, !updated.cuts.contains(cut) { selectedCut = nil }

        let timelineChanged = old.trim != updated.trim || old.cuts != updated.cuts || old.speedSegments != updated.speedSegments
        if timelineChanged {
            // Rebuilding the player item on every drag tick is wasteful; the
            // timeline redraws immediately and the preview follows shortly.
            scheduleRebuild(delay: isContinuousEdit ? .milliseconds(200) : .zero)
        } else if old.background != updated.background || (old.zooms != updated.zooms && selectedZoomID == nil) {
            // While a zoom is being edited the preview ignores zooms, so
            // dragging its rectangle doesn't need a new video composition.
            updatePreviewVideoComposition()
        }
        if old.trackVolumes != updated.trackVolumes { updatePreviewAudioMix() }
        scheduleSave()
    }

    private func refreshUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: Timeline actions

    func cutSelection() {
        guard let selection, selection.duration > 0.01 else { return }
        edit { $0.addCut(selection) }
        self.selection = nil
    }

    func removeCut(_ cut: TimeRange) {
        edit { $0.removeCut(cut) }
    }

    func setTrimInAtPlayhead() { edit { $0.setTrimStart(playhead) } }
    func setTrimOutAtPlayhead() { edit { $0.setTrimEnd(playhead) } }

    func addZoomAtPlayhead() {
        var added: ZoomSegment?
        edit { added = $0.addZoom(at: playhead) }
        selectedZoomID = added?.id
    }

    func removeSelectedZoom() {
        guard let id = selectedZoomID else { return }
        edit { $0.removeZoom(id: id) }
    }

    func applyAutoZoom() {
        guard let sidecar, !sidecar.clicks.isEmpty else { return }
        let suggestions = AutoZoomSuggester().suggest(clicks: sidecar.clicks, sourceDuration: duration)
        edit { $0.applyAutoZooms(suggestions) }
    }

    func setSpeedForSelection(_ rate: Double) {
        guard let selection else { return }
        edit { $0.setSpeed(rate, for: selection) }
    }

    /// Deletes whatever is selected (zoom, cut, or the selection as a cut).
    func deleteSelected() {
        if selectedZoomID != nil {
            removeSelectedZoom()
        } else if let cut = selectedCut {
            removeCut(cut)
        } else if selection != nil {
            cutSelection()
        }
    }

    func clearSelection() {
        cancelContinuousEdit()
        selection = nil
        selectedCut = nil
        selectedZoomID = nil
    }

    // MARK: Playback

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard currentEdit != nil else { return }
        if let item = player.currentItem, item.currentTime().seconds >= timeline.outputDuration - 0.05 {
            seekPlayer(to: .zero)
        }
        player.rate = 1
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    /// L: play, or speed up when already playing forward (1× → 2× → 4×).
    func playFaster() {
        if isPlaying, player.rate >= 1 {
            player.rate = min(4, player.rate * 2)
        } else {
            play()
        }
    }

    func stepFrames(_ count: Int) {
        pause()
        player.currentItem?.step(byCount: count)
    }

    func jump(by seconds: Double) {
        let output = player.currentTime().seconds + seconds
        seekOutput(max(0, min(timeline.outputDuration, output)))
    }

    /// Moves the playhead to source `time`; removed moments snap to the next kept frame.
    func seek(toSource time: Double) {
        let clamped = time.clamped(to: 0...max(0, duration))
        playhead = clamped
        seekOutput(timeline.nearestOutputTime(forSource: clamped), updatePlayhead: !timeline.isKept(source: clamped))
    }

    private func seekOutput(_ output: Double, updatePlayhead: Bool = true) {
        seekPlayer(to: CompositionBuilder.cmTime(output))
        if updatePlayhead { playhead = timeline.sourceTime(forOutput: output) }
    }

    /// Exact seek. While seeks are in flight (scrubbing), the periodic
    /// observer reports stale times, so it's ignored until they land.
    private func seekPlayer(to time: CMTime) {
        pendingSeeks += 1
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.pendingSeeks -= 1 }
        }
    }

    @ObservationIgnored private var pendingSeeks = 0

    private func playerTimeChanged(_ time: CMTime) {
        guard currentEdit != nil, time.isNumeric, pendingSeeks == 0 else { return }
        playhead = timeline.sourceTime(forOutput: time.seconds)
        if isPlaying, player.rate == 0 { isPlaying = false }
    }

    // MARK: Preview player

    private func scheduleRebuild(delay: Duration) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.rebuildPlayerItem(seekToSource: self.playhead)
        }
    }

    private func rebuildIfTimelineChanged(force: Bool) {
        guard force, let edit = currentEdit, edit.timeline != project.timeline else { return }
        scheduleRebuild(delay: .zero)
    }

    private func previewOptions() -> CompositionBuilder.Options {
        .preview(frameRate: media?.frameRate ?? 30, zoomEnabled: selectedZoomID == nil)
    }

    private func rebuildPlayerItem(seekToSource source: Double) {
        guard let media, let tracks else { return }
        do {
            let edit = try CompositionBuilder.build(source: media, tracks: tracks, project: project, options: previewOptions())
            let item = AVPlayerItem(asset: edit.composition)
            item.videoComposition = edit.videoComposition
            item.audioMix = edit.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let wasPlaying = isPlaying
            currentEdit = edit
            player.replaceCurrentItem(with: item)
            let output = edit.timeline.nearestOutputTime(forSource: source)
            seekPlayer(to: CompositionBuilder.cmTime(output))
            playhead = edit.timeline.sourceTime(forOutput: output)
            if wasPlaying { player.rate = 1 }
        } catch {
            Log.editor.error("Preview rebuild failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func updatePreviewVideoComposition() {
        guard let media, let edit = currentEdit, let item = player.currentItem,
              let videoTrack = edit.composition.tracks(withMediaType: .video).first else { return }
        let options = previewOptions()
        let plan = RenderPlan(
            project: project,
            sourceSize: media.size,
            orientation: media.orientation,
            shortSideCap: options.shortSideCap,
            zoomEnabled: options.zoomEnabled
        )
        item.videoComposition = CompositionBuilder.makeVideoComposition(
            plan: plan,
            source: media,
            videoTrackID: videoTrack.trackID,
            duration: edit.composition.duration,
            frameRate: options.frameRate,
            force: false
        )
        // A paused player doesn't redraw by itself.
        if !isPlaying {
            seekPlayer(to: player.currentTime())
        }
    }

    private func updatePreviewAudioMix() {
        guard let media, let edit = currentEdit else { return }
        player.currentItem?.audioMix = CompositionBuilder.audioMix(for: edit.composition, source: media, volumes: project.trackVolumes)
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard media != nil else { return }
        do {
            if project.isUnedited {
                store.delete(for: sourceURL)
            } else {
                try store.save(project)
            }
        } catch {
            Log.editor.error("Couldn't save edits: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func loadExportSettings() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.videoEditorExportSettings),
              let settings = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return settings
    }

    private static func saveExportSettings(_ settings: ExportSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.videoEditorExportSettings)
    }

    // MARK: Export

    /// Output size for the current export settings.
    var exportRenderSize: CGSize {
        guard let media else { return .zero }
        let plan = switch exportSettings.format {
        case .mp4: RenderPlan(project: project, sourceSize: media.size, orientation: media.orientation, shortSideCap: exportSettings.resolution.shortSideCap)
        case .gif: RenderPlan(project: project, sourceSize: media.size, orientation: media.orientation, width: exportSettings.gif.width)
        }
        return plan.renderSize
    }

    var exportFrameRate: Int {
        switch exportSettings.format {
        case .mp4: exportSettings.frameRate.resolve(sourceFrameRate: media?.frameRate ?? 30)
        case .gif: exportSettings.gif.fps
        }
    }

    var estimatedExportBytes: Int64 {
        let size = exportRenderSize
        let content = media.flatMap {
            ExportEstimator.contentBitrate(
                sourceBitrate: $0.videoBitrate, sourceSize: $0.size, sourceFrameRate: $0.frameRate,
                renderSize: size, fps: exportFrameRate
            )
        }
        switch exportSettings.format {
        case .mp4:
            let hasAudio = audioTracks.contains { project.trackVolumes[$0.role].effectiveVolume > 0 }
            return ExportEstimator.mp4Bytes(
                renderSize: size, fps: exportFrameRate, duration: outputDuration,
                quality: exportSettings.quality, hasAudio: hasAudio, contentBitrate: content
            )
        case .gif:
            return ExportEstimator.gifBytes(renderSize: size, fps: exportFrameRate, duration: outputDuration, contentBitrate: content)
        }
    }

    var isExporting: Bool {
        if case .running = exportState { return true }
        return false
    }

    func startExport() {
        guard let media, !isExporting else { return }
        pause()
        let url: URL
        do {
            url = try ExportDestination.newFileURL(for: exportSettings.format)
        } catch {
            exportState = .failed(error.localizedDescription)
            return
        }
        let project = project
        let settings = exportSettings
        // Each run gets a generation; a cancelled run that is still winding
        // down must not overwrite the state of a newer one.
        exportGeneration += 1
        let generation = exportGeneration
        exportState = .running(progress: 0)
        let reporter = ProgressReporter { [weak self] value in
            Task { @MainActor in
                guard let self, self.exportGeneration == generation, case .running = self.exportState else { return }
                self.exportState = .running(progress: value)
            }
        }
        exportTask = Task { [weak self] in
            do {
                let result: VideoExportResult = switch settings.format {
                case .mp4:
                    try await VideoExporter.exportMP4(source: media, project: project, settings: settings, to: url, progress: reporter.report)
                case .gif:
                    try await GIFExporter.export(source: media, project: project, options: settings.gif, to: url, progress: reporter.report)
                }
                guard !Task.isCancelled, let self, self.exportGeneration == generation else {
                    // Finished just as it was cancelled: honor the cancel.
                    try? FileManager.default.removeItem(at: result.url)
                    return
                }
                self.exportState = .finished(result)
                self.onExportFinished?(result)
            } catch {
                guard let self, self.exportGeneration == generation else { return }
                if error is CancellationError {
                    self.exportState = .idle
                } else {
                    self.exportState = .failed(error.localizedDescription)
                    Log.editor.error("Export failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @ObservationIgnored private var exportGeneration = 0

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportGeneration += 1
        exportState = .idle
    }

    func resetExport() {
        if !isExporting { exportState = .idle }
    }

    /// Puts the exported file on the clipboard (VE-10).
    func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Teardown

    /// Call when the window closes: stops playback and background work and
    /// flushes the project to disk.
    func close() {
        pause()
        saveTask?.cancel()
        saveNow()
        rebuildTask?.cancel()
        exportTask?.cancel()
        analysisTasks.forEach { $0.cancel() }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// Throttles export progress callbacks (one per frame) to ~0.5 % steps
/// before they hop to the main actor.
private final class ProgressReporter: Sendable {
    private let last = Mutex<Double>(-1)
    private let deliver: @Sendable (Double) -> Void

    init(_ deliver: @escaping @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    var report: @Sendable (Double) -> Void {
        { [self] value in
            let shouldDeliver = last.withLock { previous in
                guard value >= 1 || value - previous >= 0.005 else { return false }
                previous = value
                return true
            }
            if shouldDeliver { deliver(value) }
        }
    }
}
