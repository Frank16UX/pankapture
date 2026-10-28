import AIProviders
import AppCore
import AutoEdit
import Foundation
import Transcription

/// Auto-edit actions (PRD §5.11): analysis, review toggles, pacing, and
/// adjusting items. Every change is an undoable project edit.
extension VideoEditorModel {
    /// Smart editing needs macOS 26 (ADR-31).
    var isAutoEditAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    var isAutoEditRunning: Bool {
        if case .running = autoEditState { return true }
        return false
    }

    var aiSettings: AISettings { .shared }

    /// What the next analysis is judged by: this editor's choice, else
    /// Settings ▸ AI's default; the rules when that provider isn't ready.
    var autoEditJudge: Judge {
        aiSettings.usable(judgeOverride ?? aiSettings.defaultJudge)
    }

    /// What the next analysis transcribes with (when it transcribes).
    var autoEditTranscriber: Transcriber {
        aiSettings.usable(transcriberOverride ?? aiSettings.defaultTranscriber)
    }

    /// The provider the next analysis will ask, if any.
    var autoEditProvider: ProviderConfiguration? {
        guard case .model(let choice) = autoEditJudge else { return nil }
        return aiSettings.configuration(for: choice)
    }

    /// Sets this editor's reasoning effort for its current model.
    func setAutoEditEffort(_ effort: String?) {
        guard case .model(var choice) = autoEditJudge else { return }
        choice.effort = effort
        judgeOverride = .model(choice)
    }

    /// Picks a model for this editor, with the effort recommended for it.
    func pickAutoEditModel(_ model: ModelInfo, providerID: String) {
        guard let provider = AIProvider.provider(id: providerID) else { return }
        judgeOverride = .model(ModelChoice(providerID: providerID, model: model.id,
                                           effort: aiSettings.recommendedEffort(model, provider: provider)))
    }

    // MARK: Analysis

    /// Analyzes the recording. Reuses the project's transcript (with the
    /// user's corrections) or the cached one unless `retranscribe` is set.
    func runAutoEdit(retranscribe: Bool = false) {
        guard #available(macOS 26, *) else { return }
        guard media != nil, !isAutoEditRunning else { return }
        let url = sourceURL
        let language = autoEditLanguage
        UserDefaults.standard.set(language.rawValue, forKey: PreferenceKey.autoEditLanguage)
        let provider = autoEditProvider
        let cloudService = aiSettings.cloudService(for: autoEditTranscriber)
        let cloudProviderID: String? = if case .cloud(let id, _) = autoEditTranscriber { id } else { nil }
        let transcriptAtStart = project.transcript
        let corrected = transcriptAtStart?.language == language ? transcriptAtStart : nil
        let cached = retranscribe ? nil : (corrected ?? TranscriptStore.load(for: url, language: language))
        autoEditGeneration += 1
        let generation = autoEditGeneration
        autoEditNotice = nil
        autoEditState = .running(stage: "Reading the microphone…", fraction: nil)

        // Detached: reading and analyzing audio blocks its thread.
        let work = Task.detached(priority: .userInitiated) { [weak self] () async throws -> AutoEditResult in
            // Keys are read here, off the main actor: the first read after an
            // update can wait on a Keychain prompt (ADR-41). A cached transcript
            // sends no request, so it reads no key.
            let cloud: CloudTranscription? = if cached == nil, let cloudService, let cloudProviderID {
                AISettings.cloudTranscription(service: cloudService.service, model: cloudService.model, providerID: cloudProviderID)
            } else {
                nil
            }
            if cloudService != nil, cloud == nil, cached == nil {
                throw ProviderError.missingKey(cloudService?.service.name ?? "The transcription service")
            }
            let prepared = try await AutoEditAnalyzer.prepare(recordingAt: url, language: language, transcript: cached, cloud: cloud) { progress in
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
            let name = provider.displayName
            await MainActor.run {
                guard let self, self.autoEditGeneration == generation else { return }
                self.autoEditState = .running(stage: "Asking \(name)…", fraction: nil)
            }
            let outcome = try await ModelPass.run(prepared.input, configuration: provider, apiKey: AISettings.apiKey(for: provider.presetID))
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
                    // Corrections made while it ran are newer than the copy it
                    // analyzed; keep them. Removals are time ranges, and
                    // corrections keep word times, so the two still line up.
                    let correctedMeanwhile = $0.transcript != transcriptAtStart && $0.transcript?.language == language
                    if !correctedMeanwhile { $0.transcript = result.analysis.transcript }
                }
                self.transcriptSelection = nil
                self.autoEditNotice = result.notice
                self.autoEditState = .idle
                if !result.analysis.suggestions.isEmpty || !result.analysis.pauses.isEmpty { self.autoEditPage = .review }
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
        case .transcribing: aiSettings.cloudService(for: autoEditTranscriber).map { "Transcribing with \($0.service.name)…" } ?? "Transcribing on this Mac…"
        case .analyzing: "Finding pauses and mistakes…"
        case .askingModel: "Asking the AI provider…"
        }
        let showsFraction = progress.stage == .transcribing || progress.stage == .downloadingSpeechModel
        autoEditState = .running(stage: stage, fraction: showsFraction ? progress.fraction : nil)
    }

    /// Removes auto-edit's layer: every suggestion goes; the user's own cuts stay.
    func clearAutoEdit() {
        selectedAutoItem = nil
        autoEditPage = .setup
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

    /// Selects an item and moves the playhead to just before it. Wherever
    /// it was picked (timeline or review list), the other one shows it too:
    /// the inspector opens Auto-Edit's review, the timeline scrolls to it.
    func selectAutoItem(_ item: AutoEditItem) {
        selection = nil
        selectedCut = nil
        selectedZoomID = nil
        selectedCameraLayoutID = nil
        transcriptSelection = nil
        selectedAutoItem = item
        inspectorSection = .autoEdit
        autoEditPage = .review
        if let range = project.autoEdit?.range(of: item) {
            revealOnTimeline(range)
            seek(toSource: max(0, range.start - 0.6))
        }
    }

    /// Selects the suggestion `offset` places after (or before) the selected
    /// one in `items`, for stepping through the review one at a time.
    func selectAutoItem(after offset: Int, in items: [AutoEditItem]) {
        guard !items.isEmpty else { return }
        let index = selectedAutoItem.flatMap(items.firstIndex(of:)).map { $0 + offset } ?? (offset > 0 ? 0 : items.count - 1)
        selectAutoItem(items[index.clamped(to: 0...(items.count - 1))])
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
