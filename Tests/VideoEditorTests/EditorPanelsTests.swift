import AppCore
import Foundation
import Testing
import Transcription
@testable import VideoEditor

@Suite("Timeline viewport")
struct TimelineViewportTests {
    @Test func zoomKeepsTheAnchorInPlace() {
        var viewport = TimelineViewport()
        viewport.zoom(by: 4, around: 30, duration: 120)
        #expect(viewport.zoom == 4)
        #expect(viewport.span(duration: 120) == 30)
        // 30 s was a quarter of the way across; it still is.
        #expect(abs((30 - viewport.start) / 30 - 0.25) < 1e-9)
    }

    @Test func zoomAndPanStayInsideTheSource() {
        var viewport = TimelineViewport()
        viewport.zoom(by: 0.5, around: 10, duration: 60)
        #expect(viewport == TimelineViewport())
        viewport.zoom(by: 1000, around: 59, duration: 60)
        #expect(viewport.zoom == TimelineViewport.maximumZoom(duration: 60))
        #expect(viewport.end(duration: 60) <= 60 + 1e-9)
        viewport.pan(by: -1000, duration: 60)
        #expect(viewport.start == 0)
        viewport.pan(by: 1000, duration: 60)
        #expect(abs(viewport.end(duration: 60) - 60) < 1e-9)
        viewport.fit()
        #expect(!viewport.isZoomed)
    }

    @Test func revealAndFollow() {
        var viewport = TimelineViewport(zoom: 10, start: 0)
        // Already visible: nothing moves.
        let movedForVisible = viewport.reveal(TimeRange(start: 2, end: 3), duration: 100)
        #expect(!movedForVisible)
        let movedForFar = viewport.reveal(TimeRange(start: 50, end: 51), duration: 100)
        #expect(movedForFar)
        #expect(viewport.contains(50, duration: 100) && viewport.contains(51, duration: 100))
        let followedInside = viewport.follow(playhead: 51.5, duration: 100)
        #expect(!followedInside)
        let followedPast = viewport.follow(playhead: 70, duration: 100)
        #expect(followedPast)
        #expect(viewport.contains(70, duration: 100))
        // Not zoomed: the whole source shows, so nothing to do.
        var whole = TimelineViewport()
        let movedWhole = whole.reveal(TimeRange(start: 90, end: 95), duration: 100)
        #expect(!movedWhole)
    }

    @Test func scaleMapsTheVisibleWindow() {
        let scale = TimelineScale(duration: 100, width: 1016, inset: 8, viewport: TimelineViewport(zoom: 10, start: 40))
        #expect(scale.span == 10)
        #expect(scale.x(40) == 8)
        #expect(scale.x(50) == 1008)
        #expect(abs(scale.time(508) - 45) < 1e-9)
        #expect(abs(scale.seconds(100) - 1) < 1e-9)
        #expect(scale.isVisible(TimeRange(start: 30, end: 41)))
        #expect(!scale.isVisible(TimeRange(start: 60, end: 61)))
    }
}

@Suite("Transcript editing")
struct TranscriptEditingTests {
    private func words(_ texts: [String]) -> [TranscriptWord] {
        texts.enumerated().map { TranscriptWord(text: $1, start: Double($0), end: Double($0) + 0.5) }
    }

    @Test func untouchedWordsKeepTheirTimes() {
        let original = words(["We", "met", "Alpiza", "and", "Loana", "today."])
        let edited = TranscriptEditing.words(original, editedTo: "We met Alfonso and Lorena today.")
        #expect(edited.map(\.text) == ["We", "met", "Alfonso", "and", "Lorena", "today."])
        #expect(edited[0] == original[0] && edited[3] == original[3] && edited[5] == original[5])
        #expect(edited[2].start == original[2].start && edited[2].end == original[2].end)
    }

    @Test func replacedRunsShareTheirSpan() {
        let original = words(["the", "numbers", "four", "April."])
        let edited = TranscriptEditing.words(original, editedTo: "the numbers for April.")
        #expect(edited.map(\.text) == ["the", "numbers", "for", "April."])
        let split = TranscriptEditing.words(original, editedTo: "the num bers four April.")
        #expect(split.map(\.text) == ["the", "num", "bers", "four", "April."])
        #expect(split[1].start == 1 && split[2].end == 1.5)
        #expect(split[1].end == split[2].start)
    }

    @Test func addedAndDeletedWords() {
        let original = words(["one", "two", "three"])
        // Into the 0.5 s silence after "one".
        let added = TranscriptEditing.words(original, editedTo: "one and two three")
        #expect(added.map(\.text) == ["one", "and", "two", "three"])
        #expect(added[1].start == 0.5 && added[1].end == 1)
        // Too many for the silence: they share "one"'s time instead.
        let crowded = TranscriptEditing.words(original, editedTo: "one and then also so two three")
        #expect(crowded.map(\.text) == ["one", "and", "then", "also", "so", "two", "three"])
        #expect(crowded[0].start == 0 && crowded[4].end == 0.5)
        #expect(crowded[5] == original[1])
        // Before the first word, which starts at 0.
        let first = TranscriptEditing.words(original, editedTo: "So one two three")
        #expect(first.map(\.text) == ["So", "one", "two", "three"])
        #expect(first[0].start == 0 && first[1].end == 0.5)
        // Deleted words leave the transcript (not the video).
        let deleted = TranscriptEditing.words(original, editedTo: "one three")
        #expect(deleted == [original[0], original[2]])
        #expect(TranscriptEditing.words(original, editedTo: "").isEmpty)
    }

    @Test func paragraphsAreOnlyLayout() {
        let original = [TranscriptWord(text: "End.", start: 0, end: 0.5), TranscriptWord(text: "Next", start: 3, end: 3.4)]
        let text = TranscriptEditing.text(of: original, paragraphPause: 1.5)
        #expect(text == "End.\nNext")
        #expect(TranscriptEditing.words(original, editedTo: text) == original)
    }

    @Test func correctAllFindsTheSameWordsAndKeepsPunctuation() {
        let original = words(["Hi", "alpiza,", "how", "is", "Alpiza?", "Alpiza", "said", "alpiza."])
        let others = TranscriptEditing.occurrences(of: 1...1, in: original)
        #expect(others == [4...4, 5...5, 7...7])
        let fixed = TranscriptEditing.correcting(original, 1...1, to: "Alfonso,", alsoAt: others)
        #expect(fixed.map(\.text) == ["Hi", "Alfonso,", "how", "is", "Alfonso?", "Alfonso", "said", "Alfonso."])
        #expect(fixed.map(\.start) == original.map(\.start))

        // Phrases too, without overlapping the original.
        let phrase = words(["New", "work", "and", "new", "work"])
        #expect(TranscriptEditing.occurrences(of: 0...1, in: phrase) == [3...4])
        let replaced = TranscriptEditing.correcting(phrase, 0...1, to: "Newark", alsoAt: [3...4])
        #expect(replaced.map(\.text) == ["Newark", "and", "Newark"])
        #expect(replaced[0].start == 0 && replaced[0].end == 1.5)
    }
}
