import Foundation
import Transcription

/// Corrections to the transcript's words (PRD CAP-2, ADR-36). Words the
/// user didn't touch keep their times; new words share the time of the
/// words they replace, in proportion to their length, so captions stay in
/// sync. The video is never changed.
enum TranscriptEditing {
    /// `tokens` spread over `start...end`, each getting a share of the time
    /// proportional to its length.
    static func words(_ tokens: [String], from start: Double, to end: Double) -> [TranscriptWord] {
        guard !tokens.isEmpty else { return [] }
        let total = Double(tokens.reduce(0) { $0 + $1.count })
        var cursor = start
        return tokens.enumerated().map { offset, token in
            let share = total > 0 ? Double(token.count) / total : 1 / Double(tokens.count)
            let wordEnd = offset == tokens.count - 1 ? end : cursor + (end - start) * share
            defer { cursor = wordEnd }
            return TranscriptWord(text: token, start: cursor, end: wordEnd, confidence: 1)
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The words after the user rewrote the whole text (the panel's Edit
    /// Text mode). Unchanged words are matched by a diff; each run of
    /// changed words takes the time of the run it replaced. Words added
    /// where nothing was said go into the silence there, or share the
    /// previous word's time when the silence is too short.
    static func words(_ original: [TranscriptWord], editedTo text: String) -> [TranscriptWord] {
        let new = tokens(text)
        let old = original.map(\.text)
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }

        var result: [TranscriptWord] = []
        result.reserveCapacity(new.count)
        var i = 0
        var j = 0
        while i < old.count || j < new.count {
            if i < old.count, j < new.count, !removed.contains(i), !inserted.contains(j) {
                result.append(original[i])
                i += 1
                j += 1
                continue
            }
            let replacedStart = i
            while i < old.count, removed.contains(i) { i += 1 }
            let addedStart = j
            while j < new.count, inserted.contains(j) { j += 1 }
            guard i > replacedStart || j > addedStart else { break }
            let added = Array(new[addedStart..<j])
            guard !added.isEmpty else { continue }

            if i > replacedStart {
                result += words(added, from: original[replacedStart].start, to: original[i - 1].end)
                continue
            }
            let previousEnd = result.last?.end ?? 0
            let nextStart = i < original.count ? original[i].start : previousEnd
            if nextStart - previousEnd >= 0.15 * Double(added.count) {
                result += words(added, from: previousEnd, to: nextStart)
            } else if let previous = result.popLast() {
                result += words([previous.text] + added, from: previous.start, to: previous.end)
            } else if i < original.count, j < new.count, !inserted.contains(j) {
                // Added before the first word: it shares that word's time.
                let next = original[i]
                result += words(added + [next.text], from: next.start, to: next.end)
                i += 1
                j += 1
            } else {
                result += words(added, from: previousEnd, to: nextStart)
            }
        }
        return result
    }

    /// Every other run of words that reads the same as `range` (ignoring
    /// case and punctuation), so a misheard name can be fixed everywhere.
    static func occurrences(of range: ClosedRange<Int>, in words: [TranscriptWord]) -> [ClosedRange<Int>] {
        guard range.lowerBound >= 0, range.upperBound < words.count else { return [] }
        let target = words[range].map(\.bare)
        let length = target.count
        guard !target.allSatisfy(\.isEmpty) else { return [] }
        var found: [ClosedRange<Int>] = []
        var index = 0
        while index + length <= words.count {
            let candidate = index...(index + length - 1)
            if !candidate.overlaps(range), words[candidate].map(\.bare) == target {
                found.append(candidate)
                index += length
            } else {
                index += 1
            }
        }
        return found
    }

    /// Replaces `range` with `text`, and each of `others` too. The others
    /// keep their own trailing punctuation: correcting "alpiza," to
    /// "Alfonso," turns "Alpiza?" into "Alfonso?".
    static func correcting(_ words: [TranscriptWord], _ range: ClosedRange<Int>, to text: String,
                           alsoAt others: [ClosedRange<Int>] = []) -> [TranscriptWord] {
        let replacement = tokens(text)
        var result = words
        // From the end, so earlier ranges keep their indices.
        let targets = ([range] + others).sorted { $0.lowerBound > $1.lowerBound }
        for target in targets where target.lowerBound >= 0 && target.upperBound < result.count {
            var tokens = replacement
            if target != range, let last = tokens.last {
                tokens[tokens.count - 1] = String(last.dropLast(trailingPunctuation(last).count))
                    + trailingPunctuation(result[target.upperBound].text)
            }
            let start = result[target.lowerBound].start
            let end = result[target.upperBound].end
            result.replaceSubrange(target, with: Self.words(tokens, from: start, to: end))
        }
        return result
    }

    private static func trailingPunctuation(_ word: String) -> String {
        String(word.reversed().prefix { $0.isPunctuation }.reversed())
    }

    /// The text the panel shows: words separated by spaces, with a new
    /// paragraph after a long pause.
    static func text(of words: [TranscriptWord], paragraphPause: Double) -> String {
        var text = ""
        for (index, word) in words.enumerated() {
            text += word.text
            guard index + 1 < words.count else { break }
            text += words[index + 1].start - word.end >= paragraphPause ? "\n" : " "
        }
        return text
    }
}
