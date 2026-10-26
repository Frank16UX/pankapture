import AIProviders
import AppCore
import AVFoundation
import Foundation
import Transcription

/// Runs auto-edit on a recording (PRD §5.11): reads the microphone track,
/// transcribes it on device, finds pauses and what the screen did during
/// them, and applies the rules. `ModelPass` then refines the judgments when
/// a provider is configured. macOS 26+ (on-device transcription).
@available(macOS 26, *)
public enum AutoEditAnalyzer {
    public enum Stage: String, Sendable {
        case readingAudio
        case downloadingSpeechModel
        case transcribing
        case analyzing
        case askingModel
    }

    public struct Progress: Sendable {
        public var stage: Stage
        /// 0…1 within the stage.
        public var fraction: Double
    }

    public struct Prepared: Sendable {
        public var input: AutoEditInput
        /// The microphone's level, for snapping cuts to quiet points (AE-9).
        public var envelope: LoudnessEnvelope
        public var microphoneLabel: String
    }

    /// Everything up to (not including) the model pass.
    ///
    /// - Parameters:
    ///   - transcript: an earlier transcript (cached, or corrected by the
    ///     user); skips transcription.
    ///   - clicks: click times in source seconds; defaults to the recording's sidecar.
    ///   - cloud: a speech-to-text service to use instead of the on-device
    ///     one (PRD AI-5; it receives the microphone audio).
    public static func prepare(
        recordingAt url: URL,
        language: TranscriptLanguage,
        transcript cached: Transcript? = nil,
        clicks: [Double]? = nil,
        cloud: (service: CloudTranscriptionService, apiKey: String)? = nil,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Prepared {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("autoEditPrepare", id: signpostID)
        defer { Log.signposter.endInterval("autoEditPrepare", interval) }

        progress(Progress(stage: .readingAudio, fraction: 0))
        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pankapture-AutoEdit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let audio = try await MicrophoneAudio.extract(from: url, to: workDirectory.appendingPathComponent("microphone.caf"))

        let transcript: Transcript
        if let cached, cached.language == language {
            transcript = cached
        } else if let cloud {
            progress(Progress(stage: .transcribing, fraction: 0))
            transcript = try await CloudTranscriber.transcribe(
                audioFileAt: audio.url, language: language, service: cloud.service, apiKey: cloud.apiKey, timeOffset: audio.startTime
            )
        } else {
            guard let locale = await OnDeviceTranscriber.locale(for: language) else {
                throw OnDeviceTranscriber.Failure.languageUnavailable(language)
            }
            if await OnDeviceTranscriber.modelState(for: locale) != .installed {
                progress(Progress(stage: .downloadingSpeechModel, fraction: 0))
                try await OnDeviceTranscriber.installModel(for: locale) { progress(Progress(stage: .downloadingSpeechModel, fraction: $0)) }
            }
            progress(Progress(stage: .transcribing, fraction: 0))
            transcript = try await OnDeviceTranscriber.transcribe(
                audioFileAt: audio.url, language: language, timeOffset: audio.startTime
            ) { progress(Progress(stage: .transcribing, fraction: $0)) }
        }

        progress(Progress(stage: .analyzing, fraction: 0))
        let detection = PauseDetector.detect(words: transcript.words, envelope: audio.envelope)
        let clickTimes = clicks ?? RecordingSidecar.load(for: url)?.clicks.map(\.time) ?? []
        let activity = await ScreenActivityProbe.measure(
            asset: AVURLAsset(url: url), pauses: detection.pauses.map(\.range), clicks: clickTimes
        )
        var pauses = detection.pauses
        for index in pauses.indices { pauses[index].activity = activity[index] }
        pauses = RuleBasedEditor.classify(pauses, transcript: transcript)
        let suggestions = RuleBasedEditor.suggestions(for: transcript, voicedGaps: detection.voicedGaps, envelope: audio.envelope)
        progress(Progress(stage: .analyzing, fraction: 1))

        let input = AutoEditInput(
            transcript: transcript, pauses: pauses, ruleSuggestions: suggestions,
            duration: audio.startTime + audio.duration
        )
        return Prepared(input: input, envelope: audio.envelope, microphoneLabel: audio.trackLabel)
    }

    /// The full analysis: rules, then the provider's judgment if one is given.
    public static func analyze(
        recordingAt url: URL,
        language: TranscriptLanguage,
        transcript: Transcript? = nil,
        provider: (configuration: ProviderConfiguration, apiKey: String?)? = nil,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> (analysis: AutoEditAnalysis, prepared: Prepared, modelError: String?) {
        let prepared = try await prepare(recordingAt: url, language: language, transcript: transcript, progress: progress)
        guard let provider else { return (AutoEditAnalysis(rulesOnly: prepared.input), prepared, nil) }
        progress(Progress(stage: .askingModel, fraction: 0))
        let outcome = try await ModelPass.run(prepared.input, configuration: provider.configuration, apiKey: provider.apiKey)
        progress(Progress(stage: .askingModel, fraction: 1))
        return (outcome.analysis, prepared, outcome.error)
    }
}
