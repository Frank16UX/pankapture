import AppCore
import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoEditor

/// Rendering of backgrounds, the shadow, and full-frame zoom.
@Suite("Backgrounds and full-frame zoom")
struct BackgroundRenderingTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func pixels(_ image: CIImage, size: CGSize) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return { x, y in
            let i = (y * width + x) * 4
            return (data[i], data[i + 1], data[i + 2])
        }
    }

    private func project(_ configure: (inout VideoEditProject) -> Void) -> VideoEditProject {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        configure(&project)
        return project
    }

    private func solid(_ color: CIColor, _ size: CGSize) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// The shadow used to be clamped to its extent before blurring, which
    /// smeared dark bands out from the video's edges that the crop cut off.
    @Test func shadowFadesOutInsteadOfEndingInABand() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let plan = RenderPlan(
            project: project { $0.background = VideoBackground(fill: .solid(red), padding: 0.3, cornerRadius: 0, shadow: true) },
            sourceSize: CGSize(width: 400, height: 400)
        )
        #expect(plan.videoRect == CGRect(x: 120, y: 120, width: 160, height: 160))
        let renderer = FrameRenderer(plan: plan)
        let pixel = pixels(
            renderer.render(source: solid(CIColor(red: 0, green: 0, blue: 1), plan.renderSize), outputTime: 0, backdrop: renderer.makeBackdrop()),
            size: plan.renderSize
        )
        // Right next to the video: shadow. 25 px out (> 6σ): clean background.
        #expect(pixel(117, 190).r < 235)
        #expect(pixel(95, 190).r >= 250)
        #expect(pixel(200, 95).r >= 250)
        #expect(pixel(10, 190).r >= 250)
    }

    @Test func fullFrameZoomFillsTheCanvas() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let zoom = ZoomSegment(range: TimeRange(start: 0, end: 4), rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), easeDuration: 1)
        func render(fillsFrame: Bool) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let plan = RenderPlan(
                project: project {
                    $0.background = VideoBackground(fill: .solid(red), padding: 0.2, cornerRadius: 0, shadow: false)
                    $0.zooms = [zoom]
                    $0.zoomFillsFrame = fillsFrame
                },
                sourceSize: CGSize(width: 200, height: 100)
            )
            let image = FrameRenderer(plan: plan).render(source: solid(CIColor(red: 0, green: 0, blue: 1), plan.sourceSize), outputTime: 2)
            return pixels(image, size: plan.renderSize)
        }
        // Inside the padding: the background stays at the edges…
        #expect(render(fillsFrame: false)(2, 2) == (255, 0, 0))
        // …with full-frame zoom the video covers the whole frame.
        #expect(render(fillsFrame: true)(2, 2) == (0, 0, 255))
        #expect(render(fillsFrame: true)(197, 97) == (0, 0, 255))
    }

    @Test func canvasZoomEasesFromTheWholeCanvas() throws {
        let zoom = ZoomSegment(range: TimeRange(start: 0, end: 4), rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), easeDuration: 1)
        let canvas = CGSize(width: 200, height: 100)
        let video = CGRect(x: 20, y: 10, width: 160, height: 80)
        #expect(ZoomMath.canvasVisibleRect(at: 5, zooms: [zoom], canvas: canvas, videoRect: video) == nil)
        let full = try #require(ZoomMath.canvasVisibleRect(at: 2, zooms: [zoom], canvas: canvas, videoRect: video))
        // Bottom-right quarter of the video (bottom-left origin: low y).
        #expect(abs(full.minX - 100) < 1e-6 && abs(full.minY - 10) < 1e-6)
        #expect(abs(full.width - 80) < 1e-6 && abs(full.height - 40) < 1e-6)
        let halfway = try #require(ZoomMath.canvasVisibleRect(at: 0.5, zooms: [zoom], canvas: canvas, videoRect: video))
        #expect(halfway.width < 200 && halfway.width > 80)
        #expect(abs(halfway.width / halfway.height - 2) < 1e-6)
    }

    @Test func customGradientFollowsItsAngle() {
        let gradient = CustomGradient(start: RGBAColor(red: 1, green: 0, blue: 0), end: RGBAColor(red: 0, green: 0, blue: 1), angle: 0)
        let points = gradient.endpoints(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(points.start == CGPoint(x: 0, y: 25))
        #expect(points.end == CGPoint(x: 100, y: 25))
        // 90° runs top → bottom on screen: starts at the top (high y, bottom-left origin).
        let down = CustomGradient(start: .white, end: .black, angle: 90).endpoints(in: CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(abs(down.start.y - 50) < 1e-9 && abs(down.end.y) < 1e-9)

        let plan = RenderPlan(
            project: project { $0.background = VideoBackground(fill: .customGradient(gradient), padding: 0.3, cornerRadius: 0, shadow: false) },
            sourceSize: CGSize(width: 100, height: 50)
        )
        let pixel = pixels(FrameRenderer(plan: plan).makeBackdrop(), size: plan.renderSize)
        #expect(pixel(1, 25).r > 240 && pixel(1, 25).b < 15)
        #expect(pixel(98, 25).b > 240 && pixel(98, 25).r < 15)
    }

    @Test func imageBackgroundFillsTheCanvas() throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("green.png")
        let green = solid(CIColor(red: 0, green: 1, blue: 0), CGSize(width: 30, height: 60))
        let cgImage = try #require(context.createCGImage(green, from: green.extent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))

        let plan = RenderPlan(
            project: project { $0.background = VideoBackground(fill: .image(url), padding: 0.2, cornerRadius: 0, shadow: false) },
            sourceSize: CGSize(width: 200, height: 100)
        )
        let pixel = pixels(FrameRenderer(plan: plan).makeBackdrop(), size: plan.renderSize)
        #expect(pixel(1, 1) == (0, 255, 0))
        #expect(pixel(198, 98) == (0, 255, 0))
    }

    @Test func backgroundFilesAreRecognizedByType() {
        #expect(BackgroundLibrary.kind(of: URL(fileURLWithPath: "/a/b.PNG")) == .image)
        #expect(BackgroundLibrary.kind(of: URL(fileURLWithPath: "/a/b.heic")) == .image)
        #expect(BackgroundLibrary.kind(of: URL(fileURLWithPath: "/a/b.mov")) == .video)
        #expect(BackgroundLibrary.kind(of: URL(fileURLWithPath: "/a/b.mp4")) == .video)
        #expect(BackgroundLibrary.kind(of: URL(fileURLWithPath: "/a/b.txt")) == nil)
    }
}

