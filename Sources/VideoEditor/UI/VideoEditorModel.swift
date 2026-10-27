import AppCore
import AppKit
import AutoEdit
import AVFoundation
import Observation
import Synchronization
import Transcription

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
    /// The project as last saved (VE-12); edits beyond it are unsaved.
    private(set) var savedProject: VideoEditProject
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Playhead in **source** seconds (the timeline shows the whole source).
    private(set) var playhead: Double = 0
    private(set) var isPlaying = false
    /// Range selected on the timeline (source seconds), for Cut and Speed.
    /// One thing is selected at a time: selecting a range, cut, or zoom
    /// deselects auto-edit's item, so ⌫ and [ ] act on what's visible.
    var selection: TimeRange? {
        didSet { if selection != nil { selectedAutoItem = nil } }
    }
    var selectedCut: TimeRange? {
        didSet { if selectedCut != nil { selectedAutoItem = nil } }
    }
    /// The zoom being edited. While set, the preview shows the unzoomed frame
    /// so the user can position the zoom rectangle over it.
    var selectedZoomID: ZoomSegment.ID? {
        didSet {
            guard oldValue != selectedZoomID else { return }
            if selectedZoomID != nil { selectedAutoItem = nil }
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
    /// What the running (or last) export is making, e.g. "MP4 · 1920 × 1080 · 60 fps".
    private(set) var exportDescription = ""
    /// When the running export started, for the time-left estimate.
    private(set) var exportStartDate: Date?
    var isShowingExportSheet = false

    // MARK: Auto-edit (PRD §5.11; actions in VideoEditorModel+AutoEdit.swift)

    enum AutoEditState: Equatable {
        case idle
        case running(stage: String, fraction: Double?)
        case failed(String)
    }

    var autoEditState: AutoEditState = .idle
    /// Why the provider's answer wasn't used, or what its checks dropped.
    var autoEditNotice: String?
    var autoEditLanguage: TranscriptLanguage
    /// The auto-edit pause or removal selected on the timeline or in the review list.
    var selectedAutoItem: AutoEditItem?
    /// Words selected in the transcript panel (PRD AE-10).
    var transcriptSelection: ClosedRange<Int>?
    /// Words being corrected in the transcript's popover (CAP-2).
    var wordsBeingCorrected: ClosedRange<Int>?

    // MARK: Panels (VE-14, VE-15)

    /// The one inspector pane on screen. Selecting something on the
    /// timeline shows the pane that edits it.
    var inspectorSection: InspectorSection = .background
    var autoEditPage: AutoEditPage = .setup
    /// What part of the source the timeline shows.
    var timelineViewport = TimelineViewport()

    enum VoiceState: Equatable {
        case idle
        case processing(Double)
        case failed(String)
    }

    /// Voice cleanup (PRD AU-3): processing runs in the background; the
    /// preview uses the original voice until the cleaned one is ready.
    private(set) var voiceState: VoiceState = .idle
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    /// Each voice change gets a number; only the latest may touch the state.
    @ObservationIgnored private var voiceRun = 0
    @ObservationIgnored private var waveformTasks: [CMPersistentTrackID: Task<Void, Never>] = [:]
    @ObservationIgnored var autoEditTask: Task<Void, Never>?
    /// Each analysis run gets a generation; a cancelled run that is still
    /// winding down must not touch the state of a newer one.
    @ObservationIgnored var autoEditGeneration = 0

    @ObservationIgnored var onExportFinished: ((VideoExportResult) -> Void)?
    /// Called when `hasUnsavedChanges` flips (the window's edited dot).
    @ObservationIgnored var onUnsavedChangesChanged: ((Bool) -> Void)?
    /// The loaded background movie when the fill is one (rebuilds need its track).
    @ObservationIgnored private var backgroundVideo: BackgroundVideo?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
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
        let empty = VideoEditProject(sourceURL: url, sourceDuration: 0)
        project = empty
        savedProject = empty
        exportSettings = Self.loadExportSettings()
        autoEditLanguage = UserDefaults.standard.string(forKey: PreferenceKey.autoEditLanguage)
            .flatMap(TranscriptLanguage.init(rawValue:)) ?? .preferred
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        inspectorSection = isAutoEditAvailable ? .autoEdit : .background
    }

    // MARK: Loading

    var duration: Double { project.sourceDuration }
    var timeline: Timeline { currentEdit?.timeline ?? project.timeline }
    var outputDuration: Double { project.timeline.outputDuration }
    var audioTracks: [AudioTrackInfo] { media?.audioTracks ?? [] }
    /// Audio tracks worth showing: a silent one (system audio when no app
    /// made a sound) is hidden. It stays in the mix; it's silent anyway.
    var visibleAudioTracks: [AudioTrackInfo] {
        audioTracks.filter { waveforms[$0.trackID]?.isSilent != true }
    }
    var silentAudioTracks: [AudioTrackInfo] {
        audioTracks.filter { waveforms[$0.trackID]?.isSilent == true }
    }
    var clickCount: Int { sidecar?.clicks.count ?? 0 }
    var selectedZoom: ZoomSegment? { project.zooms.first { $0.id == selectedZoomID } }
    var hasUnsavedChanges: Bool { media != nil && project != savedProject }

    /// Preview render plan (for overlay geometry: canvas and video rect).
    var previewPlan: RenderPlan? {
        guard let media else { return nil }
        return RenderPlan(
            project: project, sourceSize: media.size, orientation: media.orientation, shortSideCap: 1080,
            hasCameraTrack: media.camera != nil, cameraOrientation: media.camera?.orientation ?? .up
        )
    }

    func load() async {
        do {
            let media = try await SourceMedia.load(url: sourceURL)
            tracks = try await media.loadTracks()
            let sidecar = RecordingSidecar.load(for: sourceURL)
            var saved = store.load(for: sourceURL, sourceDuration: media.duration)
                ?? VideoEditProject.initial(for: media, sidecar: sidecar)
            saved.adapt(toSourceDuration: media.duration)
            if media.camera != nil, saved.camera == nil { saved.camera = sidecar?.camera.map(CameraOverlay.init) ?? .standard }
            savedProject = saved
            // Edits left unsaved by a crash come back as unsaved changes.
            if var draft = store.loadDraft(for: sourceURL, sourceDuration: media.duration) {
                draft.adapt(toSourceDuration: media.duration)
                project = draft
            } else {
                project = saved
            }
            self.media = media
            if let language = project.autoEdit?.language { autoEditLanguage = language }
            notifyUnsavedChanges()
            self.sidecar = sidecar
            if let url = project.background.fill.videoURL {
                backgroundVideo = try? await BackgroundVideo.load(url: url)
            }
            rebuildPlayerItem(seekToSource: project.trim.start)
            startAnalysis(media)
            if project.voice?.isActive == true { updateVoice() }
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
            loadWaveform(for: track, asset: asset, trackID: track.trackID, startTime: nil)
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
        if let item = selectedAutoItem, updated.autoEdit?.range(of: item) == nil { selectedAutoItem = nil }

        // Timelines compare by their segments (auto-edit derives cuts and speeds).
        let timelineChanged = Timeline(project: old) != Timeline(project: updated)
        if old.background.fill.videoURL != updated.background.fill.videoURL {
            // A background movie is a track of the composition.
            loadBackgroundVideo(updated.background.fill.videoURL)
        } else if timelineChanged {
            // Rebuilding the player item on every drag tick is wasteful; the
            // timeline redraws immediately and the preview follows shortly.
            scheduleRebuild(delay: isContinuousEdit ? .milliseconds(200) : .zero)
        } else if old.background != updated.background || old.zoomFillsFrame != updated.zoomFillsFrame || old.camera != updated.camera
                    || old.captions != updated.captions || (updated.captions?.isEnabled == true && old.transcript != updated.transcript)
                    || (old.zooms != updated.zooms && selectedZoomID == nil) {
            // While a zoom is being edited the preview ignores zooms, so
            // dragging its rectangle doesn't need a new video composition.
            updatePreviewVideoComposition()
        }
        if old.trackVolumes != updated.trackVolumes { updatePreviewAudioMix() }
        if old.voice != updated.voice { updateVoice() }
        scheduleSave()
        notifyUnsavedChanges()
    }

    @ObservationIgnored private var reportedUnsavedChanges = false

    private func notifyUnsavedChanges() {
        let value = hasUnsavedChanges
        guard value != reportedUnsavedChanges else { return }
        reportedUnsavedChanges = value
        onUnsavedChangesChanged?(value)
    }

    private func loadBackgroundVideo(_ url: URL?) {
        backgroundTask?.cancel()
        guard let url else {
            backgroundVideo = nil
            scheduleRebuild(delay: .zero)
            return
        }
        backgroundTask = Task { [weak self] in
            let video: BackgroundVideo?
            do {
                video = try await BackgroundVideo.load(url: url)
            } catch {
                Log.editor.error("Background video unavailable: \(error.localizedDescription, privacy: .public)")
                video = nil
            }
            guard !Task.isCancelled, let self else { return }
            self.backgroundVideo = video
            self.rebuildPlayerItem(seekToSource: self.playhead)
        }
    }

    /// Uses a picture or movie file as the background (copied into the app's library).
    func setBackgroundMedia(_ url: URL) {
        do {
            let fill = try BackgroundLibrary.importFile(url)
            edit { $0.background.fill = fill }
        } catch {
            mediaImportError = error.localizedDescription
            Log.editor.error("Background import failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var mediaImportError: String?

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

    /// Splits the footage at the playhead (VE-3); the parts can then be
    /// selected and deleted.
    func splitAtPlayhead() {
        edit { $0.addSplit(at: playhead) }
    }

    /// Clicking the filmstrip selects the segment under the pointer once the
    /// footage is split (so Delete removes it); returns whether it did.
    @discardableResult
    func selectSegment(at time: Double) -> Bool {
        let segments = project.segments
        guard segments.count > 1, let segment = segments.first(where: { $0.contains(time) }) else {
            selection = nil
            return false
        }
        selection = segment
        return true
    }

    func setTrimInAtPlayhead() { edit { $0.setTrimStart(playhead) } }
    func setTrimOutAtPlayhead() { edit { $0.setTrimEnd(playhead) } }

    func addZoomAtPlayhead() {
        var added: ZoomSegment?
        edit { added = $0.addZoom(at: playhead) }
        selectedZoomID = added?.id
        if added != nil { inspectorSection = .zoom }
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
    /// For an auto-edit item, ⌫ restores what it removed (AE-8).
    func deleteSelected() {
        if let words = transcriptSelection {
            cutWords(words)
        } else if let item = selectedAutoItem {
            restoreAutoItem(item)
        } else if selectedZoomID != nil {
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
        selectedAutoItem = nil
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
        // Page the zoomed timeline along with playback. Copy first, so
        // observers only hear about real moves.
        if isPlaying, timelineViewport.isZoomed {
            var viewport = timelineViewport
            if viewport.follow(playhead: playhead, duration: duration) { timelineViewport = viewport }
        }
    }

    // MARK: Voice cleanup (PRD AU-1–AU-3)

    var microphoneTrack: AudioTrackInfo? { media?.audioTracks.first { $0.role == .microphone } }

    /// Makes the preview match `project.voice`: processes the microphone in
    /// the background (or takes it from the cache) and swaps it in. Until a
    /// new setting is ready, the original voice plays.
    private func updateVoice() {
        voiceTask?.cancel()
        voiceRun += 1
        guard media != nil, let microphone = microphoneTrack else { return }
        let settings = project.voice
        let cached = settings.flatMap { $0.isActive ? VoiceProcessor.cached(for: sourceURL, settings: $0) : nil }
        if cached == nil, tracks?.processedVoice != nil {
            tracks?.processedVoice = nil
            rebuildPlayerItem(seekToSource: playhead)
            loadWaveform(for: microphone, asset: AVURLAsset(url: sourceURL), trackID: microphone.trackID, startTime: nil)
        }
        guard let settings, settings.isActive else {
            voiceState = .idle
            return
        }
        let url = sourceURL
        let run = voiceRun
        voiceState = .processing(0)
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            try await VoiceProcessor.process(source: url, microphoneTrackID: microphone.trackID, settings: settings) { fraction in
                Task { @MainActor in
                    guard let self, self.voiceRun == run, case .processing = self.voiceState else { return }
                    self.voiceState = .processing(fraction)
                }
            }
        }
        voiceTask = Task { [weak self] in
            do {
                let output = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                let voice = try await ProcessedVoice.load(output)
                // A newer change may have come in during either wait.
                guard let self, !Task.isCancelled, self.voiceRun == run, self.project.voice == settings else { return }
                self.tracks?.processedVoice = voice
                self.voiceState = .idle
                self.rebuildPlayerItem(seekToSource: self.playhead)
                self.loadWaveform(for: microphone, asset: voice.asset, trackID: voice.track.trackID, startTime: voice.startTime)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, self.voiceRun == run else { return }
                self.voiceState = .failed(error.localizedDescription)
                Log.editor.error("Voice processing failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Draws a lane's waveform from `asset` (the recording, or the processed
    /// voice placed at `startTime`). A newer request for the lane replaces
    /// an older one still running.
    private func loadWaveform(for lane: AudioTrackInfo, asset: AVURLAsset, trackID: CMPersistentTrackID, startTime: Double?) {
        waveformTasks[lane.trackID]?.cancel()
        let extraction = Task.detached(priority: .utility) {
            try await WaveformExtractor.waveform(asset: asset, trackID: trackID)
        }
        waveformTasks[lane.trackID] = Task { [weak self] in
            let extracted = try? await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            guard let self, !Task.isCancelled, var waveform = extracted else { return }
            if let startTime {
                waveform = Waveform(startTime: waveform.startTime + startTime, bucketDuration: waveform.bucketDuration,
                                    peaks: waveform.peaks, loudestPeak: waveform.loudestPeak)
            }
            self.waveforms[lane.trackID] = waveform
        }
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
            let edit = try CompositionBuilder.build(
                source: media, tracks: tracks, project: project, options: previewOptions(), background: backgroundVideo
            )
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
              let videoTrack = edit.composition.tracks(withMediaType: .video).first(where: {
                  $0.trackID != edit.cameraTrackID && $0.trackID != edit.backgroundTrackID
              }) else { return }
        let options = previewOptions()
        let plan = RenderPlan(
            project: project,
            sourceSize: media.size,
            orientation: media.orientation,
            shortSideCap: options.shortSideCap,
            zoomEnabled: options.zoomEnabled,
            backgroundOrientation: backgroundVideo?.orientation ?? .up,
            hasCameraTrack: edit.cameraTrackID != nil,
            cameraOrientation: media.camera?.orientation ?? .up,
            cameraMatteQuality: options.cameraMatteQuality
        )
        item.videoComposition = CompositionBuilder.makeVideoComposition(
            plan: plan,
            source: media,
            videoTrackID: videoTrack.trackID,
            backgroundTrackID: edit.backgroundTrackID,
            cameraTrackID: edit.cameraTrackID,
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
        player.currentItem?.audioMix = CompositionBuilder.audioMix(
            for: edit.composition, source: media, volumes: project.trackVolumes, timeline: edit.timeline
        )
    }

    // MARK: Persistence

    /// Autosaves unsaved edits to the draft file, for crash recovery.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDraftNow()
        }
    }

    private func saveDraftNow() {
        guard media != nil else { return }
        guard hasUnsavedChanges else {
            store.deleteDraft(for: sourceURL)
            return
        }
        do {
            try store.saveDraft(project)
        } catch {
            Log.editor.error("Couldn't autosave edits: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Saves the edits as the recording's project (⌘S). Returns `false` if
    /// writing failed (the error is logged and shown).
    @discardableResult
    func save() -> Bool {
        guard media != nil else { return true }
        saveTask?.cancel()
        do {
            if project == VideoEditProject(sourceURL: project.sourceURL, sourceDuration: project.sourceDuration) {
                store.delete(for: sourceURL)
            } else {
                try store.save(project)
            }
            store.deleteDraft(for: sourceURL)
            savedProject = project
            notifyUnsavedChanges()
            return true
        } catch {
            saveError = error.localizedDescription
            Log.editor.error("Couldn't save edits: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    var saveError: String?

    /// Drops unsaved edits (closing with "Don't Save").
    func discardChanges() {
        saveTask?.cancel()
        store.deleteDraft(for: sourceURL)
        cancelContinuousEdit()
        if project != savedProject { apply(savedProject) }
        history = UndoHistory<VideoEditProject>()
        refreshUndoState()
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
        case .mp4: RenderPlan(project: project, sourceSize: media.size, orientation: media.orientation, shortSide: exportSettings.resolution.shortSide)
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
        exportStartDate = .now
        let size = exportRenderSize
        exportDescription = settings.format == .mp4
            ? "\(settings.format.title) · \(Int(size.width)) × \(Int(size.height)) · \(exportFrameRate) fps"
            : "\(settings.format.title) · \(Int(size.width)) px wide · \(settings.gif.fps) fps"
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
                if settings.format == .mp4 { Self.writeCaptionsFile(for: project, nextTo: result.url) }
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

    /// Saves the captions as `.srt` or `.vtt` beside an MP4 export (CAP-4),
    /// timed like the exported video.
    nonisolated static func writeCaptionsFile(for project: VideoEditProject, nextTo video: URL) {
        guard let settings = project.captions, settings.isEnabled, settings.fileFormat != .none,
              let words = project.transcript?.words else { return }
        let cues = CaptionBuilder.cues(words: words, timeline: project.timeline)
        let (text, fileExtension) = settings.fileFormat == .srt ? (CaptionBuilder.srt(cues), "srt") : (CaptionBuilder.vtt(cues), "vtt")
        let url = video.deletingPathExtension().appendingPathExtension(fileExtension)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.editor.error("Couldn't save the captions file: \(error.localizedDescription, privacy: .public)")
        }
    }

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
        // Whatever is still unsaved stays in the draft (offered next time).
        saveDraftNow()
        rebuildTask?.cancel()
        backgroundTask?.cancel()
        exportTask?.cancel()
        autoEditTask?.cancel()
        voiceTask?.cancel()
        waveformTasks.values.forEach { $0.cancel() }
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
