import CoreMedia
import Testing
@testable import Recording

private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

@Suite("PauseTimeline")
struct PauseTimelineTests {
    @Test func withoutPausesOutputEqualsInput() {
        let timeline = PauseTimeline()
        #expect(timeline.outputTime(for: t(12.5)) == t(12.5))
        #expect(!timeline.isPaused)
    }

    @Test func samplesDuringPauseAreDropped() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(10))
        timeline.resume(at: t(13))
        #expect(timeline.outputTime(for: t(9.99)) == t(9.99))
        #expect(timeline.outputTime(for: t(10)) == nil)
        #expect(timeline.outputTime(for: t(12.99)) == nil)
        #expect(timeline.outputTime(for: t(13)) == t(10))
        #expect(timeline.outputTime(for: t(15)) == t(12))
    }

    @Test func openPauseDropsEverythingAfterIt() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(5))
        #expect(timeline.isPaused)
        #expect(timeline.outputTime(for: t(4.5)) == t(4.5))
        #expect(timeline.outputTime(for: t(500)) == nil)
    }

    @Test func multipleCyclesAccumulate() {
        var timeline = PauseTimeline()
        timeline.pause(at: t(2)); timeline.resume(at: t(3))   // 1 s
        timeline.pause(at: t(5)); timeline.resume(at: t(7.5)) // 2.5 s
        timeline.pause(at: t(10)); timeline.resume(at: t(10.5)) // 0.5 s
        #expect(timeline.pausedDuration(before: t(20)) == t(4))
        #expect(timeline.outputTime(for: t(20)) == t(16))
        #expect(timeline.outputTime(for: t(8)) == t(4.5))
        #expect(timeline.intervals.count == 3)
    }

    @Test func outputTimesAreMonotonicAcrossPauses() {
        var timeline = PauseTimeline()
        for cycle in 0..<10 {
            let base = Double(cycle) * 3
            timeline.pause(at: t(base + 1))
            timeline.resume(at: t(base + 2))
        }
        var last = CMTime.negativeInfinity
        var kept = 0
        for frame in 0..<(35 * 60) {
            let host = t(Double(frame) / 60)
            guard let output = timeline.outputTime(for: host) else { continue }
            #expect(output > last)
            last = output
            kept += 1
        }
        #expect(kept > 0)
    }

    @Test func redundantCallsAreIgnored() {
        var timeline = PauseTimeline()
        timeline.resume(at: t(1))          // not paused: ignored
        timeline.pause(at: t(2))
        timeline.pause(at: t(3))           // already paused: ignored
        timeline.resume(at: t(4))
        timeline.resume(at: t(5))          // ignored
        timeline.pause(at: t(3.5))         // before last resume: ignored
        #expect(timeline.intervals == [PauseTimeline.Interval(start: t(2), end: t(4))])
    }

    @Test func elapsedExcludesPauses() {
        var timeline = PauseTimeline()
        let start = t(100)
        timeline.pause(at: t(103)); timeline.resume(at: t(105))
        #expect(timeline.elapsedSeconds(from: start, to: t(110)) == 8)

        // While paused, elapsed freezes.
        timeline.pause(at: t(110))
        #expect(timeline.elapsedSeconds(from: start, to: t(111)) == 8)
        #expect(timeline.elapsedSeconds(from: start, to: t(150)) == 8)
        timeline.resume(at: t(150))
        #expect(timeline.elapsedSeconds(from: start, to: t(151)) == 9)
    }

    @Test func elapsedBeforeStartIsZero() {
        #expect(PauseTimeline().elapsed(from: t(10), to: t(5)) == .zero)
    }
}
