import AppCore
import AutoEdit
import Foundation
import Transcription

/// Scores one analysis of one sample against its labels (PRD §11.6).
struct SampleScore: Codable, Sendable {
    var sample: String
    var audioSeconds: Double
    /// No removal labels: any mistake cut is a false positive.
    var isControl: Bool

    var labeledMistakes = 0
    var foundMistakes = 0
    /// Suggested mistake-cut time, excluding time inside unsure labels.
    var suggestedTime = 0.0
    /// The part of it inside labeled removals (±tolerance).
    var correctTime = 0.0
    /// Seconds of suggested cuts over words outside every removal label.
    var contentLost = 0.0
    var controlFalsePositives = 0

    var deliberateLabeled = 0
    var deliberateKept = 0
    /// Labeled deliberate pauses no detected pause matched.
    var deliberateUndetected = 0
    var longUnlabeledPauses = 0
    var longUnlabeledShortened = 0

    /// For the report: what went wrong, with timestamps.
    var missed: [String] = []
    var falseCuts: [String] = []
    var pauseMisses: [String] = []
}

enum Scorer {
    /// A label counts as found when suggested cuts cover this share of it.
    static let coverageToFind = 0.7
    /// Labels are timed by hand; cuts this close to one aren't penalized.
    static let tolerance = 0.3
    /// Unlabeled pauses at least this long are scored as hesitations.
    static let longPause = 1.0

    static func score(sample: String, analysis: AutoEditAnalysis, labels: [Label], audioSeconds: Double) -> SampleScore {
        let removals = labels.filter { $0.kind.isRemoval && !$0.isUnsure }
        let pauseLabels = labels.filter { $0.kind.isPause && !$0.isUnsure }
        let unsure = labels.filter(\.isUnsure)
        var score = SampleScore(sample: sample, audioSeconds: audioSeconds, isControl: removals.isEmpty)

        let mistakeCuts = analysis.suggestions.filter { $0.kind.isMistake && $0.isEnabledByDefault }
        let cutRanges = TimeRange.merged(mistakeCuts.map(\.range))
        let unsureRanges = TimeRange.merged(unsure.map { dilate($0.range) })
        let allowed = TimeRange.merged(removals.map { dilate($0.range) })

        // Recall: labels covered by the cuts.
        score.labeledMistakes = removals.count
        for label in removals {
            let covered = overlap(of: label.range, with: cutRanges)
            if covered >= coverageToFind * label.range.duration {
                score.foundMistakes += 1
            } else {
                score.missed.append("\(span(label.range)) \(label.kind.rawValue) \(label.note)")
            }
        }

        // Precision: cut time inside labeled removals (unsure spans don't count either way).
        for range in cutRanges {
            let counted = subtract(unsureRanges, from: range)
            score.suggestedTime += counted.reduce(0) { $0 + $1.duration }
            score.correctTime += counted.reduce(0) { $0 + overlap(of: $1, with: allowed) }
        }

        // Content lost: cut time over words no label marks for removal.
        let fillerWords = Set(analysis.suggestions.filter { $0.kind == .filler }.compactMap(\.words).flatMap { Array($0) })
        let neutral = TimeRange.merged(allowed + unsureRanges)
        for (index, word) in analysis.transcript.words.enumerated() where !fillerWords.contains(index) {
            guard !neutral.contains(where: { $0.contains(word.range.midpoint) }) else { continue }
            score.contentLost += overlap(of: word.range, with: cutRanges)
        }
        for cut in mistakeCuts {
            let outside = subtract(neutral, from: cut.range).reduce(0) { $0 + $1.duration }
            if outside > 0.5 * cut.range.duration {
                score.falseCuts.append("\(span(cut.range)) \(cut.kind.rawValue) \(quoted(text(of: cut, in: analysis.transcript))) — \(cut.reason)")
            }
        }
        if score.isControl { score.controlFalsePositives = mistakeCuts.count }

        // Deliberate pauses kept.
        for label in pauseLabels {
            score.deliberateLabeled += 1
            let found = analysis.pauses.filter { matches($0.range, label.range) }
            if found.isEmpty {
                score.deliberateUndetected += 1
                score.pauseMisses.append("\(span(label.range)) \(label.kind.rawValue): no pause detected there")
            } else if found.contains(where: { $0.kind.isDeliberate }) {
                score.deliberateKept += 1
            } else {
                let kinds = found.map { "\($0.kind.rawValue) (\($0.kindSource.rawValue))" }.joined(separator: ", ")
                score.pauseMisses.append("\(span(label.range)) \(label.kind.rawValue) judged \(kinds)")
            }
        }

        // Long unlabeled pauses: hesitations, fine to shorten.
        let labeled = TimeRange.merged(labels.map { dilate($0.range) })
        for pause in analysis.pauses where pause.duration >= longPause {
            guard !labeled.contains(where: { $0.overlaps(pause.range) }) else { continue }
            score.longUnlabeledPauses += 1
            if !pause.kind.isDeliberate {
                score.longUnlabeledShortened += 1
            } else {
                score.pauseMisses.append("\(span(pause.range)) unlabeled pause judged \(pause.kind.rawValue) (\(pause.kindSource.rawValue))")
            }
        }
        return score
    }

