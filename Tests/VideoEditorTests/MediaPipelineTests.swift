import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import VideoEditor

/// End-to-end tests on tiny synthetic movies (160×90, 2 s).
@Suite("Media pipeline")
struct MediaPipelineTests {
    @Test func loadsSourceProperties() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(TestMovie.Spec(audioAmplitudes: [0.5, 0]), in: directory)

        let source = try await SourceMedia.load(url: url)
        #expect(abs(source.duration - 2) < 0.1)
        #expect(source.size == CGSize(width: 160, height: 90))
        #expect(abs(source.frameRate - 30) < 1)
        #expect(source.audioTracks.map(\.role) == [.system, .microphone])
        #expect(source.audioTracks.map(\.label) == ["Audio 1", "Audio 2"])
    }

    @Test func compositionDropsCutsAndAppliesSpeed() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(in: directory)
        let source = try await SourceMedia.load(url: url)

        var project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        let added = project.addCut(TimeRange(start: 0.5, end: 1.0))
        #expect(added)
        let cut = try await CompositionBuilder.build(source: source, project: project, options: .init())
        #expect(abs(cut.duration - 1.5) < 0.05)
        #expect(cut.videoComposition != nil)
        #expect(cut.composition.tracks(withMediaType: .audio).count == 1)
        #expect(cut.audioMix != nil)

        project.setSpeed(2, for: TimeRange(start: 1.0, end: 2.0))
        let fast = try await CompositionBuilder.build(source: source, project: project, options: .init())
        #expect(abs(fast.duration - 1.0) < 0.05)
    }

    @Test func mutedTracksAreLeftOutOfExports() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(in: directory)
        let source = try await SourceMedia.load(url: url)
        var project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        project.trackVolumes.system.isMuted = true

        let export = try await CompositionBuilder.build(source: source, project: project, options: .init())
        #expect(export.composition.tracks(withMediaType: .audio).isEmpty)
        #expect(!export.hasAudibleAudio)
        let preview = try await CompositionBuilder.build(source: source, project: project, options: .preview(frameRate: 30))
        #expect(preview.composition.tracks(withMediaType: .audio).count == 1)
        #expect(preview.videoComposition == nil) // nothing changes the picture
    }

    @Test func exportsMP4WithEdits() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(in: directory)
        let source = try await SourceMedia.load(url: url)
        var project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        project.addCut(TimeRange(start: 0.5, end: 1.0))
        project.addZoom(at: 0, duration: 1.5)
        project.background.fill = .gradient(.ocean)

        let output = directory.appendingPathComponent("out.mp4")
        let progress = ProgressRecorder()
        let result = try await VideoExporter.exportMP4(
            source: source,
            project: project,
            settings: ExportSettings(resolution: .original, quality: .low, frameRate: .fps30),
            to: output,
            progress: { progress.record($0) }
        )
        #expect(result.format == .mp4)
        #expect(result.byteCount > 0)
        #expect(result.pixelSize == CGSize(width: 160, height: 90))
        #expect(progress.last == 1)

        let exported = AVURLAsset(url: output)
        #expect(abs(try await exported.load(.duration).seconds - 1.5) < 0.1)
        #expect(try await exported.loadTracks(withMediaType: .video).count == 1)
        #expect(try await exported.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func exportsGIFHonoringTheComposition() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Blue movie on a red background.
        let url = try TestMovie.make(TestMovie.Spec(color: (255, 0, 0)), in: directory)
        let source = try await SourceMedia.load(url: url)
        var project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        project.addCut(TimeRange(start: 0.5, end: 1.0))
        project.background = VideoBackground(fill: .solid(RGBAColor(red: 1, green: 0, blue: 0)), padding: 0.2, cornerRadius: 0, shadow: false)

        let output = directory.appendingPathComponent("out.gif")
        let result = try await GIFExporter.export(source: source, project: project, options: GIFOptions(width: 80, fps: 10), to: output)
        #expect(result.format == .gif)

        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let count = CGImageSourceGetCount(imageSource)
        #expect((14...16).contains(count))
        let frame = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(frame.width == 80)
        #expect(frame.height == 46)

        let properties = CGImageSourceCopyProperties(imageSource, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 0)
        #expect(abs(totalDelay(imageSource) - 1.5) < 0.06)

        let pixel = rgb(of: frame)
        let corner = pixel(1, 1)
        let center = pixel(40, 23)
        #expect(corner.r > 200 && corner.b < 60)
        #expect(center.b > 200 && center.r < 60)
    }

    @Test func convertsAWholeMovieToGIF() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(TestMovie.Spec(duration: 1), in: directory)
        let output = directory.appendingPathComponent("direct.gif")
        let result = try await GIFExporter.convert(videoAt: url, to: output, options: GIFOptions(width: nil, fps: 10))
        #expect(result.pixelSize == CGSize(width: 160, height: 90))
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect((9...11).contains(CGImageSourceGetCount(imageSource)))
    }

    @Test func cancellingAnExportStopsItAndRemovesTheFile() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(in: directory)
        let source = try await SourceMedia.load(url: url)
        let project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        let output = directory.appendingPathComponent("cancelled.mp4")

        let task = Task {
            try await VideoExporter.exportMP4(source: source, project: project, settings: ExportSettings(), to: output)
        }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func waveformsReflectTrackLoudness() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(TestMovie.Spec(audioAmplitudes: [0.5, 0]), in: directory)
        let source = try await SourceMedia.load(url: url)

        let loud = try await WaveformExtractor.waveform(asset: source.asset, trackID: source.audioTracks[0].trackID)
        let silent = try await WaveformExtractor.waveform(asset: source.asset, trackID: source.audioTracks[1].trackID)
        #expect((90...110).contains(loud.peaks.count))
        #expect(loud.peaks.max() == 1)
        #expect(loud.peak(in: TimeRange(start: 0.5, end: 1.5)) > 0.8)
        #expect((silent.peaks.max() ?? 0) < 0.01)
    }

    @Test func filmstripFramesAreGenerated() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try TestMovie.make(in: directory)
        let source = try await SourceMedia.load(url: url)
        let frames = await FilmstripGenerator.frames(asset: source.asset, duration: source.duration, count: 4, maximumSize: CGSize(width: 64, height: 64))
        #expect(frames.count == 4)
        #expect(frames.map(\.time) == frames.map(\.time).sorted())
    }

    /// A movie stored landscape with a 90° display rotation (like phone
    /// footage) must come out upright through both the built-in compositor
    /// (no effects) and the custom one (background).
    @Test(arguments: [false, true])
    func rotatedSourcesComeOutUpright(withBackground: Bool) async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stored frame: left half red, right half blue. Rotated 90° clockwise
        // for display, the left half ends up on top.
        let url = try TestMovie.make(
            TestMovie.Spec(duration: 1, color: (0, 0, 255), rightColor: (255, 0, 0), transform: CGAffineTransform(rotationAngle: .pi / 2)),
            in: directory
        )
        let source = try await SourceMedia.load(url: url)
        #expect(source.size == CGSize(width: 90, height: 160))
        #expect(source.orientation == .right)

        var project = VideoEditProject(sourceURL: url, sourceDuration: source.duration)
        if withBackground {
            project.background = VideoBackground(fill: .solid(RGBAColor(red: 0, green: 1, blue: 0)), padding: 0.05, cornerRadius: 0, shadow: false)
        }
        let output = directory.appendingPathComponent("rotated.gif")
        _ = try await GIFExporter.export(source: source, project: project, options: GIFOptions(width: nil, fps: 5), to: output)

        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(frame.width == 90 && frame.height == 160)
        let pixel = rgb(of: frame)
        let top = pixel(45, 40), bottom = pixel(45, 120)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
    }

    @Test func streamingWriterKeepsTimingAndColors() throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stream.gif")
        let writer = try StreamingGIFWriter(url: url, width: 40, height: 20, loopCount: 3)
        let colors: [CGColor] = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)]
        for index in 0..<15 {
            let context = try #require(CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ))
            context.setFillColor(colors[index % 2])
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            try writer.append(try #require(context.makeImage()), duration: 1.0 / 15)
        }
        try writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 15)
        #expect(abs(totalDelay(source) - 1.0) < 0.011) // 7,6,7,… centiseconds, no drift
        let gif = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        #expect(gif?[kCGImagePropertyGIFLoopCount] as? Int == 3)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(rgb(of: first)(20, 10).r > 240)
        #expect(rgb(of: second)(20, 10).b > 240)
    }

    private func totalDelay(_ source: CGImageSource) -> Double {
        (0..<CGImageSourceGetCount(source)).reduce(0) { total, index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return total + ((gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]) as? Double ?? 0)
        }
    }

    private func rgb(of image: CGImage) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return { x, y in
            let i = (y * width + x) * 4
            return (data[i], data[i + 1], data[i + 2])
        }
    }
}

/// Collects progress callbacks from any queue.
private final class ProgressRecorder: Sendable {
    private let values = Mutex<[Double]>([])
    func record(_ value: Double) { values.withLock { $0.append(value) } }
    var last: Double? { values.withLock { $0.last } }
}
