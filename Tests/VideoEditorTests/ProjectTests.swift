import AppCore
import CoreGraphics
import Foundation
import Testing
@testable import VideoEditor

private func range(_ start: Double, _ end: Double) -> TimeRange {
    TimeRange(start: start, end: end)
}

@Suite("VideoEditProject")
struct VideoEditProjectTests {
    private func project(duration: Double = 10) -> VideoEditProject {
        VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/Recording.mp4"), sourceDuration: duration)
    }

    @Test func newProjectIsUnedited() {
        let project = project()
        #expect(project.isUnedited)
        #expect(project.trim == range(0, 10))
        #expect(project.timeline.outputDuration == 10)
    }

    @Test func trimHandlesKeepAMinimumLength() {
        var project = project()
        project.setTrimStart(9.99)
        #expect(project.trim.start == 10 - VideoEditProject.minimumKeptDuration)
        project.setTrimEnd(0)
        #expect(abs(project.trim.end - (project.trim.start + VideoEditProject.minimumKeptDuration)) < 1e-9)
        project.setTrimStart(-5)
        #expect(project.trim.start == 0)
        project.setTrimEnd(50)
        #expect(project.trim.end == 10)
    }

    @Test func trimCannotBeDraggedEntirelyIntoACut() {
        var project = project()
        project.addCut(range(0, 5))
        project.setTrimEnd(3)
        #expect(project.trim.end == 10)
        #expect(project.timeline.outputDuration == 5)
        project.setTrimEnd(7)
        #expect(project.trim.end == 7)
    }

    @Test func volumeOnlyEditsCountAsEdits() {
        var project = project()
        project.trackVolumes.microphone.isMuted = true
        #expect(!project.isUnedited)
    }

    @Test func adaptingToAShorterSourceClampsEverything() {
        var project = project(duration: 10)
        project.setTrimEnd(9.5)
        project.addCut(range(8, 9))
        project.addZoom(at: 7, duration: 3)
        project.setSpeed(2, for: range(9.2, 10))
        project.adapt(toSourceDuration: 8.5)
        #expect(project.sourceDuration == 8.5)
        #expect(project.trim == range(0, 8.5))
        #expect(project.cuts == [range(8, 8.5)])
        #expect(project.zooms.first?.range == range(7, 8.5))
        #expect(project.speedSegments.isEmpty)
    }

    @Test func addingCutsMergesOverlaps() {
        var project = project()
        let results = [project.addCut(range(2, 4)), project.addCut(range(3, 5)), project.addCut(range(7, 8))]
        #expect(results == [true, true, true])
        #expect(project.cuts == [range(2, 5), range(7, 8)])
        project.removeCut(range(7, 8))
        #expect(project.cuts == [range(2, 5)])
        #expect(!project.isUnedited)
    }

    @Test func cutThatWouldRemoveEverythingIsRefused() {
        var project = project()
        project.setTrimStart(2)
        project.setTrimEnd(4)
        let everything = project.addCut(range(1, 5))
        #expect(!everything)
        #expect(project.cuts.isEmpty)
        let outside = project.addCut(range(20, 30))
        #expect(!outside)
    }

    @Test func settingSpeedReplacesOverlaps() {
        var project = project()
        project.setSpeed(2, for: range(2, 6))
        project.setSpeed(4, for: range(4, 8))
        #expect(project.speedSegments.map(\.range) == [range(2, 4), range(4, 8)])
        #expect(project.speedSegments.map(\.rate) == [2, 4])
        project.setSpeed(1, for: range(3, 5))
        #expect(project.speedSegments.map(\.range) == [range(2, 3), range(5, 8)])
    }

    @Test func zoomsStaySortedAndClamped() throws {
        var project = project()
        let late = project.addZoom(at: 6)
        let early = project.addZoom(at: 1)
        #expect(project.zooms.map(\.id) == [early.id, late.id])
        var moved = late
        moved.range = range(8, 40)
        moved.rect = CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        project.updateZoom(moved)
        let updated = try #require(project.zooms.first { $0.id == late.id })
        #expect(updated.range.end == 10)
        #expect(updated.rect == CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        project.removeZoom(id: early.id)
        #expect(project.zooms.count == 1)
    }