    // MARK: Stability

    /// Decisions that differ between runs of the same sample: whether each
    /// model-judged pause is deliberate, and whether each word is cut
    /// (counting only words some run cut).
    static func instability(_ runs: [AutoEditAnalysis]) -> (unstable: Int, total: Int) {
        guard runs.count > 1 else { return (0, 0) }
        var unstable = 0
        var total = 0
        let pauseIDs = Set(runs.flatMap { $0.pauses.filter { $0.kindSource == .model }.map(\.id) })
        for id in pauseIDs {
            let decisions = runs.map { run in run.pauses.first { $0.id == id }?.kind.isDeliberate ?? false }
            total += 1
            if Set(decisions).count > 1 { unstable += 1 }
        }
        let cutWords = runs.map { run in
            Set(run.suggestions.filter { $0.kind.isMistake && $0.isEnabledByDefault }.compactMap(\.words).flatMap { Array($0) })
        }
        for word in cutWords.reduce(Set<Int>(), { $0.union($1) }) {
            total += 1
            if !cutWords.allSatisfy({ $0.contains(word) }) { unstable += 1 }
        }
        return (unstable, total)
    }

    // MARK: Helpers

    static func dilate(_ range: TimeRange) -> TimeRange {
        TimeRange(start: range.start - tolerance, end: range.end + tolerance)
    }

    /// Seconds of `range` covered by `ranges` (merged, non-overlapping).
    static func overlap(of range: TimeRange, with ranges: [TimeRange]) -> Double {
        ranges.reduce(0) { $0 + (range.intersection($1)?.duration ?? 0) }
    }

    static func subtract(_ holes: [TimeRange], from range: TimeRange) -> [TimeRange] {
        holes.reduce([range]) { parts, hole in parts.flatMap { $0.subtracting(hole) } }
    }

    /// A detected pause belongs to a labeled one when they share 0.15 s or
    /// half of the shorter.
    static func matches(_ pause: TimeRange, _ label: TimeRange) -> Bool {
        guard let shared = pause.intersection(dilate(label))?.duration else { return false }
        return shared >= 0.15 || shared >= 0.5 * min(pause.duration, label.duration)
    }

    static func span(_ range: TimeRange) -> String {
        "\(LabelParser.format(range.start))–\(LabelParser.format(range.end))"
    }

    static func quoted(_ text: String) -> String {
        text.isEmpty ? "" : "“\(text)”"
    }

    static func text(of suggestion: Suggestion, in transcript: Transcript) -> String {
        guard let words = suggestion.words else { return "" }
        return transcript.text(of: words)
    }
}

/// Scores of one variant (rules, or a provider) over every run and sample.
struct VariantSummary: Codable, Sendable {
    var name: String
    var isRules: Bool
    var isLocal: Bool
    var runs: Int

    var mistakeRecall: Double?
    var mistakePrecision: Double?
    var contentLostPer10Minutes: Double
    var maxControlFalsePositives: Int?
    var deliberateKept: Double?
    var hesitationsShortened: Double?
    var validFirstTry: Double?
    var validFinal: Double?
    /// Share of decisions that agree across runs (1 = fully stable).
    var stability: Double?
    var medianSecondsPer10Minutes: Double?
    var costPerRecording: Double?

