import AppCore
import AutoEdit
import AVFoundation
import Foundation
import Testing
import Transcription
@testable import VideoEditor

private func pause(_ id: Int, _ start: Double, _ end: Double, _ kind: PauseKind, source: DecisionSource = .rules) -> Pause {
    Pause(id: id, range: TimeRange(start: start, end: end), afterWord: id, kind: kind, kindSource: source)
}

private func removal(_ start: Double, _ end: Double, _ kind: SuggestionKind = .filler, confidence: Double = 0.9) -> AutoEditLayer.Removal {
    let suggestion = Suggestion(kind: kind, range: TimeRange(start: start, end: end), words: nil, confidence: confidence, reason: "test", source: .rules)
    return AutoEditLayer.Removal(suggestion: suggestion, text: "um", isEnabled: suggestion.isEnabledByDefault)
}

private func layer(pacing: Pacing = .natural) -> AutoEditLayer {
    AutoEditLayer(
        language: .english,
        pacing: pacing,
        pauses: [
            .init(pause: pause(0, 2, 4, .section)),     // 2 s section break
            .init(pause: pause(1, 6, 6.8, .hesitation)), // 0.8 s hesitation
            .init(pause: pause(2, 9, 12, .action)),      // silent screen action
        ],
        removals: [removal(5, 5.3), removal(7, 7.2, .filler, confidence: 0.35), removal(14, 16, .retake)]
    )
}

@Suite("Auto-edit layer")
struct AutoEditLayerTests {
    @Test func pacingKeepsHalfTheTargetOnEachSide() {
        let natural = layer().pauses.map { $0.cut(pacing: .natural) }
        #expect(natural[0] == TimeRange(start: 2.5, end: 3.5))      // section keeps 1.0 s
        #expect(natural[1] == TimeRange(start: 6.075, end: 6.725))  // hesitation keeps 0.15 s
        #expect(natural[2] == nil)                                   // screen actions are never cut
        #expect(abs((layer().pauses[0].cut(pacing: .tight)?.duration ?? 0) - 1.4) < 1e-9)
        #expect(abs((layer().pauses[0].cut(pacing: .relaxed)?.duration ?? 0) - 0.5) < 1e-9)
    }

    @Test func pausesAreNeverLengthened() {
        let short = AutoEditLayer.PauseItem(pause: pause(0, 1, 1.4, .section))
        #expect(short.cut(pacing: .natural) == nil)
    }

    @Test func cutsFollowGroupsAndToggles() {
        var edit = layer()
        // The low-confidence filler starts off.
        #expect(edit.cuts.count == 4)
        edit.groups.remove(.fillers)
        #expect(edit.cuts.count == 3)
        edit.groups.remove(.pauses)
        #expect(edit.cuts == [TimeRange(start: 14, end: 16)])
        edit.groups = []
        #expect(edit.cuts.isEmpty)
    }

    @Test func keepAsIsWins() {
        var edit = layer()
        edit.pauses[0].keepsLength = true
        #expect(edit.pauses[0].cut(pacing: .tight) == nil)
        #expect(edit.pauses[0].isUserEdited)
    }

    @Test func screenActionsCanBeSpedUp() {
        var edit = layer()
        #expect(edit.speedSegments.isEmpty)
        edit.actionSpeed = 4
        #expect(edit.speedSegments.map(\.range) == [TimeRange(start: 9, end: 12)])
        #expect(edit.speedSegments.first?.rate == 4)
    }

    @Test func draggingAnEdgeAdjustsTheItem() {
        var edit = layer()
        edit.setEdge(of: .pause(0), start: true, to: 2.2)
        #expect(edit.pauses[0].adjustedCut == TimeRange(start: 2.2, end: 3.5))
        let id = edit.removals[2].id
        edit.setEdge(of: .removal(id), start: false, to: 16.5)
        #expect(edit.removals[2].range == TimeRange(start: 14, end: 16.5))
        #expect(edit.removals[2].isUserEdited)
        #expect(edit.range(of: .removal(id)) == TimeRange(start: 14, end: 16.5))
    }

