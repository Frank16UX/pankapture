import AppCore
import Foundation
import Transcription

/// The built-in judgments (PRD AI-1): fillers, repeats, stutters, retakes, and
/// pause intent from punctuation, length, transition words, and screen
/// activity. They need no provider, and they're the evaluation's baseline.
/// Tuned for precision: a missed mistake is cheaper than cut content.
public enum RuleBasedEditor {
    /// A gap this long ends a sentence even without punctuation.
    static let sentenceGap = 1.2

    /// Everything the rules suggest removing, overlaps resolved.
    public static func suggestions(
        for transcript: Transcript,
        voicedGaps: [(range: TimeRange, afterWord: Int)] = []
    ) -> [Suggestion] {
        let context = Context(transcript)
        var all = fillers(context) + repeats(context) + retakes(context)
        all += voicedGaps.map { gap in
            Suggestion(kind: .filler, range: gap.range, words: nil, confidence: 0.4,
                       reason: "Sound between words with no words on it (a dropped filler?)", source: .rules)
        }
        return resolveOverlaps(all)
    }

    /// Pause kinds from the rules (PRD AE-2, when no provider is configured).
    public static func classify(_ pauses: [Pause], transcript: Transcript) -> [Pause] {
        let context = Context(transcript)
        return pauses.map { pause in
            var pause = pause
            pause.kind = kind(of: pause, context: context)
            pause.kindSource = .rules
            return pause
        }
    }

    static func kind(of pause: Pause, context: Context) -> PauseKind {
        if pause.activity.isActive { return .action }
        guard context.words.indices.contains(pause.afterWord) else { return .sentence }
        let before = context.words[pause.afterWord]
        if before.endsSentence {
            let next = pause.afterWord + 1
            let opensSection = context.lexicon.transitions.contains { context.matches($0, at: next) }
            if pause.duration >= 2.5 || (pause.duration >= 1.5 && opensSection) { return .section }
            return .sentence
        }
        return before.endsClause ? .sentence : .hesitation
    }

    // MARK: Fillers

    static func fillers(_ c: Context) -> [Suggestion] {
        var result: [Suggestion] = []
        var index = 0
        while index < c.count {
            if c.lexicon.fillers.contains(c.bare[index]) {
                result.append(c.suggestion(.filler, index...index, confidence: 0.95, reason: "Filler word “\(c.bare[index])”"))
                index += 1
                continue
            }
            if let phrase = c.lexicon.setApartFillers.first(where: { c.matches($0, at: index) }) {
                let last = index + phrase.count - 1
                if c.isSetApartAfter(last) {
                    result.append(c.suggestion(.filler, index...last, confidence: 0.6,
                                               reason: "“\(phrase.joined(separator: " "))” used as a filler"))
                    index = last + 1
                    continue
                }
            }
            if let phrase = c.lexicon.ambiguousFillers.first(where: { c.matches($0, at: index) }) {
                let last = index + phrase.count - 1
                if c.isSetApartBefore(index), c.isSetApartAfter(last) {
                    result.append(c.suggestion(.filler, index...last, confidence: 0.35,
                                               reason: "“\(phrase.joined(separator: " "))” may be a filler"))
                    index = last + 1
                    continue
                }
            }
            index += 1
        }
        return result
    }

    // MARK: Repeats and stutters

    static func repeats(_ c: Context) -> [Suggestion] {
        var result: [Suggestion] = []
        var index = 0
        outer: while index < c.count {
            // Phrases said twice in a row ("let me, let me"), longest first.
            for size in stride(from: 4, through: 2, by: -1) where index + 2 * size <= c.count {
                let first = index..<(index + size)
                let second = (index + size)..<(index + 2 * size)
                guard c.bare[first].elementsEqual(c.bare[second]),
                      !c.bare[first].allSatisfy({ c.lexicon.emphasisWords.contains($0) || $0.isEmpty }),
                      !c.words[index + size - 1].endsSentence,
                      c.gapAfter(index + size - 1) < 1.0 else { continue }
                let phrase = c.bare[first].joined(separator: " ")
                result.append(c.suggestion(.repeat, index...(index + size - 1), confidence: 0.85,
                                           reason: "“\(phrase)” said twice", throughNext: true))
                index += size
                continue outer
            }
            // A single word said twice ("the the").
            if index + 1 < c.count, c.bare[index] == c.bare[index + 1], !c.bare[index].isEmpty,
               !c.lexicon.emphasisWords.contains(c.bare[index]), !c.lexicon.fillers.contains(c.bare[index]),
               Double(c.bare[index]) == nil, !c.words[index].endsSentence, c.gapAfter(index) < 0.6 {
                result.append(c.suggestion(.stutter, index...index, confidence: 0.7,
                                           reason: "“\(c.bare[index])” said twice", throughNext: true))
            }
            index += 1
        }
        return result
    }

    // MARK: Retakes and false starts