    @Test func roundTripsThroughJSON() throws {
        var project = project(duration: 42.5)
        project.setTrimStart(1.25)
        project.addCut(range(10, 12))
        project.addZoom(at: 5, center: CGPoint(x: 0.3, y: 0.7))
        project.setSpeed(2, for: range(20, 30))
        project.background = VideoBackground(fill: .gradient(.ocean), padding: 0.1, cornerRadius: 0.05, shadow: false, aspect: .square)
        project.trackVolumes.microphone = TrackVolume(volume: 0.4, isMuted: true)

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(VideoEditProject.self, from: data)
        #expect(decoded == project)

        var solid = project
        solid.background.fill = .solid(RGBAColor(hex: 0x123456))
        #expect(try JSONDecoder().decode(VideoEditProject.self, from: JSONEncoder().encode(solid)) == solid)
    }

    @Test func storeSavesAndRestoresByFileName() throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory.appendingPathComponent("Edits"))
        var project = project(duration: 12)
        project.addCut(range(1, 2))
        try store.save(project)

        #expect(store.location(for: project.sourceURL).lastPathComponent == "Recording.mp4.json")
        #expect(store.load(for: project.sourceURL, sourceDuration: 12) == project)
        // A different file with the same name (different duration) doesn't inherit edits.
        #expect(store.load(for: project.sourceURL, sourceDuration: 30) == nil)
        store.delete(for: project.sourceURL)
        #expect(store.load(for: project.sourceURL) == nil)
    }

    @Test func undoStackRestoresSnapshots() {
        var history = UndoHistory<Int>(limit: 2)
        var value = 0
        history.record(value); value = 1
        history.record(value); value = 2
        history.record(value); value = 3
        #expect(history.canUndo)
        value = history.undo(current: value) ?? value
        #expect(value == 2)
        value = history.undo(current: value) ?? value
        #expect(value == 1)
        #expect(history.undo(current: value) == nil) // limit reached
        value = history.redo(current: value) ?? value
        #expect(value == 2)
        history.record(value) // a new edit clears redo
        #expect(!history.canRedo)
    }
}

@Suite("Waveform")
struct WaveformTests {
    @Test func peaksAreOffsetByTheTrackStart() {
        let waveform = Waveform(startTime: 1, bucketDuration: 0.5, peaks: [0.2, 1, 0.4])
        #expect(waveform.peak(in: TimeRange(start: 0, end: 0.9)) == 0)
        #expect(waveform.peak(in: TimeRange(start: 1.5, end: 1.9)) == 1)
        #expect(waveform.peak(in: TimeRange(start: 2, end: 9)) == 0.4)
    }
}

@Suite("Audio track roles")
struct AudioRoleTests {
    @Test func namedTracksWin() {
        let roles = RecordingTracks.resolveRoles(names: ["Microphone", "System Audio"])
        #expect(roles.map(\.role) == [.microphone, .system])
        #expect(roles.map(\.label) == ["Microphone", "System Audio"])
    }

    @Test func unnamedTracksFollowOrderWithNeutralLabels() {
        let roles = RecordingTracks.resolveRoles(names: [nil, nil])
        #expect(roles.map(\.role) == [.system, .microphone])
        #expect(roles.map(\.label) == ["Audio 1", "Audio 2"])
        let single = RecordingTracks.resolveRoles(names: [nil])
        #expect(single.map(\.role) == [.system])
        #expect(single.map(\.label) == ["Audio"])
    }

    @Test func singleNamedMicTrack() {
        #expect(RecordingTracks.resolveRoles(names: ["mic"]).map(\.role) == [.microphone])
        let mixed = RecordingTracks.resolveRoles(names: [nil, "Mic"])
        #expect(mixed.map(\.role) == [.system, .microphone])
    }
}
