import AppCore
import AutoEdit
import Foundation
import Transcription

/// Editing by transcript (PRD AE-10) and correcting it (CAP-2). The
/// transcript lives in the project, so corrections are undoable and saved
/// with the edits.
extension VideoEditorModel {
    /// What happens to a word in the edited video.
    enum WordState: Equatable {
        case kept
        /// Outside the trim.
        case trimmed
        /// Inside one of the user's cuts.
        case cut
        /// Inside an enabled auto-edit removal.
        case autoRemoved(AutoEditGroup)
    }

    var transcript: Transcript? { project.transcript }

    /// The state of every word, in one pass over the sorted cuts. Matches
    /// playback: auto-edit counts only when `effectiveCuts` applies it, and
    /// its pause cuts count too (a dragged edge can reach into speech).
    func wordStates() -> [WordState] {
        guard let words = project.transcript?.words else { return [] }
        let trim = project.trim
        let cuts = TimeRange.merged(project.cuts)
        let removals = autoRemovals().sorted { $0.range.start < $1.range.start }
        var cutIndex = 0
        var removalIndex = 0
        return words.map { word in
            let time = word.range.midpoint
            guard trim.contains(time) else { return .trimmed }
            while cutIndex < cuts.count, cuts[cutIndex].end <= time { cutIndex += 1 }
            if cutIndex < cuts.count, cuts[cutIndex].contains(time) { return .cut }
            while removalIndex < removals.count, removals[removalIndex].range.end <= time { removalIndex += 1 }
            // Removals can overlap; check the next few that start before the word.
            for removal in removals[removalIndex...].prefix(4) where removal.range.contains(time) {
                return .autoRemoved(removal.group)
            }
            return .kept
        }
    }

    /// What auto-edit removes from playback, by group: nothing when
    /// `effectiveCuts` sets it aside for leaving too little footage.
    private func autoRemovals() -> [(range: TimeRange, group: AutoEditGroup)] {
        guard let layer = project.autoEdit, project.effectiveCuts != project.cuts else { return [] }
        var ranges = layer.removals
            .filter { $0.isEnabled && layer.groups.contains($0.group) }
            .map { (range: $0.range, group: $0.group) }
        if layer.groups.contains(.pauses) {
            ranges += layer.pauses.compactMap { $0.cut(pacing: layer.pacing) }.map { (range: $0, group: AutoEditGroup.pauses) }
        }
        return ranges
    }

