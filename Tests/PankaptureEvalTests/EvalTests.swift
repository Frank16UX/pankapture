import AIProviders
import AppCore
import Foundation
import Testing
import Transcription
@testable import AutoEdit
@testable import PankaptureEval

@Suite("Labels")
struct LabelTests {
    @Test func parsesTheDocumentedFormat() throws {
        let text = """
        start\tend\tkind\tnote
        # a comment
        0:12.4\t0:15.1\tretake\t"April. Wait, sorry, I meant" → keeps "May"

        1:02.0\t1:04.8\tfalse_start\t"So what we're going to—"
        2:10.5\t2:13.0\tsection_pause\tintro → settings
        3:40.0\t3:52.0\taction_pause\tclicking ? not sure
        """
        let labels = try LabelParser.parse(text)
        let kinds: [Label.Kind] = labels.map(\.kind)
        let expected: [Label.Kind] = [.retake, .falseStart, .sectionPause, .actionPause]
        #expect(kinds == expected)
        #expect(labels[0].range == TimeRange(start: 12.4, end: 15.1))
        #expect(labels[0].note.hasPrefix("\"April."))
        #expect(labels[2].kind.isPause && !labels[0].kind.isPause)
        #expect(labels[3].isUnsure)
    }

    @Test func times() {
        #expect(LabelParser.time("1:02.5") == 62.5)
        #expect(LabelParser.time("0:01:02.5") == 62.5)
        #expect(LabelParser.time("62.5") == 62.5)
        #expect(LabelParser.time("1.5:02") == nil)
        #expect(LabelParser.time("abc") == nil)
        #expect(LabelParser.format(62.54) == "1:02.5")
    }

    @Test func reportsProblemsWithLineNumbers() {
        #expect(throws: LabelParser.ParseError.self) { try LabelParser.parse("start\tend\tkind\n0:01\t0:02\tmistake") }
        #expect(throws: LabelParser.ParseError.self) { try LabelParser.parse("0:05\t0:02\tretake") }
        #expect(throws: LabelParser.ParseError.self) { try LabelParser.parse("0:01 0:02 retake") }
        #expect(throws: LabelParser.ParseError.self) { try LabelParser.parse("start\tend\tkind\n0:01\tsoon\tretake") }
    }
}

@Suite("Provider specs")
struct ProviderSpecTests {
    @Test func presetModelAndEffort() throws {
        let spec = try ProviderSpec.parse("openai:gpt-6-luna@low", environment: ["OPENAI_API_KEY": "sk"])
        #expect(spec.configuration.model == "gpt-6-luna")
        #expect(spec.configuration.reasoningEffort == "low")
        #expect(spec.apiKey == "sk")
        #expect(spec.price?.input == 0.10)
        #expect(spec.slug == "openai_gpt-6-luna_low")
    }

    @Test func defaultsComeFromThePreset() throws {
        let local = try ProviderSpec.parse("lmstudio", environment: [:])
        #expect(local.configuration.model == "qwen3.5-9b")
        #expect(local.configuration.reasoningEffort == nil)
        #expect(local.price?.input == 0)
        let openAI = try ProviderSpec.parse("openai", environment: ["OPENAI_API_KEY": "sk"])
        #expect(openAI.configuration.reasoningEffort == "none")
    }

    @Test func explainsWhatsMissing() {
        #expect(throws: ProviderSpec.SpecError.self) { try ProviderSpec.parse("openai", environment: [:]) }
        #expect(throws: ProviderSpec.SpecError.self) { try ProviderSpec.parse("nope:model", environment: [:]) }
        #expect(throws: ProviderSpec.SpecError.self) { try ProviderSpec.parse("custom:model", environment: [:]) }
    }

    @Test func customEndpoint() throws {
        let spec = try ProviderSpec.parse("custom:mock@low", environment: ["CUSTOM_BASE_URL": "http://127.0.0.1:8765/v1"])
        #expect(spec.configuration.baseURL.absoluteString == "http://127.0.0.1:8765/v1")
        #expect(spec.configuration.isLocal)
    }
}

/// Ten one-second words, "w0" … "w9".
private func transcript() -> Transcript {
    let words = (0..<10).map { TranscriptWord(text: "w\($0)", start: Double($0), end: Double($0) + 0.9) }
    return Transcript(language: .english, localeIdentifier: "en-US", engine: "test", words: words)
}