    @Test func reanalysisKeepsWhatTheUserChanged() {
        var previous = layer()
        previous.removals[0].isEnabled = false
        previous.removals[0].isUserEdited = true
        previous.pauses[1].keepsLength = true
        previous.pacing = .tight

        let analysis = AutoEditAnalysis(
            transcript: Transcript(language: .english, localeIdentifier: "en-US", engine: "test", words: []),
            pauses: [pause(0, 2, 4, .sentence), pause(1, 6, 6.9, .sentence), pause(2, 20, 22, .section)],
            suggestions: [removal(5, 5.4).suggestion, removal(18, 19, .repeat).suggestion]
        )
        let rerun = AutoEditLayer(analysis: analysis, envelope: nil, language: .english, judgedBy: "Rules", keeping: previous)
        #expect(rerun.pacing == .tight)
        // The user's switched-off filler replaces the new overlapping one.
        #expect(rerun.removals.count == 2)
        #expect(rerun.removals.first { $0.range.start == 5 }?.isEnabled == false)
        // The kept pause stays kept; the overlapping new judgment is dropped.
        #expect(rerun.pauses.count == 3)
        #expect(rerun.pauses.first { $0.pause.range.start == 6 }?.keepsLength == true)
        #expect(Set(rerun.pauses.map(\.id)).count == 3)
    }

    @Test func removalEdgesSnapToQuietMoments() {
        // Loud everywhere except one quiet frame 50 ms before the start.
        var levels = [Float](repeating: -20, count: 300)
        levels[95] = -70
        let envelope = LoudnessEnvelope(startTime: 0, levels: levels)
        let snapped = AutoEditLayer.snap(TimeRange(start: 1.0, end: 2.0), to: envelope)
        #expect(abs(snapped.start - 0.955) < 0.001)
    }
}

@Suite("Auto-edit in the timeline")
struct AutoEditTimelineTests {
    @Test func enabledSuggestionsAreRemoved() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 20)
        project.cuts = [TimeRange(start: 18, end: 19)]
        project.autoEdit = layer()
        let timeline = Timeline(project: project)
        #expect(timeline.isKept(source: 1))
        #expect(!timeline.isKept(source: 3))      // shortened section break
        #expect(!timeline.isKept(source: 15))     // retake
        #expect(!timeline.isKept(source: 18.5))   // the user's cut
        #expect(timeline.isKept(source: 7.1))     // the switched-off filler stays
        #expect(!project.isUnedited)
        #expect(project.effectiveCuts.count == 5)
    }

    @Test func autoEditNeverEmptiesTheTimeline() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 1)
        var everything = AutoEditLayer(language: .english)
        everything.removals = [removal(0, 1, .retake)]
        project.autoEdit = everything
        #expect(project.effectiveCuts.isEmpty)
        #expect(Timeline(project: project).outputDuration == 1)
    }

    @Test func joinsAreWhereFootageWasRemoved() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        project.cuts = [TimeRange(start: 2, end: 3)]
        project.speedSegments = [SpeedSegment(range: TimeRange(start: 5, end: 7), rate: 2)]
        // Speed changes split segments but don't make a join.
        #expect(CompositionBuilder.joinTimes(Timeline(project: project)) == [2])
    }

    @Test func fadesAroundJoins() throws {
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        let parameters = CompositionBuilder.mixParameters(for: track, volume: 0.8, joins: [2, 2.01, 5])
        var start: Float = 0
        var end: Float = 0
        var range = CMTimeRange()
        // Just before the first join the volume ramps down to silence.
        #expect(parameters.getVolumeRamp(for: CMTime(seconds: 1.996, preferredTimescale: 60_000), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 0.8 && end == 0)
        #expect(parameters.getVolumeRamp(for: CMTime(seconds: 5.004, preferredTimescale: 60_000), startVolume: &start, endVolume: &end, timeRange: &range))
        #expect(start == 0 && end == 0.8)
        // A muted track stays at zero (no fade back in).
        let muted = CompositionBuilder.mixParameters(for: track, volume: 0, joins: [2])
        _ = muted.getVolumeRamp(for: CMTime(seconds: 2.004, preferredTimescale: 60_000), startVolume: &start, endVolume: &end, timeRange: &range)
        #expect(start == 0 && end == 0)
    }

    @Test func projectsWithoutAutoEditStillDecode() throws {
        let project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
        json.removeValue(forKey: "autoEdit")
        let decoded = try JSONDecoder().decode(VideoEditProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.autoEdit == nil)

        var edited = project
        edited.autoEdit = layer()
        let roundTrip = try JSONDecoder().decode(VideoEditProject.self, from: JSONEncoder().encode(edited))
        #expect(roundTrip.autoEdit == edited.autoEdit)
    }
}
