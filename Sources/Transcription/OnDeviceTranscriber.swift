import AppCore
import AVFoundation
import Foundation
import Speech

/// Transcribes an audio file on device with `SpeechAnalyzer` + `SpeechTranscriber`
/// (macOS 26+, ADR-31): word timings and confidence, no permission prompt,
/// nothing leaves the Mac. Language models download on first use and are
/// shared with other apps.
@available(macOS 26, *)
public enum OnDeviceTranscriber {
    public static let engineName = Transcript.onDeviceEngine

    public enum Failure: LocalizedError {
        case languageUnavailable(TranscriptLanguage)
        case modelUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .languageUnavailable(let language):
                "On-device transcription isn't available for \(language.englishName) on this Mac."
            case .modelUnavailable(let locale):
                "The speech model for \(locale) couldn't be installed."
            }
        }
    }

    /// The recognizer locale for `language`: the user's region when the
    /// recognizer has it (es-MX, en-GB…), otherwise a common default.
    public static func locale(for language: TranscriptLanguage, region: Locale.Region? = Locale.current.region) async -> Locale? {
        var candidates: [Locale] = []
        if let region { candidates.append(Locale(identifier: "\(language.rawValue)-\(region.identifier)")) }
        candidates += fallbackLocales[language, default: []].map(Locale.init(identifier:))
        for candidate in candidates {
            if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) { return supported }
        }
        return nil
    }

    private static let fallbackLocales: [TranscriptLanguage: [String]] = [
        .english: ["en-US", "en-GB"],
        .spanish: ["es-MX", "es-US", "es-ES"],
    ]

    /// Whether the speech model for `locale` is installed, and if not, whether
    /// it can be downloaded.
    public enum ModelState: Sendable, Equatable {
        case installed
        case downloadable
        case unsupported
    }

    public static func modelState(for locale: Locale) async -> ModelState {
        switch await AssetInventory.status(forModules: [makeTranscriber(locale: locale)]) {
        case .installed: .installed
        case .supported, .downloading: .downloadable
        default: .unsupported
        }
    }

    /// Downloads and installs the speech model for `locale` if it's missing.
    /// `progress` gets 0…1 (the system doesn't report bytes).
    public static func installModel(for locale: Locale, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let transcriber = makeTranscriber(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let reporter = request.progress
        let monitor = Task {
            while !Task.isCancelled {
                progress(reporter.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { monitor.cancel() }
        try await request.downloadAndInstall()
        progress(1)
        guard await modelState(for: locale) == .installed else {
            throw Failure.modelUnavailable(locale.identifier)
        }
    }

    /// Transcribes `url` (any format `AVAudioFile` reads). Word times are
    /// offset by `timeOffset`, so they land in the recording's timeline when
    /// the file starts later than the movie. Installs the model if needed.
    ///
    /// - Parameter progress: 0…1 while transcribing.
    public static func transcribe(
        audioFileAt url: URL,
        language: TranscriptLanguage,
        timeOffset: Double = 0,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Transcript {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("transcribe", id: signpostID)
        defer { Log.signposter.endInterval("transcribe", interval) }

        guard let locale = await locale(for: language) else { throw Failure.languageUnavailable(language) }
        if await modelState(for: locale) != .installed {
            try await installModel(for: locale)
        }

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / max(1, file.processingFormat.sampleRate)
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let results = transcriber.results
        let collector = Task { () throws -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in results {
                words += Self.words(in: result.text, offset: timeOffset)
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }

        do {
            if let last = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        progress(1)
        Log.editor.info("Transcribed \(words.count) words (\(locale.identifier, privacy: .public))")
        return Transcript(language: language, localeIdentifier: locale.identifier, engine: engineName, words: words)
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    /// Words from one result. Each timed run is a word; untimed runs (stray
    /// punctuation) attach to the word before. A timed run holding several
    /// tokens is split, its time shared out by length.
    static func words(in text: AttributedString, offset: Double) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let string = String(text[run.range].characters)
            let tokens = string.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            guard let timeRange = run.audioTimeRange, timeRange.duration.seconds.isFinite else {
                if !words.isEmpty { words[words.count - 1].text += tokens.joined() }
                continue
            }
            let start = timeRange.start.seconds + offset
            let end = timeRange.end.seconds + offset
            let confidence = run.transcriptionConfidence
            let totalLength = Double(tokens.reduce(0) { $0 + $1.count })
            var cursor = start
            for (index, token) in tokens.enumerated() {
                let share = totalLength > 0 ? Double(token.count) / totalLength : 1 / Double(tokens.count)
                let tokenEnd = index == tokens.count - 1 ? end : cursor + (end - start) * share
                words.append(TranscriptWord(text: token, start: cursor, end: tokenEnd, confidence: confidence))
                cursor = tokenEnd
            }
        }
        return words
    }
}