private func cut(_ start: Double, _ end: Double, words: ClosedRange<Int>, kind: SuggestionKind = .retake, confidence: Double = 0.8) -> Suggestion {
    Suggestion(kind: kind, range: TimeRange(start: start, end: end), words: words, confidence: confidence, reason: "test", source: .model)
}

private func label(_ start: Double, _ end: Double, _ kind: Label.Kind, note: String = "") -> Label {
    Label(range: TimeRange(start: start, end: end), kind: kind, note: note)
}

@Suite("Scoring")
struct ScoringTests {
    @Test func foundMistakeWithNoCollateral() {
        let analysis = AutoEditAnalysis(transcript: transcript(), pauses: [], suggestions: [cut(2, 4, words: 2...3)])
        let score = Scorer.score(sample: "s", analysis: analysis, labels: [label(2.1, 3.9, .retake)], audioSeconds: 600)
        #expect(score.foundMistakes == 1)
        #expect(score.correctTime == 2)
        #expect(score.suggestedTime == 2)
        #expect(score.contentLost == 0)
        #expect(score.falseCuts.isEmpty)
        #expect(!score.isControl)
    }

    @Test func cuttingRealContentCounts() {
        let analysis = AutoEditAnalysis(transcript: transcript(), pauses: [], suggestions: [cut(6, 8, words: 6...7)])
        let score = Scorer.score(sample: "s", analysis: analysis, labels: [label(2, 4, .retake)], audioSeconds: 600)
        #expect(score.foundMistakes == 0)
        #expect(score.missed.count == 1)
        #expect(abs(score.contentLost - 1.8) < 1e-9)
        #expect(score.falseCuts.count == 1)
        #expect(score.correctTime == 0)
    }

    @Test func controlsCountEveryEnabledCut() {
        let analysis = AutoEditAnalysis(transcript: transcript(), pauses: [], suggestions: [
            cut(6, 7, words: 6...6), cut(8, 8.5, words: 8...8, confidence: 0.4),
        ])
        let score = Scorer.score(sample: "s", analysis: analysis, labels: [], audioSeconds: 60)
        #expect(score.isControl)
        // The low-confidence cut starts switched off, so it isn't counted.
        #expect(score.controlFalsePositives == 1)
    }

    @Test func unsureLabelsAreNeutral() {
        let analysis = AutoEditAnalysis(transcript: transcript(), pauses: [], suggestions: [cut(6, 7, words: 6...6)])
        let score = Scorer.score(sample: "s", analysis: analysis, labels: [label(6, 7, .repeat, note: "maybe?")], audioSeconds: 60)
        #expect(score.labeledMistakes == 0)
        #expect(score.suggestedTime == 0)
        #expect(score.contentLost == 0)
    }

    @Test func deliberatePausesAndHesitations() {
        let pauses = [
            Pause(id: 0, range: TimeRange(start: 2.9, end: 4.5), afterWord: 2, kind: .section),
            Pause(id: 1, range: TimeRange(start: 5.9, end: 7.2), afterWord: 5, kind: .sentence),
            Pause(id: 2, range: TimeRange(start: 8.9, end: 10.2), afterWord: 8, kind: .hesitation),
            Pause(id: 3, range: TimeRange(start: 0.9, end: 2.0), afterWord: 0, kind: .emphasis),
        ]
        let analysis = AutoEditAnalysis(transcript: transcript(), pauses: pauses, suggestions: [])
        let labels = [label(3, 4.4, .sectionPause), label(6, 7, .emphasisPause), label(11, 12, .actionPause)]
        let score = Scorer.score(sample: "s", analysis: analysis, labels: labels, audioSeconds: 60)
        #expect(score.deliberateLabeled == 3)
        #expect(score.deliberateKept == 1)
        #expect(score.deliberateUndetected == 1)
        // Unlabeled long pauses: p2 (hesitation, fine) and p3 (emphasis, not fine).
        #expect(score.longUnlabeledPauses == 2)
        #expect(score.longUnlabeledShortened == 1)
        #expect(score.pauseMisses.count == 3)
    }