    /// The word playing at source `time` (or the last one before it).
    func wordIndex(atSource time: Double) -> Int? {
        guard let words = project.transcript?.words, !words.isEmpty else { return nil }
        var low = 0
        var high = words.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if words[middle].start <= time { low = middle } else { high = middle - 1 }
        }
        return words[low].start <= time ? low : nil
    }

    /// Up to `count` words just before and just after `range` (the review's
    /// context around a suggestion).
    func words(around range: TimeRange, count: Int) -> (before: String, after: String) {
        guard let words = project.transcript?.words, !words.isEmpty else { return ("", "") }
        let firstInside = firstWord(in: words) { $0.range.midpoint >= range.start }
        let firstAfter = firstWord(in: words) { $0.range.midpoint > range.end }
        let before = words[max(0, firstInside - count)..<firstInside].map(\.text).joined(separator: " ")
        let after = words[firstAfter..<min(words.count, firstAfter + count)].map(\.text).joined(separator: " ")
        return (before, after)
    }

    /// The first word for which `isPast` holds; words are in time order.
    private func firstWord(in words: [TranscriptWord], where isPast: (TranscriptWord) -> Bool) -> Int {
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if isPast(words[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    func seek(toWord index: Int) {
        guard let word = project.transcript?.words[safe: index] else { return }
        transcriptSelection = nil
        seek(toSource: word.start)
    }

    /// The source range a run of words occupies, through the pause after it
    /// when that pause is short (like auto-edit's removals).
    func sourceRange(ofWords range: ClosedRange<Int>) -> TimeRange? {
        guard let words = project.transcript?.words, range.lowerBound >= 0, range.upperBound < words.count else { return nil }
        let start = words[range.lowerBound].start
        var end = words[range.upperBound].end
        if range.upperBound + 1 < words.count {
            let next = words[range.upperBound + 1].start
            end = next - end < 1.0 ? next : end + 0.1
        }
        return TimeRange(start: start, end: end)
    }

    /// Whether every word in `range` is already removed.
    func areWordsRemoved(_ range: ClosedRange<Int>) -> Bool {
        let states = wordStates()
        return range.allSatisfy { states[safe: $0].map { $0 != .kept } ?? false }
    }

    /// ⌫ on selected words: cuts them, or brings them back if they're all removed.
    func cutWords(_ range: ClosedRange<Int>) {
        guard let removed = sourceRange(ofWords: range) else { return }
        if areWordsRemoved(range) {
            restore(removed)
        } else {
            edit { $0.addCut(removed) }
        }
        transcriptSelection = nil
    }

    /// Brings back footage: the trim grows to include it, the user's cuts
    /// shrink around it, and auto-edit's removals and pause cuts there
    /// switch off.
    func restore(_ range: TimeRange) {
        edit { project in
            let trim = project.trim
            if range.start < trim.start || range.end > trim.end {
                project.trim = TimeRange(start: max(0, min(trim.start, range.start)),
                                         end: min(project.sourceDuration, max(trim.end, range.end)))
            }
            project.cuts = TimeRange.merged(project.cuts.flatMap { $0.subtracting(range) })
            guard var layer = project.autoEdit else { return }
            for index in layer.removals.indices where layer.removals[index].range.overlaps(range) {
                layer.removals[index].isEnabled = false
                layer.removals[index].isUserEdited = true
            }
            // Only pause cuts over the words themselves: `range` also spans
            // the pause after them, whose shortening stays.
            let words = (project.transcript?.words ?? []).map(\.range.midpoint).filter { range.contains($0) }
            for index in layer.pauses.indices {
                guard let cut = layer.pauses[index].cut(pacing: layer.pacing), words.contains(where: { cut.contains($0) }) else { continue }
                layer.pauses[index].keepsLength = true
                layer.pauses[index].adjustedCut = nil
            }
            project.autoEdit = layer
        }
    }

    /// A zoom over the selected words.
    func zoomWords(_ range: ClosedRange<Int>) {
        guard let span = sourceRange(ofWords: range) else { return }
        var added: ZoomSegment?
        edit { added = $0.addZoom(at: span.start, duration: max(1.5, span.duration + 0.5)) }
        selectedZoomID = added?.id
        transcriptSelection = nil
    }

    /// Replaces the selected words with `text` (CAP-2), and with
    /// `everywhere` every other run that reads the same (a misheard name).
    /// Each new word gets a share of the original time proportional to its
    /// length, so captions stay in sync. Empty text removes the words from
    /// the transcript (not from the video).
    func correctWords(_ range: ClosedRange<Int>, to text: String, everywhere: Bool = false) {
        guard var transcript = project.transcript, range.lowerBound >= 0, range.upperBound < transcript.words.count else { return }
        let others = everywhere ? TranscriptEditing.occurrences(of: range, in: transcript.words) : []
        transcript.words = TranscriptEditing.correcting(transcript.words, range, to: text, alsoAt: others)
        edit { $0.transcript = transcript }
        transcriptSelection = nil
        wordsBeingCorrected = nil
    }

    /// How many other places read the same as `range` ("Correct all").
    func otherOccurrences(of range: ClosedRange<Int>) -> Int {
        guard let words = project.transcript?.words else { return 0 }
        return TranscriptEditing.occurrences(of: range, in: words).count
    }

    /// Opens the correction popover over `range` (double-click or Return).
    func beginCorrecting(_ range: ClosedRange<Int>) {
        guard let count = project.transcript?.words.count, range.upperBound < count else { return }
        transcriptSelection = range
        wordsBeingCorrected = range
    }

    /// The whole transcript as the user rewrote it (Edit Text mode). One
    /// undo step; unchanged words keep their times.
    func applyTranscriptText(_ text: String) {
        guard var transcript = project.transcript else { return }
        let words = TranscriptEditing.words(transcript.words, editedTo: text)
        guard words != transcript.words else { return }
        transcript.words = words
        edit { $0.transcript = transcript }
        transcriptSelection = nil
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
