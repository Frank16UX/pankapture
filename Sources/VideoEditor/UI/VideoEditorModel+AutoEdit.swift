import AIProviders
import AppCore
import AutoEdit
import Foundation
import Transcription

/// Auto-edit actions (PRD §5.11): analysis, review toggles, pacing, and
/// adjusting items. Every change is an undoable project edit.
extension VideoEditorModel {
    /// Smart editing needs macOS 26 (ADR-30).
    var isAutoEditAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var isAutoEditRunning: Bool {
        if case .running = autoEditState { return true }
        return false
    }

    /// The provider the next analysis will ask (Settings ▸ AI), if any.
    var autoEditProvider: ProviderConfiguration? {
        ProviderSettings.active()?.configuration
    }

    // MARK: Analysis

    func runAutoEdit() {
        guard #available(macOS 26, *) else { return }
        guard media != nil, !isAutoEditRunning else { return }
        let url = sourceURL
        let language = autoEditLanguage
        UserDefaults.standard.set(language.rawValue, forKey: PreferenceKey.autoEditLanguage)
        let provider = ProviderSettings.active()
        let cached = TranscriptStore.load(for: url, language: language)
        autoEditGeneration += 1
        let generation = autoEditGeneration
        autoEditNotice = nil
        autoEditState = .running(stage: "Reading the microphone…", fraction: nil)

        // Detached: reading and analyzing audio blocks its thread.
        let work = Task.detached(priority: .userInitiated) { [weak self] () async throws -> AutoEditResult in
            let prepared = try await AutoEditAnalyzer.prepare(recordingAt: url, language: language, transcript: cached) { progress in
                Task { @MainActor in self?.showAutoEditProgress(progress, language: language, generation: generation) }
            }
            if cached == nil {
                do {
                    try TranscriptStore.save(prepared.input.transcript, for: url)
                } catch {
                    Log.editor.error("Couldn't cache the transcript: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let provider else {
                return AutoEditResult(analysis: AutoEditAnalysis(rulesOnly: prepared.input), envelope: prepared.envelope, judgedBy: "Built-in rules", notice: nil)
            }
            let name = provider.configuration.displayName
            await MainActor.run {
                guard let self, self.autoEditGeneration == generation else { return }
                self.autoEditState = .running(stage: "Asking \(name)…", fraction: nil)
            }
            let outcome = try await ModelPass.run(prepared.input, configuration: provider.configuration, apiKey: provider.apiKey)
            if let error = outcome.error {
                return AutoEditResult(analysis: outcome.analysis, envelope: prepared.envelope, judgedBy: "Built-in rules",
                                      notice: "\(name) couldn't be used, so the built-in rules made these suggestions. \(error)")
            }
            let notice = outcome.report.warnings.isEmpty ? nil : outcome.report.warnings.joined(separator: " ")
            return AutoEditResult(analysis: outcome.analysis, envelope: prepared.envelope, judgedBy: name, notice: notice)
        }

        autoEditTask = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, !Task.isCancelled, self.autoEditGeneration == generation else { return }
                // Re-runs renumber pauses: an old selection would point elsewhere.
                self.selectedAutoItem = nil
                self.edit {
                    $0.autoEdit = AutoEditLayer(analysis: result.analysis, envelope: result.envelope, language: language,
                                                judgedBy: result.judgedBy, keeping: $0.autoEdit)
                }
                self.autoEditNotice = result.notice
                self.autoEditState = .idle
                let count = result.analysis.suggestions.count
                Log.editor.info("Auto-edit: \(count) suggestions, \(result.analysis.pauses.count) pauses (\(result.judgedBy, privacy: .public))")
            } catch {
                guard let self, self.autoEditGeneration == generation else { return }
                if error is CancellationError || Task.isCancelled {
                    self.autoEditState = .idle
                } else {
                    self.autoEditState = .failed(error.localizedDescription)
                    Log.editor.error("Auto-edit failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func cancelAutoEdit() {
        autoEditTask?.cancel()
        autoEditTask = nil
        autoEditGeneration += 1
        autoEditState = .idle
    }

    @available(macOS 26, *)
    private func showAutoEditProgress(_ progress: AutoEditAnalyzer.Progress, language: TranscriptLanguage, generation: Int) {
        guard isAutoEditRunning, autoEditGeneration == generation else { return }
        let stage = switch progress.stage {
        case .readingAudio: "Reading the microphone…"
        case .downloadingSpeechModel: "Downloading the \(language.englishName) speech model…"
        case .transcribing: "Transcribing on this Mac…"
        case .analyzing: "Finding pauses and mistakes…"
        case .askingModel: "Asking the AI provider…"
        }
        let showsFraction = progress.stage == .transcribing || progress.stage == .downloadingSpeechModel
        autoEditState = .running(stage: stage, fraction: showsFraction ? progress.fraction : nil)
    }

    /// Removes auto-edit's layer: every suggestion goes; the user's own cuts stay.
    func clearAutoEdit() {
        selectedAutoItem = nil
        edit { $0.autoEdit = nil }
    }

    // MARK: Review (AE-7)

    func setAutoEditGroup(_ group: AutoEditGroup, isOn: Bool) {
        edit { project in
            if isOn { project.autoEdit?.groups.insert(group) } else { project.autoEdit?.groups.remove(group) }
        }
    }

    func setPacing(_ pacing: Pacing) {
        UserDefaults.standard.set(pacing.rawValue, forKey: PreferenceKey.autoEditPacing)
        edit { $0.autoEdit?.pacing = pacing }
    }

    func setActionSpeed(_ rate: Double?) {
        edit { $0.autoEdit?.actionSpeed = rate }
    }

    func setRemoval(_ id: UUID, isEnabled: Bool) {
        edit { project in
            guard let index = project.autoEdit?.removals.firstIndex(where: { $0.id == id }) else { return }
            project.autoEdit?.removals[index].isEnabled = isEnabled
            project.autoEdit?.removals[index].isUserEdited = true
        }
    }

    /// "Keep as is" (AE-8): the pause is never shortened.
    func setPause(_ id: Int, keepsLength: Bool) {
        edit { project in
            guard let index = project.autoEdit?.pauses.firstIndex(where: { $0.id == id }) else { return }
            project.autoEdit?.pauses[index].keepsLength = keepsLength
            if keepsLength { project.autoEdit?.pauses[index].adjustedCut = nil }
        }
    }

    /// The user's own judgment of a pause, which pacing then applies.
    func setPauseKind(_ id: Int, kind: PauseKind) {
        edit { project in
            guard let index = project.autoEdit?.pauses.firstIndex(where: { $0.id == id }) else { return }
            project.autoEdit?.pauses[index].pause.kind = kind
            project.autoEdit?.pauses[index].pause.kindSource = .user
            project.autoEdit?.pauses[index].adjustedCut = nil
            project.autoEdit?.pauses[index].keepsLength = false
        }
    }

    /// Selects an item and plays from just before it.
    func selectAutoItem(_ item: AutoEditItem) {
        selection = nil
        selectedCut = nil
        selectedZoomID = nil
        selectedAutoItem = item
        if let range = project.autoEdit?.range(of: item) {
            seek(toSource: max(0, range.start - 0.6))
        }
    }

    /// ⌫ on an item: brings back what it removed.
    func restoreAutoItem(_ item: AutoEditItem) {
        switch item {
        case .pause(let id): setPause(id, keepsLength: true)
        case .removal(let id): setRemoval(id, isEnabled: false)
        }
    }

    // MARK: Adjusting edges (AE-8)

    /// Moves an edge of an auto-edit item (timeline handles).
    func moveAutoItemEdge(_ item: AutoEditItem, start: Bool, to time: Double) {
        edit { $0.autoEdit?.setEdge(of: item, start: start, to: time.clamped(to: 0...duration)) }
    }

    /// Moves an edge of one of the user's cuts; the selection follows it.
    /// Edges stop at the neighbouring cuts, so dragging never merges (and
    /// then truncates) another cut.
    func moveCutEdge(_ cut: TimeRange, start: Bool, to time: Double) {
        // Touching cuts merge (`TimeRange.merged`), so stop just short of a neighbour.
        let gap = 0.02
        let others = project.cuts.filter { $0 != cut }
        let lower = others.filter { $0.end <= cut.start }.map { $0.end + gap }.max() ?? 0
        let upper = others.filter { $0.start >= cut.end }.map { $0.start - gap }.min() ?? duration
        var resized = cut
        if start {
            resized.start = min(max(time, lower), cut.end - 0.05)
        } else {
            resized.end = max(min(time, upper), cut.start + 0.05)
        }
        guard let clamped = resized.clamped(to: project.fullRange) else { return }
        var applied = false
        edit { project in
            project.removeCut(cut)
            applied = project.addCut(clamped)
            if !applied { project.cuts = TimeRange.merged(project.cuts + [cut]) }
        }
        if applied { selectedCut = project.cuts.first { $0.overlaps(clamped) } }
    }

    /// `[` and `]`: moves the start or end of the selected cut (the user's
    /// or auto-edit's) to the playhead.
    func setSelectedEdgeToPlayhead(start: Bool) {
        if let item = selectedAutoItem {
            moveAutoItemEdge(item, start: start, to: playhead)
        } else if let cut = selectedCut {
            moveCutEdge(cut, start: start, to: playhead)
        }
    }
}

/// What a finished analysis hands back to the main actor.
struct AutoEditResult: Sendable {
    var analysis: AutoEditAnalysis
    var envelope: LoudnessEnvelope
    var judgedBy: String
    var notice: String?
}