@Suite("Splits and saved projects")
struct SplitAndStoreTests {
    private let url = URL(fileURLWithPath: "/tmp/movie.mp4")

    @Test func splitsDivideKeptFootageIntoSegments() {
        var project = VideoEditProject(sourceURL: url, sourceDuration: 10)
        #expect(project.segments == [TimeRange(start: 0, end: 10)])
        let first = project.addSplit(at: 4)
        let second = project.addSplit(at: 2)
        #expect(first && second)
        #expect(project.splits == [2, 4])
        #expect(project.segments == [TimeRange(start: 0, end: 2), TimeRange(start: 2, end: 4), TimeRange(start: 4, end: 10)])
        // Too close to a boundary, or outside the kept footage: ignored.
        let nearBoundary = project.addSplit(at: 4.01)
        project.setTrimEnd(8)
        let trimmedAway = project.addSplit(at: 9)
        #expect(!nearBoundary && !trimmedAway)

        // Deleting the middle segment cuts it; its split points no longer show.
        let cut = project.addCut(TimeRange(start: 2, end: 4))
        #expect(cut)
        #expect(project.segments == [TimeRange(start: 0, end: 2), TimeRange(start: 4, end: 8)])
        #expect(project.visibleSplits.isEmpty)
        #expect(abs(project.timeline.outputDuration - 6) < 1e-9)
    }

