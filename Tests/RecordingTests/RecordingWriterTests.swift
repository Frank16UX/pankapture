import AppCore
import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Recording

final class SidecarSink: Sendable {
    private let storage = Mutex<[(RecordingSidecar, URL)]>([])
    func append(_ sidecar: RecordingSidecar, _ url: URL) { storage.withLock { $0.append((sidecar, url)) } }
    var items: [(RecordingSidecar, URL)] { storage.withLock { $0 } }
}

@Suite("RecordingWriter", .serialized)
struct RecordingWriterTests {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pankapture-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 48_000) }

    /// Feeds `seconds` of 30 fps video plus system (stereo) and mic (mono) audio,
    /// starting at host time `start`, in capture order.
    private func feed(
        _ writer: RecordingWriter,
        from start: Double,
        seconds: Double,
        pauses: [(Double, Double)] = [],
        muteAt: Double? = nil
    ) async throws {
        let audioStep = 1024.0 / 48_000
        var nextVideo = start
        var nextAudio = start - 0.2 // audio before the first frame must be dropped
        let end = start + seconds
        var pendingPauses = pauses
        var muted = false

        while nextVideo < end || nextAudio < end {
            let now = min(nextVideo, nextAudio)
            if let (pauseStart, pauseEnd) = pendingPauses.first, now >= pauseStart {
                await writer.pause(at: t(pauseStart))
                await writer.resume(at: t(pauseEnd))
                pendingPauses.removeFirst()
            }
            if let muteAt, !muted, now >= muteAt {
                await writer.setMicrophoneMuted(true)
                muted = true
            }
            if nextVideo <= nextAudio {
                await writer.appendVideo(SyntheticMedia.videoFrame(at: t(nextVideo)))
                nextVideo += 1.0 / 30
                try await Task.sleep(for: .milliseconds(1))
            } else {
                await writer.appendAudio(SyntheticMedia.audio(at: t(nextAudio)), from: .system)
                await writer.appendAudio(
                    SyntheticMedia.audio(at: t(nextAudio), channels: 1, interleaved: true, value: 0.5),
                    from: .microphone
                )
                nextAudio += audioStep
            }
        }
    }

    @Test func writesContinuousFileWithPauseRemovedAndTwoNamedAudioTracks() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.mp4")

        let writer = RecordingWriter(settings: .init(
            url: url, codec: .h264, quality: .medium, framesPerSecond: 30,
            capturesSystemAudio: true, capturesMicrophone: true
        ))
        try await feed(writer, from: 1000, seconds: 5, pauses: [(1002, 1003)], muteAt: 1004)
        let summary = try await writer.finish(at: t(1005))

        #expect(abs(summary.duration - 4.0) < 0.05)
        #expect(summary.videoSize == CGSize(width: 320, height: 240))
        // 120 frames arrive outside the pause. The writer drops a frame when the
        // encoder isn't ready (real-time behavior), which a busy CI runner hits.
        #expect(summary.framesWritten + summary.framesDropped > 110)
        #expect(summary.framesWritten > 60)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 4.0) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 2)
        var names: [String] = []
        for track in audioTracks {
            let items = try await track.load(.metadata)
            let name = try await items
                .first { $0.commonKey == .commonKeyTitle }?
                .load(.stringValue)
            names.append(name ?? "?")
        }
        #expect(names == [RecordingWriter.TrackName.systemAudio, RecordingWriter.TrackName.microphone])
    }

    /// Players that play one audio track must get system + mic: the mixdown
    /// puts an enabled "Mix" track first and keeps the separate tracks, disabled.
    @Test func mixdownAddsDefaultMixedTrack() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.mp4")
        let writer = RecordingWriter(settings: .init(
            url: url, codec: .h264, quality: .low, framesPerSecond: 30,
            capturesSystemAudio: true, capturesMicrophone: true
        ))
        try await feed(writer, from: 10, seconds: 2)
        _ = try await writer.finish(at: t(12))

        #expect(try await AudioMixdown.addMixedTrack(to: url))

        let asset = AVURLAsset(url: url)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        try #require(audio.count == 3)
        var tracks: [(name: String, enabled: Bool)] = []
        for track in audio {
            let name = try await track.load(.metadata).first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
            tracks.append((name ?? "?", try await track.load(.isEnabled)))
        }
        #expect(tracks.map(\.name) == [RecordingWriter.TrackName.mix, RecordingWriter.TrackName.systemAudio, RecordingWriter.TrackName.microphone])
        #expect(tracks.map(\.enabled) == [true, false, false])
        // No leftover temporary file next to the recording.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["out.mp4"])
    }

    /// The webcam is its own disabled "Camera" track (ADR-25), and the
    /// audio mixdown keeps it.
    @Test func cameraIsRecordedAsADisabledTrack() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.mp4")
        let writer = RecordingWriter(settings: .init(
            url: url, codec: .h264, quality: .low, framesPerSecond: 30,
            capturesSystemAudio: true, capturesMicrophone: true, cameraSize: CGSize(width: 640, height: 480)
        ))
        // Camera frames are interleaved with the screen and audio feed.
        let audioStep = 1024.0 / 48_000
        var nextVideo = 20.0, nextAudio = 20.0
        while nextVideo < 22 || nextAudio < 22 {
            if nextVideo <= nextAudio {
                await writer.appendVideo(SyntheticMedia.videoFrame(at: t(nextVideo)))
                await writer.appendCamera(SyntheticMedia.videoFrame(at: t(nextVideo + 0.001)))
                nextVideo += 1.0 / 30
                try await Task.sleep(for: .milliseconds(1))
            } else {
                await writer.appendAudio(SyntheticMedia.audio(at: t(nextAudio)), from: .system)
                await writer.appendAudio(SyntheticMedia.audio(at: t(nextAudio), channels: 1, interleaved: true, value: 0.5), from: .microphone)
                nextAudio += audioStep
            }
        }
        _ = try await writer.finish(at: t(22))
        #expect(await writer.hasCameraTrack)
        #expect(try await AudioMixdown.addMixedTrack(to: url))

        let video = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        try #require(video.count == 2)
        let camera = video[1]
        let title = try await camera.load(.metadata).first { $0.commonKey == .commonKeyTitle }?.load(.stringValue)
        #expect(title == RecordingWriter.TrackName.camera)
        #expect(try await camera.load(.isEnabled) == false)
        #expect(try await video[0].load(.isEnabled))
        #expect(try await camera.load(.timeRange).duration.seconds > 1.5)
    }

    /// The camera track starts with the screen (CAM-7): the camera frame from
    /// just before the first screen frame, or else the first one after it,
    /// shows from time zero instead of an empty start.
    @Test(arguments: [true, false])
    func cameraStartsWithTheScreen(withLeadIn: Bool) async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.mp4")
        let writer = RecordingWriter(settings: .init(
            url: url, codec: .h264, quality: .low, framesPerSecond: 30,
            capturesSystemAudio: false, capturesMicrophone: false, cameraSize: CGSize(width: 320, height: 240)
        ))
        if withLeadIn { await writer.appendCamera(SyntheticMedia.videoFrame(at: t(19.95), shade: 40)) }
        var next = 20.0
        while next < 21 {
            await writer.appendVideo(SyntheticMedia.videoFrame(at: t(next)))
            // The camera's own frames arrive a moment late.
            if next >= 20.2 { await writer.appendCamera(SyntheticMedia.videoFrame(at: t(next + 0.001), shade: 200)) }
            next += 1.0 / 30
            try await Task.sleep(for: .milliseconds(1))
        }
        _ = try await writer.finish(at: t(21))

        let video = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
        try #require(video.count == 2)
        let segments = try await video[1].load(.segments)
        let first = try #require(segments.first)
        #expect(!first.isEmpty)
        #expect(abs(first.timeMapping.target.start.seconds) < 1e-3)
    }

    /// Simulates a crash: snapshot the fragmented file mid-recording (as a power
    /// loss would leave it), then recover the snapshot.
    @Test func interruptedRecordingIsRecoverable() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inProgress = directory.appendingPathComponent("InProgress", isDirectory: true)
        let destination = directory.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: inProgress, withIntermediateDirectories: true)

        let manifest = RecordingManifest(
            startDate: Date(timeIntervalSince1970: 1_792_419_225),
            configuration: RecordingConfiguration(source: .display(1)),
            destinationDirectory: destination
        )
        let liveURL = directory.appendingPathComponent("live.mp4")
        let writer = RecordingWriter(settings: .init(
            url: liveURL, codec: .h264, quality: .low, framesPerSecond: 30,
            capturesSystemAudio: true, capturesMicrophone: false
        ))
        try await feed(writer, from: 50, seconds: 7)
        try await Task.sleep(for: .milliseconds(300)) // let the last fragment flush

        try FileManager.default.copyItem(at: liveURL, to: RecordingManifest.movieURL(for: manifest.id, in: inProgress))
        try manifest.write(in: inProgress)
        await writer.cancel()

        let sidecars = SidecarSink()
        let recovery = RecordingRecovery(
            directory: inProgress,
            namer: CaptureFileNamer(timeZone: TimeZone(identifier: "UTC")!),
            fallbackDestination: { destination },
            saveSidecar: { sidecar, url in sidecars.append(sidecar, url) }
        )
        let pending = recovery.pending()
        try #require(pending.count == 1)
        #expect(pending[0].manifest == manifest)

        let recovered = try await recovery.recover(pending[0])
        #expect(recovered.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL)
        #expect(recovered.lastPathComponent == "Pankapture 2026-10-19 at 14.13.45.mp4")
        let duration = try await AVURLAsset(url: recovered).load(.duration).seconds
        #expect(duration >= 3.9) // at least the fragments flushed before the "crash"
        #expect(recovery.pending().isEmpty)
        #expect(sidecars.items.count == 1)
        #expect(sidecars.items.first?.0.videoSize == CGSize(width: 320, height: 240))
    }

    @Test func noFramesMeansNothingToSave() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = RecordingWriter(settings: .init(
            url: directory.appendingPathComponent("empty.mp4"), codec: .h264, quality: .low,
            framesPerSecond: 30, capturesSystemAudio: true, capturesMicrophone: false
        ))
        await writer.appendAudio(SyntheticMedia.audio(at: t(1)), from: .system)
        await #expect(throws: RecordingError.noFramesCaptured) {
            _ = try await writer.finish(at: t(2))
        }
    }

    @Test func silencedCopyKeepsLayoutAndZeroesSamples() throws {
        let original = SyntheticMedia.audio(at: t(3), frames: 480, channels: 2, interleaved: false, value: 0.8)
        #expect(AudioBuffers.peakLevel(of: original) > 0.79)
        let silent = try #require(AudioBuffers.silencedCopy(of: original))
        #expect(CMSampleBufferGetNumSamples(silent) == 480)
        #expect(CMSampleBufferGetPresentationTimeStamp(silent) == t(3))
        #expect(AudioBuffers.peakLevel(of: silent) == 0)
    }

    @Test func meterMapsDecibels() {
        #expect(AudioBuffers.meterValue(forPeak: 0) == 0)
        #expect(AudioBuffers.meterValue(forPeak: 1) == 1)
        #expect(abs(AudioBuffers.meterValue(forPeak: 0.1) - 0.6) < 0.001) // −20 dBFS
    }
}
