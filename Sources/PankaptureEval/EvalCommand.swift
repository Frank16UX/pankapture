import AIProviders
import AutoEdit
import Foundation
import Transcription

/// `make eval`: runs auto-edit over labeled sample recordings with the rules
/// alone and with each provider, scores the results (PRD §11), and writes
/// `results/<date-time>/report.md` plus the raw answers.
@main
struct EvalCommand {
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
            guard let options else { return }
            guard #available(macOS 26, *) else { throw Options.UsageError(message: "Needs macOS 26 or later (on-device transcription).") }
            try await Evaluation(options: options).run()
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

struct Options {
    var directory: URL
    var providers: [ProviderSpec]
    var runs: Int
    var split: String
    /// Only samples whose name contains this.
    var only: String?
    /// A cloud speech-to-text service instead of the on-device one (PRD AI-5).
    var transcriber: CloudTranscription?

    struct UsageError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static let usage = """
    Usage: pankapture-eval --dir <folder> [--providers "spec …"] [--runs N] [--split dev|test|all] [--only <name>]

      --dir        Folder with samples/dev, samples/test (default: $EVAL_DIR or ~/PankaptureEval)
      --providers  Space-separated preset[:model][@effort], e.g. "lmstudio:qwen3.5-9b openai:gpt-6-luna@low".
                   Presets: \(ProviderPreset.all.map(\.id).joined(separator: ", ")). Leave out to score the rules alone.
                   Keys come from the environment (OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY, …).
      --runs       Model calls per sample (default 3; answers vary between runs)
      --split      dev (default), test, or all
      --only       Only samples whose folder name contains this
      --transcriber  service[:model]: elevenLabs, openAI, groq, or openRouter (e.g. "openRouter:assemblyai/universal-3-6-pro"):
                   transcribe in the cloud instead of on device (sends the recordings' audio; key from
                   ELEVENLABS_API_KEY, OPENAI_API_KEY, GROQ_API_KEY, or OPENROUTER_API_KEY)
    """

    /// `nil` when only help was asked for.
    static func parse(_ arguments: [String], environment: [String: String]) throws -> Options? {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                print(usage)
                return nil
            }
            guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                throw UsageError(message: "Unexpected “\(argument)”.\n\n\(usage)")
            }
            values[String(argument.dropFirst(2))] = arguments[index + 1]
            index += 2
        }
        let path = values["dir"].flatMap { $0.isEmpty ? nil : $0 } ?? environment["EVAL_DIR"] ?? "~/PankaptureEval"
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        let providers = try (values["providers"] ?? "").split(whereSeparator: \.isWhitespace)
            .map { try ProviderSpec.parse(String($0), environment: environment) }
        guard let runs = Int(values["runs"] ?? "3"), runs >= 1 else { throw UsageError(message: "--runs must be 1 or more.") }
        let split = values["split"] ?? "dev"
        guard ["dev", "test", "all"].contains(split) else { throw UsageError(message: "--split must be dev, test, or all.") }
        let only = values["only"].flatMap { $0.isEmpty ? nil : $0 }
        var transcriber: CloudTranscription?
        if let spec = values["transcriber"], !spec.isEmpty {
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            guard let service = CloudTranscriptionService.allCases.first(where: { $0.rawValue.lowercased() == parts[0].lowercased() }) else {
                throw UsageError(message: "--transcriber must be elevenLabs, openAI, groq, or openRouter, optionally with :model.")
            }
            guard let key = environment[service.keyEnvironmentVariable], !key.isEmpty else {
                throw UsageError(message: "\(service.name) needs a key: export \(service.keyEnvironmentVariable) first.")
            }
            transcriber = CloudTranscription(service: service, model: parts.count > 1 ? parts[1] : nil, apiKey: key)
        }
        return Options(directory: directory, providers: providers, runs: runs, split: split, only: only, transcriber: transcriber)
    }
}

@available(macOS 26, *)
struct Evaluation {
    var options: Options