    @Test func projectsSavedBeforeNewOptionsStillOpen() throws {
        var legacy = VideoEditProject(sourceURL: url, sourceDuration: 5)
        legacy.addCut(TimeRange(start: 1, end: 2))
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "zoomFillsFrame")
        json.removeValue(forKey: "splits")
        let decoded = try JSONDecoder().decode(VideoEditProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == legacy)
        #expect(!decoded.zoomFillsFrame)
        #expect(decoded.splits.isEmpty)
    }

    @Test func newFillsRoundTrip() throws {
        for fill: VideoBackground.Fill in [
            .customGradient(CustomGradient(start: .white, end: .black, angle: 120)),
            .image(URL(fileURLWithPath: "/tmp/bg.png")),
            .video(URL(fileURLWithPath: "/tmp/bg.mov")),
        ] {
            var project = VideoEditProject(sourceURL: url, sourceDuration: 5, zoomFillsFrame: true, splits: [1.5])
            project.background.fill = fill
            let decoded = try JSONDecoder().decode(VideoEditProject.self, from: JSONEncoder().encode(project))
            #expect(decoded == project)
        }
    }

    @Test func draftsAreKeptApartFromTheSavedProject() throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ProjectStore(directory: directory)
        var saved = VideoEditProject(sourceURL: url, sourceDuration: 5)
        saved.addCut(TimeRange(start: 1, end: 2))
        try store.save(saved)
        var draft = saved
        draft.addSplit(at: 3)
        try store.saveDraft(draft)

        #expect(store.load(for: url) == saved)
        #expect(store.loadDraft(for: url) == draft)
        store.deleteDraft(for: url)
        #expect(store.loadDraft(for: url) == nil)
        #expect(store.load(for: url) == saved)
    }
}

@Suite("Background video")
struct BackgroundVideoTests {
    /// A short green movie loops behind a longer blue one, in the export.
    @Test func loopsBehindTheRecordingInExports() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = try await TestMovie.make(TestMovie.Spec(duration: 2, color: (255, 0, 0)), in: directory)
        let backgroundURL = try await TestMovie.make(TestMovie.Spec(duration: 0.5, color: (0, 255, 0), audioAmplitudes: []), in: directory)
        let source = try await SourceMedia.load(url: main)
        var project = VideoEditProject(sourceURL: main, sourceDuration: source.duration)
        project.background = VideoBackground(fill: .video(backgroundURL), padding: 0.2, cornerRadius: 0, shadow: false)

        let edit = try await CompositionBuilder.build(source: source, project: project, options: .init(frameRate: 10))
        let videoTracks = edit.composition.tracks(withMediaType: .video)
        #expect(videoTracks.count == 2)
        let backgroundTrack = try #require(videoTracks.first { $0.trackID == edit.backgroundTrackID })
        #expect(abs(backgroundTrack.timeRange.duration.seconds - edit.duration) < 0.05)

