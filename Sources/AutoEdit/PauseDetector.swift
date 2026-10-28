import AppCore
import Foundation
import Transcription

/// Finds the pauses between transcribed words (PRD AE-2). A pause is silence
/// on the microphone inside a gap between two words; a gap that holds sound
/// the recognizer didn't transcribe (a dropped "eh") is reported separately.
public enum PauseDetector {
    /// Shortest pause worth judging (AE-2).
    public static let minimumPause = 0.3
    /// Untranscribed sound this long can be a dropped filler ("eh"); shorter
    /// is a click or a breath, longer is speech the recognizer missed.
    public static let voicedGapDuration: ClosedRange<Double> = 0.15...0.6

    public struct Result: Sendable, Equatable {
        public var pauses: [Pause]
        /// Sound inside word gaps with no word on it, source seconds.
        public var voicedGaps: [(range: TimeRange, afterWord: Int)]

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.pauses == rhs.pauses && lhs.voicedGaps.map(\.range) == rhs.voicedGaps.map(\.range)
                && lhs.voicedGaps.map(\.afterWord) == rhs.voicedGaps.map(\.afterWord)
        }
    }

    /// The part of a word always treated as speech. The recognizer often
    /// stretches a sentence's last word over the silence after it, so the
    /// rest of the word is searched for silence too.
    static let wordCore = 0.25

    /// - Parameter envelope: when `nil`, every gap of `minimum` or more is a pause.
    public static func detect(words: [TranscriptWord], envelope: LoudnessEnvelope?, minimum: Double = minimumPause) -> Result {
        var pauses: [Pause] = []
        var voiced: [(range: TimeRange, afterWord: Int)] = []
        let thresholds = envelope?.thresholds()
        for index in words.indices.dropLast() {
            let gap = TimeRange(start: words[index].end, end: words[index + 1].start)
            guard let envelope, let thresholds else {
                if gap.duration >= minimum { pauses.append(Pause(id: pauses.count, range: gap, afterWord: index)) }
                continue
            }
            let searchStart = min(words[index].end, words[index].start + wordCore)
            let search = TimeRange(start: searchStart, end: words[index + 1].start)
            guard search.duration >= minimum else { continue }
            let silent = envelope.silentRuns(in: search, minimum: minimum, thresholds: thresholds)
            for run in silent {
                pauses.append(Pause(id: pauses.count, range: run, afterWord: index))
            }
            // Sound between the words that no word covers: a dropped "eh"
            // is sustained and as loud as speech, with silence on both sides.
            // Typing, clicks, and breaths are short or quieter.
            guard gap.duration >= voicedGapDuration.lowerBound + 0.3 else { continue }
            let quiet = envelope.silentRuns(in: gap, minimum: 0.15, thresholds: thresholds)
            var sound = [gap]
            for run in quiet { sound = sound.flatMap { $0.subtracting(run) } }
            for range in sound where voicedGapDuration.contains(range.duration)
                && quiet.contains(where: { abs($0.end - range.start) < 0.011 })
                && quiet.contains(where: { abs($0.start - range.end) < 0.011 }) {
                let levels = envelope.levels(in: range)
                guard !levels.isEmpty else { continue }
                let loudFrames = levels.filter { $0 >= thresholds.speech }.count
                let mean = levels.reduce(0, +) / Float(levels.count)
                if Double(loudFrames) >= 0.8 * Double(levels.count), mean >= thresholds.speech + 6 {
                    voiced.append((range, index))
                }
            }
        }
        return Result(pauses: pauses, voicedGaps: voiced)
    }
}