    func run() async throws {
        var samples = try Sample.load(root: options.directory, split: options.split)
        if let only = options.only { samples = samples.filter { $0.name.contains(only) } }
        guard !samples.isEmpty else { throw Options.UsageError(message: "No samples match --only \(options.only ?? "").") }

        let started = Date()
        let output = options.directory.appendingPathComponent("results/\(Self.stamp(started))", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Auto-edit evaluation: \(samples.count) samples (\(options.split)), \(options.providers.count) provider(s), \(options.runs) run(s)")

        // Transcribe and analyze each sample once; providers reuse the result.
        var inputs: [String: AutoEditInput] = [:]
        // The default model keeps the older cache names; another model gets its own cache.
        let engine = options.transcriber.map { cloud in
            cloud.model == cloud.service.defaultModel
                ? cloud.service.rawValue
                : "\(cloud.service.rawValue)-\(cloud.model.replacingOccurrences(of: "/", with: "_"))"
        } ?? ""
        for sample in samples {
            let cached = sample.cachedTranscript(engine: engine)
            let how = options.transcriber.map { "transcribing with \($0.displayName)…" } ?? "transcribing on device…"
            print("• \(sample.name): \(cached == nil ? how : "analyzing (cached transcript)…")")
            let prepared = try await AutoEditAnalyzer.prepare(
                recordingAt: sample.recording, language: sample.language, transcript: cached, cloud: options.transcriber
            )
            if cached == nil { try sample.saveTranscript(prepared.input.transcript, engine: engine) }
            inputs[sample.name] = prepared.input
            let judged = ModelPass.judgedPauses(prepared.input).count
            print("  \(prepared.input.transcript.words.count) words, \(prepared.input.pauses.count) pauses (\(judged) judged by models), \(prepared.input.ruleSuggestions.count) rule suggestions")
        }
        let audioSeconds = samples.reduce(0) { $0 + (inputs[$1.name]?.duration ?? 0) }

        var perSample: [String: [(variant: String, score: SampleScore)]] = [:]
        var summaries: [VariantSummary] = []

        // Baseline: the rules alone.
        var ruleScores: [SampleScore] = []
        for sample in samples {
            guard let input = inputs[sample.name] else { continue }
            let analysis = AutoEditAnalysis(rulesOnly: input)
            let score = Scorer.score(sample: sample.name, analysis: analysis, labels: sample.labels, audioSeconds: input.duration)
            ruleScores.append(score)
            perSample[sample.name, default: []].append(("Rules only", score))
            try Self.write(RawResult(analysis: analysis, report: nil, error: nil),
                           to: output.appendingPathComponent("raw/rules/\(sample.name).json"))
        }
        var baseline = Summarizer.summarize(name: "Rules only", isRules: true, isLocal: true, runs: [ruleScores], calls: nil)
        Summarizer.applyBar(&baseline, baseline: nil)
        summaries.append(baseline)

        for spec in options.providers {
            print("\n\(spec.configuration.displayName)")
            if let problem = await Self.preflight(spec) {
                print("  ✗ skipped: \(problem)")
                continue
            }
            var runs: [[SampleScore]] = []
            var reports: [ModelPassReport] = []
            var failures = 0
            var analyses: [String: [AutoEditAnalysis]] = [:]
            for run in 1...options.runs {
                var scores: [SampleScore] = []
                for sample in samples {
                    guard let input = inputs[sample.name] else { continue }
                    let outcome = try await ModelPass.run(input, configuration: spec.configuration, apiKey: spec.apiKey)
                    reports.append(outcome.report)
                    if let error = outcome.error {
                        failures += 1
                        print("  ✗ run \(run) \(sample.name): \(error)")
                    } else {
                        print(String(format: "  ✓ run %d %@ (%.1f s)", run, sample.name, outcome.report.latency))
                    }
                    analyses[sample.name, default: []].append(outcome.analysis)
                    let score = Scorer.score(sample: sample.name, analysis: outcome.analysis, labels: sample.labels, audioSeconds: input.duration)
                    scores.append(score)
                    if run == 1 { perSample[sample.name, default: []].append((spec.label, score)) }
                    try Self.write(RawResult(analysis: outcome.analysis, report: outcome.report, error: outcome.error),
                                   to: output.appendingPathComponent("raw/\(spec.slug)/run-\(run)/\(sample.name).json"))
                }
                runs.append(scores)
            }
            let instability = analyses.values.map(Scorer.instability).reduce((unstable: 0, total: 0)) {
                (unstable: $0.unstable + $1.unstable, total: $0.total + $1.total)
            }
            var summary = Summarizer.summarize(
                name: spec.label, isRules: false, isLocal: spec.configuration.isLocal, runs: runs,
                calls: .init(reports: reports, failures: failures, instability: instability, price: spec.price)
            )
            Summarizer.applyBar(&summary, baseline: baseline)
            summaries.append(summary)
        }

        let context = ReportWriter.Context(
            date: started, split: options.split, samples: samples, audioSeconds: audioSeconds, runs: options.runs,
            promptFingerprint: ReportWriter.fingerprint(ModelPass.systemPrompt + ModelPass.schema.serialized())
        )
        let report = ReportWriter.markdown(context: context, summaries: summaries, perSample: perSample)
        try report.write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        try Self.write(summaries, to: output.appendingPathComponent("summary.json"))

        print("\nSummary")
        for summary in summaries {
            let verdict = summary.passes ? "passes" : "misses: " + summary.failures.joined(separator: ", ")
            print("  \(summary.name): recall \(ReportWriter.percent(summary.mistakeRecall)), precision \(ReportWriter.percent(summary.mistakePrecision)), deliberate pauses \(ReportWriter.percent(summary.deliberateKept)) — \(verdict)")
        }
        print("\nReport: \(output.appendingPathComponent("report.md").path)")
    }

    struct RawResult: Encodable {
        var analysis: AutoEditAnalysis
        var report: ModelPassReport?
        var error: String?
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// A quick check that an OpenAI-compatible server answers, so a stopped
    /// LM Studio doesn't fail every sample one by one.
    static func preflight(_ spec: ProviderSpec) async -> String? {
        guard spec.configuration.api == .openAICompatible else { return nil }
        var request = URLRequest(url: spec.configuration.baseURL.appending(path: "models"))
        request.timeoutInterval = 10
        if let key = spec.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 { return "the API key was rejected (401)" }
            return nil
        } catch {
            return spec.configuration.isLocal
                ? "nothing answers at \(spec.configuration.baseURL.absoluteString). Is the server running? (PRD §11.4)"
                : error.localizedDescription
        }
    }
}
