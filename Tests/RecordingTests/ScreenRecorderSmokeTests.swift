import AppCore
import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Recording

/// End-to-end recordings through ScreenCaptureKit. Skipped by default: they
/// need Screen Recording permission for the process running the tests (e.g.
/// the terminal) and record the real screen. Run with:
///
///     PANKAPTURE_SMOKE=1 swift test --filter ScreenRecorderSmoke
@Suite(
    "ScreenRecorder smoke",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["PANKAPTURE_SMOKE"] == "1")
)
@MainActor
struct ScreenRecorderSmokeTests {
    private func makeRecorder() throws -> (ScreenRecorder, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pk-smoke-\(UUID().uuidString)")
        let saved = root.appendingPathComponent("Saved", isDirectory: true)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "pankapture.smoke.\(UUID().uuidString)")!
        defaults.set(saved.path, forKey: PreferenceKey.saveDirectory)
        let recorder = ScreenRecorder(
            inProgressDirectory: root.appendingPathComponent("InProgress", isDirectory: true),
            defaults: defaults
        )
        return (recorder, root)
    }

    private func cleanUp(_ result: RecordingResult?, root: URL) {
        try? FileManager.default.removeItem(at: root)
        if let result { try? FileManager.default.removeItem(at: RecordingSidecar.location(for: result.url)) }
    }

    @Test func recordsMainDisplayWithPause() async throws {
        let (recorder, root) = try makeRecorder()
        var result: RecordingResult?
        defer { cleanUp(result, root: root) }

        try await recorder.start(RecordingConfiguration(
            source: .display(CGMainDisplayID()), framesPerSecond: 30, countdown: 0
        ))
        #expect(recorder.state == .recording)
        try await Task.sleep(for: .seconds(2))
        recorder.pause()
        try await Task.sleep(for: .seconds(1))
        recorder.resume()
        try await Task.sleep(for: .seconds(1.5))
        result = try await recorder.stop()
        let saved = try #require(result)

        #expect(recorder.state == .idle)
        #expect(abs(saved.duration - 3.5) < 0.4)
        #expect(saved.fileSize > 0)
        let bounds = CGDisplayBounds(CGMainDisplayID())
        #expect(saved.videoSize.width >= bounds.width)
        let asset = AVURLAsset(url: saved.url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1) // system audio
        #expect(abs(try await asset.load(.duration).seconds - saved.duration) < 0.2)
        #expect(RecordingSidecar.load(for: saved.url)?.videoSize == saved.videoSize)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("InProgress").path).isEmpty)
    }

    @Test func recordsAreaAtEvenPixelSize() async throws {
        let (recorder, root) = try makeRecorder()
        var result: RecordingResult?
        defer { cleanUp(result, root: root) }

        try await recorder.start(RecordingConfiguration(
            source: .area(displayID: CGMainDisplayID(), rect: CGRect(x: 100, y: 100, width: 301, height: 151)),
            framesPerSecond: 60, codec: .hevc, capturesSystemAudio: false, countdown: 0
        ))
        try await Task.sleep(for: .seconds(1.5))
        result = try await recorder.stop()
        let saved = try #require(result)
        #expect(Int(saved.videoSize.width) % 2 == 0 && Int(saved.videoSize.height) % 2 == 0)
        #expect(saved.videoSize.width >= 300 && saved.videoSize.width <= 604)
    }

    @Test func hidingDesktopIconsRecords() async throws {
        let (recorder, root) = try makeRecorder()
        var result: RecordingResult?
        defer { cleanUp(result, root: root) }
        try await recorder.start(RecordingConfiguration(
            source: .display(CGMainDisplayID()), capturesSystemAudio: false, hidesDesktopIcons: true, countdown: 0
        ))
        try await Task.sleep(for: .seconds(2.5)) // spans one filter refresh
        result = try await recorder.stop()
        #expect((result?.duration ?? 0) > 2)
    }

    @Test func cancelLeavesNothingBehind() async throws {
        let (recorder, root) = try makeRecorder()
        defer { cleanUp(nil, root: root) }
        try await recorder.start(RecordingConfiguration(source: .display(CGMainDisplayID()), countdown: 0))
        try await Task.sleep(for: .seconds(1))
        recorder.cancel()
        try await Task.sleep(for: .seconds(0.5))
        #expect(recorder.state == .idle)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("InProgress").path)
        #expect(leftovers.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Saved").path).isEmpty)
    }
}