    @Test func instabilityAcrossRuns() {
        let base = transcript()
        func run(_ kind: PauseKind, cutWords: ClosedRange<Int>?) -> AutoEditAnalysis {
            let pause = Pause(id: 0, range: TimeRange(start: 2.9, end: 4), afterWord: 2, kind: kind, kindSource: .model)
            let suggestions = cutWords.map { [cut(Double($0.lowerBound), Double($0.upperBound) + 0.9, words: $0)] } ?? []
            return AutoEditAnalysis(transcript: base, pauses: [pause], suggestions: suggestions)
        }
        let stable = Scorer.instability([run(.section, cutWords: 4...5), run(.emphasis, cutWords: 4...5)])
        #expect(stable.unstable == 0)
        #expect(stable.total == 3)
        let unstable = Scorer.instability([run(.section, cutWords: 4...5), run(.sentence, cutWords: 4...4)])
        #expect(unstable.unstable == 2)
        #expect(unstable.total == 3)
    }

    @Test func passBar() {
        func score(found: Int, lost: Double) -> SampleScore {
            var score = SampleScore(sample: "s", audioSeconds: 600, isControl: false)
            score.labeledMistakes = 5
            score.foundMistakes = found
            score.suggestedTime = 10
            score.correctTime = 9.5
            score.contentLost = lost
            score.deliberateLabeled = 4
            score.deliberateKept = 4
            return score
        }
        var rules = Summarizer.summarize(name: "Rules only", isRules: true, isLocal: true, runs: [[score(found: 2, lost: 0)]], calls: nil)
        Summarizer.applyBar(&rules, baseline: nil)
        #expect(rules.failures == ["mistake recall"])

        let report = ModelPassReport(provider: "p", model: "m", latency: 3, usage: TokenUsage(input: 5000, output: 1000),
                                     warnings: [], rawContent: "", firstTryValid: true, attempts: 1)
        var model = Summarizer.summarize(
            name: "openai", isRules: false, isLocal: false, runs: [[score(found: 5, lost: 0.2)]],
            calls: .init(reports: [report], failures: 0, instability: (0, 10), price: (0.10, 0.50))
        )
        Summarizer.applyBar(&model, baseline: rules)
        #expect(model.passes)
        #expect(model.mistakeRecall == 1)
        #expect(abs((model.costPerRecording ?? 0) - 0.001) < 1e-12)
        #expect(model.medianSecondsPer10Minutes == 3)
        #expect(model.stability == 1)
    }
}

@Suite("Samples")
struct SampleTests {
    @Test func loadsSamplesFromTheDocumentedLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EvalTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (split, name) in [("dev", "en-01-tour"), ("dev", "es-02-menu"), ("test", "en-03-control")] {
            let folder = root.appendingPathComponent("samples/\(split)/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("recording.mp4"))
            try "start\tend\tkind\tnote\n".write(to: folder.appendingPathComponent("labels.tsv"), atomically: true, encoding: .utf8)
        }
        let dev = try Sample.load(root: root, split: "dev")
        #expect(dev.map(\.name) == ["en-01-tour", "es-02-menu"])
        #expect(dev.map(\.language) == [.english, .spanish])
        #expect(try Sample.load(root: root, split: "all").count == 3)

        let bad = root.appendingPathComponent("samples/test/fr-04-nope")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        #expect(throws: Sample.SampleError.self) { try Sample.load(root: root, split: "test") }
    }

    @Test func transcriptCacheFollowsTheRecording() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EvalTests-\(UUID().uuidString)/en-01-x")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: folder.appendingPathComponent("recording.mp4"))
        try "".write(to: folder.appendingPathComponent("labels.tsv"), atomically: true, encoding: .utf8)
        let sample = try Sample.load(directory: folder, split: "dev")
        #expect(sample.cachedTranscript() == nil)
        try sample.saveTranscript(transcript())
        #expect(sample.cachedTranscript()?.words.count == 10)
        try Data("changed".utf8).write(to: sample.recording)
        #expect(sample.cachedTranscript() == nil)
    }

    @Test func optionsParse() throws {
        let options = try Options.parse(["--dir", "/tmp/x", "--runs", "2", "--split", "all", "--providers", "lmstudio ollama"], environment: [:])
        #expect(options?.directory.path == "/tmp/x")
        #expect(options?.runs == 2)
        #expect(options?.providers.map(\.label) == ["lmstudio", "ollama"])
        #expect(throws: Options.UsageError.self) { try Options.parse(["--split", "weekly"], environment: [:]) }
        #expect(try Options.parse(["--help"], environment: [:]) == nil)
    }
}