        let output = directory.appendingPathComponent("out.gif")
        _ = try await GIFExporter.export(source: source, project: project, options: GIFOptions(width: 80, fps: 10), to: output)
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        // A frame after the background movie's first loop ended.
        let frame = try #require(CGImageSourceCreateImageAtIndex(imageSource, 12, nil))
        let pixel = rgb(of: frame)
        #expect(pixel(1, 1).g > 200 && pixel(1, 1).r < 60)
        #expect(pixel(40, 23).b > 200 && pixel(40, 23).g < 60)
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

@Suite("Camera layer")
struct CameraLayerTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func pixels(_ image: CIImage, size: CGSize) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return { x, y in
            let i = (y * width + x) * 4
            return (data[i], data[i + 1], data[i + 2])
        }
    }

    private func solid(_ color: CIColor, _ size: CGSize) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    @Test func layerFollowsTheRecordedBubble() {
        let sidecar = RecordingSidecar.Camera(center: CGPoint(x: 0.2, y: 0.75), size: 0.3, isCircle: false, isMirrored: false)
        let camera = CameraOverlay(sidecar)
        #expect(camera.shape == .roundedRectangle)
        // Newer sidecars name the shape, including the square.
        let square = RecordingSidecar.Camera(center: .zero, size: 0.3, isCircle: false, shape: "square", isMirrored: true)
        #expect(CameraOverlay(square).shape == .square)
        let frame = camera.frame(video: CGRect(x: 0, y: 0, width: 200, height: 100), canvas: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(abs(frame.width - 30) < 1e-9 && abs(frame.height - 22.5) < 1e-9)
        #expect(abs(frame.midX - 40) < 1e-9 && abs(frame.midY - 75) < 1e-9)
        // Dragged past the edge: kept inside the canvas.
        var moved = camera
        moved.center = CGPoint(x: 1.5, y: -1)
        let clamped = moved.frame(video: CGRect(x: 0, y: 0, width: 200, height: 100), canvas: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(abs(clamped.maxX - 200) < 1e-9 && abs(clamped.minY) < 1e-9)
    }

    /// The webcam stays on top while the video zooms; a full-frame zoom moves it.
    @Test func zoomLeavesTheCameraInPlaceUnlessItFillsTheFrame() {
        let zoom = ZoomSegment(range: TimeRange(start: 0, end: 4), rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), easeDuration: 1)
        func render(fillsFrame: Bool) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
            project.zooms = [zoom]
            project.zoomFillsFrame = fillsFrame
            project.camera = CameraOverlay(center: CGPoint(x: 0.15, y: 0.7), size: 0.4, shape: .roundedRectangle, isMirrored: false)
            let plan = RenderPlan(project: project, sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true)
            let image = FrameRenderer(plan: plan).render(
                source: solid(CIColor(red: 0, green: 0, blue: 1), plan.sourceSize),
                outputTime: 2,
                camera: solid(CIColor(red: 0, green: 1, blue: 0), CGSize(width: 64, height: 48))
            )
            return pixels(image, size: plan.renderSize)
        }
        // Layer center: x = 30, y = 70 (this bitmap's rows count from the top).
        #expect(render(fillsFrame: false)(30, 70) == (0, 255, 0))
        #expect(render(fillsFrame: true)(30, 70) == (0, 0, 255))
    }

    @Test func hiddenCameraIsNotDrawn() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        project.camera = CameraOverlay(isVisible: false, center: CGPoint(x: 0.5, y: 0.5), size: 0.5)
        let plan = RenderPlan(project: project, sourceSize: CGSize(width: 100, height: 100), hasCameraTrack: true)
        #expect(plan.camera == nil)
        #expect(!plan.needsCustomCompositor)
        project.camera?.isVisible = true
        #expect(RenderPlan(project: project, sourceSize: CGSize(width: 100, height: 100), hasCameraTrack: true).needsCustomCompositor)
        #expect(RenderPlan(project: project, sourceSize: CGSize(width: 100, height: 100), hasCameraTrack: false).camera == nil)
    }

    @Test func squareAndRectangleTakeTheChosenRoundness() throws {
        var camera = CameraOverlay(center: CGPoint(x: 0.5, y: 0.5), size: 0.3, shape: .square, roundness: 0.25)
        #expect(camera.shape.aspect == 1)
        #expect(camera.cornerRadius(for: CGSize(width: 200, height: 200)) == 50)
        camera.shape = .roundedRectangle
        #expect(camera.cornerRadius(for: CGSize(width: 200, height: 150)) == 37.5)
        camera.roundness = 0
        #expect(camera.cornerRadius(for: CGSize(width: 200, height: 150)) == 0)
        camera.shape = .circle // always round, whatever the roundness
        #expect(camera.cornerRadius(for: CGSize(width: 120, height: 120)) == 60)

        // Projects saved before roundness existed get the default.
        let old = #"{"isVisible":true,"center":[0.2,0.8],"size":0.25,"shape":"roundedRectangle","isMirrored":true}"#
        let decoded = try JSONDecoder().decode(CameraOverlay.self, from: Data(old.utf8))
        #expect(decoded.roundness == CameraOverlay.defaultRoundness)
        #expect(decoded.shape == .roundedRectangle)
    }

    @Test func cameraTrackIsFoundAndExportedAsALayer() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await TestMovie.make(TestMovie.Spec(duration: 1, color: (255, 0, 0), cameraColor: (0, 255, 0)), in: directory)
        let source = try await SourceMedia.load(url: url)
        let camera = try #require(source.camera)
        #expect(camera.size == CGSize(width: 64, height: 48))
        #expect(source.size == CGSize(width: 160, height: 90))

        let project = VideoEditProject.initial(for: source)
        #expect(project.camera == .standard)
        let edit = try await CompositionBuilder.build(source: source, project: project, options: .init(frameRate: 10))
        #expect(edit.cameraTrackID != nil)
        #expect(edit.plan.camera != nil)

        let output = directory.appendingPathComponent("camera.gif")
        _ = try await GIFExporter.export(source: source, project: project, options: GIFOptions(width: 160, fps: 10), to: output)
        let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let frame = try #require(CGImageSourceCreateImageAtIndex(imageSource, 3, nil))
        let rect = try #require(edit.plan.cameraRect) // bottom-left origin
        let pixel = rgb(of: frame)
        let center = pixel(Int(rect.midX), frame.height - Int(rect.midY))
        #expect(center.g > 200 && center.b < 60)
        #expect(pixel(150, 10).b > 200)
    }

    /// The size setting for the camera copy only ever shrinks it.
    @Test func cameraCopyIsNeverUpscaled() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await TestMovie.make(TestMovie.Spec(duration: 0.5, cameraColor: (0, 255, 0)), in: directory)
        let result = try await CameraComposite.export(
            recordingAt: url, to: directory.appendingPathComponent("copy.mp4"), resolution: .uhd4K
        )
        #expect(result.pixelSize == CGSize(width: 160, height: 90))
    }

    /// Showing the camera switches the preview to the Core Image compositor;
    /// the screen around it must look exactly as with the camera hidden (the
    /// plain built-in compositor). It came out brighter when rendered to sRGB.
    @Test func compositorKeepsTheRecordingsColors() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await TestMovie.make(
            TestMovie.Spec(duration: 1, color: (50, 50, 50), cameraColor: (0, 255, 0), tagsRec709: true), in: directory
        )
        let source = try await SourceMedia.load(url: url)

        func frame(cameraVisible: Bool) async throws -> CGImage {
            var project = VideoEditProject.initial(for: source)
            project.camera?.isVisible = cameraVisible
            let edit = try await CompositionBuilder.build(source: source, project: project, options: .preview(frameRate: 30))
            #expect((edit.videoComposition?.customVideoCompositorClass != nil) == cameraVisible)
            let generator = AVAssetImageGenerator(asset: edit.composition)
            generator.videoComposition = edit.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(value: 1, timescale: 2)).image
        }
        let plain = rgb(of: try await frame(cameraVisible: false))(150, 10)
        let composited = rgb(of: try await frame(cameraVisible: true))(150, 10)
        for (a, b) in [(plain.r, composited.r), (plain.g, composited.g), (plain.b, composited.b)] {
            #expect(abs(Int(a) - Int(b)) <= 2, "built-in \(plain) vs compositor \(composited)")
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

@Suite("Export sizes and silent tracks")
struct ExportSizeTests {
    @Test func presetsSetTheShorterSideEvenWhenUpscaling() {
        #expect(CanvasLayout.scaled(CGSize(width: 1662, height: 1080), shortSide: 2160) == CGSize(width: 3324, height: 2160))
        #expect(CanvasLayout.scaled(CGSize(width: 1662, height: 1080), shortSide: 1440) == CGSize(width: 2216, height: 1440))
        #expect(CanvasLayout.scaled(CGSize(width: 2880, height: 1800), shortSide: 1080) == CGSize(width: 1728, height: 1080))
        #expect(ExportResolution.allCases.map(\.title) == ["Original", "4K", "1440p", "1080p", "720p"])
        let project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 1)
        let plan = RenderPlan(project: project, sourceSize: CGSize(width: 1920, height: 1080), shortSide: ExportResolution.uhd4K.shortSide)
        #expect(plan.renderSize == CGSize(width: 3840, height: 2160))
    }

    @Test func silentTracksAreDetected() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try await TestMovie.make(TestMovie.Spec(duration: 1, audioAmplitudes: [0.5, 0]), in: directory)
        let source = try await SourceMedia.load(url: url)
        let loud = try await WaveformExtractor.waveform(asset: source.asset, trackID: source.audioTracks[0].trackID)
        let silent = try await WaveformExtractor.waveform(asset: source.asset, trackID: source.audioTracks[1].trackID)
        #expect(!loud.isSilent)
        #expect(silent.isSilent)
    }
}