    /// The bars this variant misses (PRD §11.6).
    var failures: [String] = []

    var passes: Bool { failures.isEmpty }
}

enum Summarizer {
    struct ModelCalls {
        var reports: [ModelPassReport]
        var failures: Int
        var instability: (unstable: Int, total: Int)
        var price: (input: Double, output: Double)?
    }

    /// - Parameter runs: per run, the scores of every sample.
    static func summarize(name: String, isRules: Bool, isLocal: Bool, runs: [[SampleScore]], calls: ModelCalls?) -> VariantSummary {
        let all = runs.flatMap { $0 }
        func ratio(_ part: Int, _ whole: Int) -> Double? { whole > 0 ? Double(part) / Double(whole) : nil }
        let suggested = all.reduce(0) { $0 + $1.suggestedTime }
        let minutes = all.reduce(0) { $0 + $1.audioSeconds } / 60

        var summary = VariantSummary(
            name: name, isRules: isRules, isLocal: isLocal, runs: runs.count,
            mistakeRecall: ratio(all.reduce(0) { $0 + $1.foundMistakes }, all.reduce(0) { $0 + $1.labeledMistakes }),
            mistakePrecision: suggested > 0 ? all.reduce(0) { $0 + $1.correctTime } / suggested : nil,
            contentLostPer10Minutes: minutes > 0 ? all.reduce(0) { $0 + $1.contentLost } / minutes * 10 : 0,
            maxControlFalsePositives: all.filter(\.isControl).map(\.controlFalsePositives).max(),
            deliberateKept: ratio(all.reduce(0) { $0 + $1.deliberateKept }, all.reduce(0) { $0 + $1.deliberateLabeled }),
            hesitationsShortened: ratio(all.reduce(0) { $0 + $1.longUnlabeledShortened }, all.reduce(0) { $0 + $1.longUnlabeledPauses })
        )
        guard let calls else { return summary }

        let total = calls.reports.count
        summary.validFirstTry = ratio(calls.reports.filter(\.firstTryValid).count, total)
        summary.validFinal = ratio(total - calls.failures, total)
        if calls.instability.total > 0 {
            summary.stability = 1 - Double(calls.instability.unstable) / Double(calls.instability.total)
        }
        let secondsPerCall = (all.reduce(0) { $0 + $1.audioSeconds }) / Double(max(1, all.count))
        let perTenMinutes = calls.reports.map { $0.latency / max(1, secondsPerCall) * 600 }.sorted()
        summary.medianSecondsPer10Minutes = perTenMinutes.isEmpty ? nil : perTenMinutes[perTenMinutes.count / 2]
        if let price = calls.price, total > 0 {
            let dollars = calls.reports.reduce(0.0) {
                $0 + Double($1.usage.input) * price.input / 1e6 + Double($1.usage.output) * price.output / 1e6
            }
            summary.costPerRecording = dollars / Double(total)
        }
        return summary
    }

    /// Applies the pass bar, comparing a provider against the rules-only baseline.
    static func applyBar(_ summary: inout VariantSummary, baseline: VariantSummary?) {
        var failures: [String] = []
        if let value = summary.mistakeRecall, value < 0.8 { failures.append("mistake recall") }
        if let value = summary.mistakePrecision, value < 0.9 { failures.append("mistake precision") }
        if summary.contentLostPer10Minutes > 1 { failures.append("content lost") }
        if let value = summary.maxControlFalsePositives, value > 1 { failures.append("control false positives") }
        if let value = summary.deliberateKept, value < 0.85 { failures.append("deliberate pauses kept") }
        if let value = summary.hesitationsShortened, value < 0.8 { failures.append("hesitations shortened") }
        if !summary.isRules {
            if let value = summary.validFinal, value < (summary.isLocal ? 0.95 : 1) { failures.append("valid answers") }
            if let value = summary.stability, value < 0.9 { failures.append("stability") }
            if let baseline {
                let betterRecall = (summary.mistakeRecall ?? 0) > (baseline.mistakeRecall ?? 0)
                let betterPauses = (summary.deliberateKept ?? 0) > (baseline.deliberateKept ?? 0)
                if !betterRecall, !betterPauses { failures.append("doesn't beat the rules") }
            }
        }
        summary.failures = failures
    }
}