    static func retakes(_ c: Context) -> [Suggestion] {
        cueRetakes(c) + sentenceRetakes(c)
    }

    private enum CueKind { case interjection, correction, ambiguousCorrection, restart }

    private static func cue(at index: Int, _ c: Context) -> (kind: CueKind, length: Int)? {
        let groups: [(CueKind, [[String]])] = [
            (.restart, c.lexicon.restarts), (.correction, c.lexicon.corrections),
            (.ambiguousCorrection, c.lexicon.ambiguousCorrections), (.interjection, c.lexicon.interjections),
        ]
        for (kind, phrases) in groups {
            if let phrase = phrases.first(where: { c.matches($0, at: index) }) { return (kind, phrase.count) }
        }
        return nil
    }

    /// Corrections and restarts announced by a cue ("Wait, sorry, I meant…").
    static func cueRetakes(_ c: Context) -> [Suggestion] {
        var result: [Suggestion] = []
        var index = 0
        while index < c.count {
            guard let first = cue(at: index, c) else {
                index += 1
                continue
            }
            // A block of adjacent cues: "wait, sorry, I meant".
            var kinds = [first.kind]
            var end = index + first.length
            while end < c.count, let next = cue(at: end, c) {
                kinds.append(next.kind)
                end += next.length
            }
            let block = index..<end
            defer { index = end }
            let lastCueWord = block.upperBound - 1

            if kinds.contains(.restart) {
                var start = c.sentenceStart(of: block.lowerBound)
                if start == block.lowerBound, start > 0 { start = c.sentenceStart(of: start - 1) }
                guard start < block.lowerBound else { continue }
                result.append(c.suggestion(.falseStart, start...lastCueWord, confidence: 0.7,
                                           reason: "Restarted: “\(c.text(block))”", throughNext: true))
                continue
            }

            let hasInterjection = kinds.contains(.interjection)
            if kinds.contains(.correction) || kinds.contains(.ambiguousCorrection) {
                guard block.lowerBound > 0 else { continue }
                let echo = echoLength(before: block.lowerBound, after: block.upperBound, c)
                let setApart = c.isSetApartBefore(block.lowerBound) && c.isSetApartAfter(lastCueWord)
                let onlyAmbiguous = !kinds.contains(.correction)
                if onlyAmbiguous, !hasInterjection, !(setApart && echo != nil) { continue }
                if !hasInterjection, !setApart { continue }
                let abandonedStart = block.lowerBound - (echo ?? 1)
                let replacement = c.text(block.upperBound..<c.phraseEnd(from: block.upperBound, maximum: 3))
                result.append(c.suggestion(.retake, abandonedStart...lastCueWord, confidence: hasInterjection ? 0.75 : 0.6,
                                           reason: "Corrected: “\(c.text(abandonedStart..<block.lowerBound))” → “\(replacement)”",
                                           throughNext: true))
                continue
            }

            // Only interjections: a false start when the words after restate
            // the abandoned ones ("So what we're going to— wait. So what we'll do…").
            guard block.lowerBound > 0 else { continue }
            let following = c.bare[block.upperBound..<min(c.count, block.upperBound + 8)]
            var start = c.sentenceStart(of: block.lowerBound)
            if start == block.lowerBound {
                // The cue opens a sentence: the previous sentence was finished,
                // so only a restart with the same opening counts.
                start = c.sentenceStart(of: block.lowerBound - 1)
                guard block.lowerBound - start >= 2, following.count >= 2,
                      c.bare[start..<(start + 2)].elementsEqual(following.prefix(2)) else { continue }
            } else {
                let abandoned = Set(c.bare[start..<block.lowerBound])
                let shared = abandoned.intersection(following).filter { $0.count > 2 }
                guard shared.count >= 2 || following.first == c.bare[start] else { continue }
            }
            result.append(c.suggestion(.falseStart, start...lastCueWord, confidence: 0.6,
                                       reason: "Abandoned and restated after “\(c.text(block))”", throughNext: true))
        }
        return result
    }

    /// How many words before a cue the replacement after it starts echoing
    /// ("el martes, digo, el miércoles" → 2: "el martes" is replaced).
    private static func echoLength(before cueStart: Int, after cueEnd: Int, _ c: Context) -> Int? {
        guard cueEnd < c.count else { return nil }
        for length in 1...4 where cueStart - length >= 0 && c.bare[cueStart - length] == c.bare[cueEnd] {
            return length
        }
        return nil
    }

