import Foundation
import Testing
@testable import VideoEditor

private func approx(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
    abs(a - b) <= tolerance
}

private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: start, end: end)
}

@Suite("TimeRange")
struct TimeRangeTests {
    @Test func mergesOverlappingAndTouchingRanges() {
        let merged = TimeRange.merged([range(5, 6), range(1, 2), range(1.5, 3), range(3, 4), range(8, 8)])
        #expect(merged == [range(1, 4), range(5, 6)])
    }

    @Test func subtractingSplitsAroundTheHole() {
        #expect(range(0, 10).subtracting(range(2, 3)) == [range(0, 2), range(3, 10)])
        #expect(range(0, 10).subtracting(range(-1, 3)) == [range(3, 10)])
        #expect(range(0, 10).subtracting(range(8, 12)) == [range(0, 8)])
        #expect(range(0, 10).subtracting(range(-1, 12)).isEmpty)
        #expect(range(0, 10).subtracting(range(11, 12)) == [range(0, 10)])
    }

    @Test func intersectionOfDisjointRangesIsNil() {
        #expect(range(0, 1).intersection(range(1, 2)) == nil)
        #expect(range(0, 2).intersection(range(1, 3)) == range(1, 2))
    }
}

@Suite("Timeline")
struct TimelineTests {
    @Test func untouchedSourceMapsOneToOne() {
        let timeline = Timeline(sourceDuration: 10)
        #expect(timeline.outputDuration == 10)
        #expect(timeline.outputTime(forSource: 3.5) == 3.5)
        #expect(timeline.sourceTime(forOutput: 7.25) == 7.25)
    }

    @Test func trimShiftsTheOutputOrigin() {
        let timeline = Timeline(sourceDuration: 10, trim: range(2, 8))
        #expect(timeline.outputDuration == 6)
        #expect(timeline.outputTime(forSource: 2) == 0)
        #expect(timeline.outputTime(forSource: 1) == nil)
        #expect(timeline.outputTime(forSource: 9) == nil)
        #expect(timeline.sourceTime(forOutput: 0) == 2)
        #expect(timeline.sourceTime(forOutput: 6) == 8)
    }

    @Test func overlappingCutsAreMergedAndClamped() {
        let kept = Timeline.keptRanges(
            sourceDuration: 10,
            trim: range(1, 9),
            cuts: [range(2, 4), range(3, 5), range(-3, 1.5), range(8.5, 20)]
        )
        #expect(kept == [range(1.5, 2), range(5, 8.5)])
    }

    @Test func cutsOutsideTheTrimDontMatter() {
        let timeline = Timeline(sourceDuration: 10, trim: range(2, 6), cuts: [range(0, 1), range(7, 9)])
        #expect(timeline.outputDuration == 4)
        #expect(timeline.segments.count == 1)
    }

    @Test func cutRemovesTimeAndSkipsTheGap() {
        let timeline = Timeline(sourceDuration: 10, cuts: [range(3, 5)])
        #expect(timeline.outputDuration == 8)
        #expect(timeline.outputTime(forSource: 2) == 2)
        #expect(timeline.outputTime(forSource: 4) == nil)
        #expect(timeline.outputTime(forSource: 6) == 4)
        #expect(timeline.sourceTime(forOutput: 3) == 5) // boundary belongs to the next segment
        #expect(timeline.sourceTime(forOutput: 2.999) < 3)
        #expect(timeline.nearestOutputTime(forSource: 4) == 3)
    }

    @Test func cutCoveringEverythingLeavesAnEmptyTimeline() {
        let timeline = Timeline(sourceDuration: 5, cuts: [range(0, 5)])
        #expect(timeline.segments.isEmpty)
        #expect(timeline.outputDuration == 0)
        #expect(timeline.sourceTime(forOutput: 1) == 0)
        #expect(timeline.nearestOutputTime(forSource: 2) == 0)
    }

    @Test func zeroDurationSourceIsEmpty() {
        let timeline = Timeline(sourceDuration: 0)
        #expect(timeline.segments.isEmpty)
        #expect(timeline.outputDuration == 0)
    }

    @Test func speedSegmentsChangeOutputDuration() {
        let timeline = Timeline(
            sourceDuration: 10,
            speedSegments: [SpeedSegment(range: range(2, 6), rate: 2)]
        )
        // 2 s + 4 s at 2× + 4 s = 8 s
        #expect(timeline.outputDuration == 8)
        #expect(timeline.segments.map(\.rate) == [1, 2, 1])
        #expect(timeline.outputTime(forSource: 4) == 3)
        #expect(timeline.outputTime(forSource: 6) == 4)
        #expect(timeline.outputTime(forSource: 8) == 6)
        #expect(timeline.sourceTime(forOutput: 3) == 4)
        #expect(timeline.sourceTime(forOutput: 6) == 8)
    }

    @Test func slowMotionLengthensOutput() {
        let timeline = Timeline(sourceDuration: 4, speedSegments: [SpeedSegment(range: range(0, 2), rate: 0.5)])
        #expect(timeline.outputDuration == 6)
        #expect(timeline.sourceTime(forOutput: 2) == 1)
    }

    @Test func speedCombinesWithCutsAndTrim() throws {
        let timeline = Timeline(
            sourceDuration: 20,
            trim: range(1, 19),
            cuts: [range(5, 7)],
            speedSegments: [SpeedSegment(range: range(4, 12), rate: 4)]
        )
        // kept: [1,5) + [7,19). speed 4× on [4,5) and [7,12).
        // output: 3 + 0.25 + 1.25 + 7 = 11.5
        #expect(approx(timeline.outputDuration, 11.5))
        #expect(timeline.segments.count == 4)
        for source in stride(from: 1.0, through: 19.0, by: 0.37) where timeline.isKept(source: source) {
            let output = try #require(timeline.outputTime(forSource: source))
            #expect(approx(timeline.sourceTime(forOutput: output), source, 1e-9))
        }
    }

    @Test func overlappingSpeedSegmentsFirstWins() {
        let timeline = Timeline(
            sourceDuration: 10,
            speedSegments: [SpeedSegment(range: range(4, 8), rate: 4), SpeedSegment(range: range(2, 6), rate: 2)]
        )
        // [0,2)@1 + [2,6)@2 + [6,8)@4 + [8,10)@1 = 2 + 2 + 0.5 + 2
        #expect(approx(timeline.outputDuration, 6.5))
    }

    @Test func outputDurationOfSourceRangeCountsOnlyKeptParts() {
        let timeline = Timeline(sourceDuration: 10, cuts: [range(2, 4)], speedSegments: [SpeedSegment(range: range(6, 10), rate: 2)])
        #expect(approx(timeline.outputDuration(ofSource: range(1, 8)), 1 + 2 + 1))
    }

    @Test func mappingIsMonotonic() {
        let timeline = Timeline(
            sourceDuration: 30,
            trim: range(0.5, 29),
            cuts: [range(3, 4), range(10, 12.5)],
            speedSegments: [SpeedSegment(range: range(5, 9), rate: 3), SpeedSegment(range: range(20, 25), rate: 0.5)]
        )
        var previous = -1.0
        for output in stride(from: 0, through: timeline.outputDuration, by: 0.05) {
            let source = timeline.sourceTime(forOutput: output)
            #expect(source >= previous)
            #expect(timeline.isKept(source: source))
            previous = source
        }
    }
}
