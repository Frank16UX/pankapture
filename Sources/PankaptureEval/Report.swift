import AutoEdit
import Foundation

/// The evaluation's `report.md` (PRD §11.5).
enum ReportWriter {
    struct Context {
        var date: Date
        var split: String
        var samples: [Sample]
        var audioSeconds: Double
        var runs: Int
        var promptFingerprint: String
    }

    static func markdown(context: Context, summaries: [VariantSummary], perSample: [String: [(variant: String, score: SampleScore)]]) -> String {
        var text = "# Auto-edit evaluation\n\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let languages = Dictionary(grouping: context.samples, by: \.language).map { "\($0.value.count) \($0.key.rawValue)" }.sorted()
        text += "- **Date:** \(formatter.string(from: context.date))\n"
        text += "- **Split:** \(context.split) · \(context.samples.count) samples (\(languages.joined(separator: ", "))) · "
        text += String(format: "%.1f min of audio", context.audioSeconds / 60) + "\n"
        text += "- **Runs per provider:** \(context.runs)\n"
        text += "- **Prompt:** `\(context.promptFingerprint)` (changes whenever the prompt or schema does)\n\n"

        text += "## Summary\n\n"
        text += "| Variant | Mistake recall | Precision | Content lost /10 min | Control FPs (max) | Deliberate pauses kept | Hesitations shortened | Valid (1st / final) | Stable | Seconds /10 min | Cost /recording | Verdict |\n"
        text += "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for summary in summaries {
            let valid = summary.isRules ? "—" : "\(percent(summary.validFirstTry)) / \(percent(summary.validFinal))"
            let verdict = summary.passes ? "✅ passes" : "❌ " + summary.failures.joined(separator: ", ")
            text += "| \(summary.name) | \(percent(summary.mistakeRecall)) | \(percent(summary.mistakePrecision)) | "
            text += String(format: "%.1f s", summary.contentLostPer10Minutes) + " | "
            text += "\(summary.maxControlFalsePositives.map(String.init) ?? "—") | \(percent(summary.deliberateKept)) | "
            text += "\(percent(summary.hesitationsShortened)) | \(valid) | \(summary.isRules ? "—" : percent(summary.stability)) | "
            text += "\(summary.medianSecondsPer10Minutes.map { String(format: "%.0f s", $0) } ?? "—") | "
            text += "\(summary.costPerRecording.map { String(format: "$%.4f", $0) } ?? "—") | \(verdict) |\n"
        }
        text += "\nBars (PRD §11.6): recall ≥ 80%, precision ≥ 90%, content lost ≤ 1 s per 10 min, ≤ 1 false cut per control, "
        text += "deliberate pauses kept ≥ 85%, hesitations shortened ≥ 80%, valid answers 100% cloud / 95% local, stable ≥ 90%. "
        text += "A provider must also beat the rules on mistake recall or deliberate pauses.\n"

        let unsure = context.samples.flatMap { sample in sample.labels.filter(\.isUnsure).map { (sample.name, $0) } }
        if !unsure.isEmpty {
            text += "\n## Unsure labels (not scored)\n\n"
            for (name, label) in unsure {
                text += "- \(name) \(Scorer.span(label.range)) \(label.kind.rawValue) \(label.note)\n"
            }
        }

        text += "\n## Per sample (first run)\n"
        for sample in context.samples {
            let removals = sample.labels.filter { $0.kind.isRemoval && !$0.isUnsure }.count
            let pauses = sample.labels.filter { $0.kind.isPause && !$0.isUnsure }.count
            text += "\n### \(sample.name)\n\n"
            text += "\(removals) mistake label\(removals == 1 ? "" : "s"), \(pauses) pause label\(pauses == 1 ? "" : "s")"
            text += removals == 0 ? " (control)\n" : "\n"
            for (variant, score) in perSample[sample.name] ?? [] {
                let lost = String(format: "%.1f s lost", score.contentLost)
                text += "\n**\(variant):** \(score.foundMistakes)/\(score.labeledMistakes) found, \(score.falseCuts.count) false cut\(score.falseCuts.count == 1 ? "" : "s"), \(lost), "
                text += "\(score.deliberateKept)/\(score.deliberateLabeled) deliberate pauses kept\n"
                for line in score.missed { text += "- Missed: \(line)\n" }
                for line in score.falseCuts { text += "- False cut: \(line)\n" }
                for line in score.pauseMisses { text += "- Pause: \(line)\n" }
            }
        }
        return text
    }

    static func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
    }

    /// FNV-1a over the prompt and schema: a short, stable fingerprint.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16).prefix(10).description
    }
}