    /// Sentences said again: a false start that's a prefix of the next
    /// sentence, or a sentence redone with only its last word changed.
    static func sentenceRetakes(_ c: Context) -> [Suggestion] {
        var result: [Suggestion] = []
        let sentences = c.sentences()
        for (a, b) in zip(sentences, sentences.dropFirst()) {
            let first = c.bare[a].filter { !c.lexicon.fillers.contains($0) }
            let second = c.bare[b].filter { !c.lexicon.fillers.contains($0) }
            guard first.count >= 2 else { continue }
            let prefix = zip(first, second).prefix { $0 == $1 }.count
            let range = a.lowerBound...(a.upperBound - 1)
            if prefix == first.count, first.count < second.count {
                result.append(c.suggestion(.falseStart, range, confidence: 0.8,
                                           reason: "Started, then said again in full", throughNext: true))
            } else if first.count >= 3, prefix >= first.count - 1, prefix >= 2, abs(first.count - second.count) <= 2, first != second {
                // Short parallel sentences ("Open the menu. Open the file.") are
                // ordinary in tutorials: below four words this starts switched off.
                result.append(c.suggestion(.retake, range, confidence: first.count >= 4 ? 0.6 : 0.4,
                                           reason: "Said again with a change", throughNext: true))
            } else if first == second {
                result.append(c.suggestion(.repeat, range, confidence: 0.45,
                                           reason: "Same sentence twice (on purpose?)", throughNext: true))
            }
        }
        return result
    }

    // MARK: Overlaps

    /// Keeps the more confident of overlapping suggestions; fillers inside a
    /// kept mistake are dropped (the mistake removes them anyway).
    static func resolveOverlaps(_ suggestions: [Suggestion]) -> [Suggestion] {
        var kept: [Suggestion] = []
        let ordered = suggestions.sorted {
            ($0.kind.isMistake ? 1 : 0, $0.confidence, $0.range.duration) > ($1.kind.isMistake ? 1 : 0, $1.confidence, $1.range.duration)
        }
        for suggestion in ordered {
            let clashes = kept.contains { other in
                guard let overlap = other.range.intersection(suggestion.range) else { return false }
                return overlap.duration >= 0.5 * min(other.range.duration, suggestion.range.duration)
            }
            if !clashes { kept.append(suggestion) }
        }
        return kept.sorted { $0.range.start < $1.range.start }
    }

    // MARK: Context

    /// Words with the lookups the rules share.
    struct Context {
        let words: [TranscriptWord]
        let bare: [String]
        let lexicon: Lexicon

        init(_ transcript: Transcript) {
            words = transcript.words
            bare = transcript.words.map(\.bare)
            lexicon = Lexicon.for(transcript.language)
        }

        var count: Int { words.count }

        func matches(_ phrase: [String], at index: Int) -> Bool {
            guard index >= 0, index + phrase.count <= count else { return false }
            return bare[index..<(index + phrase.count)].elementsEqual(phrase)
        }

        func gapBefore(_ index: Int) -> Double {
            index > 0 ? words[index].start - words[index - 1].end : .infinity
        }

        func gapAfter(_ index: Int) -> Double {
            index + 1 < count ? words[index + 1].start - words[index].end : .infinity
        }

        /// A pause or punctuation separates the word from what follows.
        func isSetApartAfter(_ index: Int) -> Bool {
            words[index].endsSentence || words[index].endsClause || gapAfter(index) >= 0.15
        }

        func isSetApartBefore(_ index: Int) -> Bool {
            index == 0 || words[index - 1].endsSentence || words[index - 1].endsClause || gapBefore(index) >= 0.15
        }

        /// First word of the sentence holding `index`.
        func sentenceStart(of index: Int) -> Int {
            var start = index
            while start > 0, !words[start - 1].endsSentence, gapBefore(start) < RuleBasedEditor.sentenceGap { start -= 1 }
            return start
        }

        /// Word ranges of the sentences, by punctuation or long gaps.
        func sentences() -> [Range<Int>] {
            var result: [Range<Int>] = []
            var start = 0
            for index in words.indices where words[index].endsSentence || gapAfter(index) >= RuleBasedEditor.sentenceGap || index == count - 1 {
                result.append(start..<(index + 1))
                start = index + 1
            }
            return result
        }

        /// End (exclusive) of up to `maximum` words from `start`, stopping
        /// after a word that ends a sentence.
        func phraseEnd(from start: Int, maximum: Int) -> Int {
            var end = start
            while end < min(count, start + maximum) {
                end += 1
                if words[end - 1].endsSentence { break }
            }
            return end
        }

        func text(_ range: Range<Int>) -> String {
            words[range.clamped(to: 0..<count)].map(\.text).joined(separator: " ")
        }

        /// A suggestion removing `range` of words. `throughNext` extends it
        /// to the next word's start (removing the pause after it) when that
        /// pause is short; otherwise it ends shortly after the last word.
        func suggestion(_ kind: SuggestionKind, _ range: ClosedRange<Int>, confidence: Double, reason: String,
                        throughNext: Bool = false) -> Suggestion {
            let start = words[range.lowerBound].start
            var end = words[range.upperBound].end
            if throughNext, range.upperBound + 1 < count {
                let next = words[range.upperBound + 1].start
                end = next - end < 1.0 ? next : end + 0.1
            }
            return Suggestion(kind: kind, range: TimeRange(start: start, end: end), words: range,
                              confidence: confidence, reason: reason, source: .rules)
        }
    }
}
