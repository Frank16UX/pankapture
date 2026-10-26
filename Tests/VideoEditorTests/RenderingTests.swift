import AppCore
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import VideoEditor

@Suite("Canvas layout")
struct CanvasLayoutTests {
    @Test func canvasContainsTheSourceAtEachAspect() {
        let source = CGSize(width: 1920, height: 1080)
        #expect(CanvasLayout.canvasSize(source: source, aspect: .original) == source)
        #expect(CanvasLayout.canvasSize(source: source, aspect: .widescreen) == source)
        #expect(CanvasLayout.canvasSize(source: source, aspect: .square) == CGSize(width: 1920, height: 1920))
        #expect(CanvasLayout.canvasSize(source: source, aspect: .standard) == CGSize(width: 1920, height: 1440))
        #expect(CanvasLayout.canvasSize(source: source, aspect: .portrait) == CGSize(width: 1920, height: 3414))
        #expect(CanvasLayout.canvasSize(source: CGSize(width: 1440, height: 900), aspect: .widescreen) == CGSize(width: 1600, height: 900))
    }

    @Test func exportScalingCapsTheShorterSideAndNeverUpscales() {
        #expect(CanvasLayout.scaled(CGSize(width: 2880, height: 1800), shortSideCap: 1080) == CGSize(width: 1728, height: 1080))
        #expect(CanvasLayout.scaled(CGSize(width: 1920, height: 3414), shortSideCap: 1080) == CGSize(width: 1080, height: 1920))
        #expect(CanvasLayout.scaled(CGSize(width: 1280, height: 720), shortSideCap: 1080) == CGSize(width: 1280, height: 720))
        #expect(CanvasLayout.scaled(CGSize(width: 1280, height: 720), shortSideCap: nil) == CGSize(width: 1280, height: 720))
        #expect(CanvasLayout.scaled(CGSize(width: 1280, height: 720), width: 640) == CGSize(width: 640, height: 360))
        #expect(CanvasLayout.scaled(CGSize(width: 320, height: 180), width: 640) == CGSize(width: 320, height: 180))
    }

    @Test func dimensionsAreEven() {
        let size = CanvasLayout.scaled(CGSize(width: 1001, height: 563), shortSideCap: 333)
        #expect(Int(size.width) % 2 == 0)
        #expect(Int(size.height) % 2 == 0)
    }

    @Test func videoIsCenteredInsideThePadding() {
        let rect = CanvasLayout.videoRect(canvas: CGSize(width: 1000, height: 500), source: CGSize(width: 1600, height: 900), padding: 0.1)
        #expect(abs(rect.height - 400) < 1e-9)
        #expect(abs(rect.width - 1600 * 400 / 900) < 1e-9)
        #expect(abs(rect.midX - 500) < 1e-9)
        #expect(abs(rect.midY - 250) < 1e-9)
        #expect(CanvasLayout.videoRect(canvas: CGSize(width: 1600, height: 900), source: CGSize(width: 1600, height: 900), padding: 0)
            == CGRect(x: 0, y: 0, width: 1600, height: 900))
    }
}

@Suite("Export estimates")
struct ExportEstimatorTests {
    @Test func mp4SizeFollowsBitrateAndDuration() {
        let bytes = ExportEstimator.mp4Bytes(renderSize: CGSize(width: 1920, height: 1080), fps: 30, duration: 60, quality: .high, hasAudio: true)
        let expected = (0.12 * 1920 * 1080 * 30 + 128_000) * 60 / 8 * 1.01
        #expect(abs(Double(bytes) - expected) < 1)
        let low = ExportEstimator.mp4Bytes(renderSize: CGSize(width: 1920, height: 1080), fps: 30, duration: 60, quality: .low, hasAudio: true)
        #expect(low < bytes)
        let silent = ExportEstimator.mp4Bytes(renderSize: CGSize(width: 1920, height: 1080), fps: 30, duration: 60, quality: .high, hasAudio: false)
        #expect(silent < bytes)
        #expect(ExportEstimator.mp4Bytes(renderSize: CGSize(width: 10, height: 10), fps: 30, duration: 0, quality: .high, hasAudio: true) == 0)
    }

    @Test func sourceDataRateCapsTheEstimate() throws {
        let size = CGSize(width: 1920, height: 1080)
        // A 1 Mbps 4K source, exported at 1080p: a quarter of the pixels.
        let content = try #require(ExportEstimator.contentBitrate(sourceBitrate: 1_000_000, sourceSize: CGSize(width: 3840, height: 2160), renderSize: size))
        #expect(abs(content - 250_000 * 1.15) < 1e-6)
        let capped = ExportEstimator.mp4Bytes(renderSize: size, fps: 30, duration: 60, quality: .high, hasAudio: false, contentBitrate: content)
        #expect(abs(Double(capped) - content * 60 / 8 * 1.01) < 1)
        // A busy source never pushes the estimate above the encoder target.
        let busy = ExportEstimator.mp4Bytes(renderSize: size, fps: 30, duration: 60, quality: .low, hasAudio: false, contentBitrate: 100_000_000)
        #expect(busy == ExportEstimator.mp4Bytes(renderSize: size, fps: 30, duration: 60, quality: .low, hasAudio: false))
        #expect(ExportEstimator.contentBitrate(sourceBitrate: 0, sourceSize: size, renderSize: size) == nil)
        let doubled = try #require(ExportEstimator.contentBitrate(sourceBitrate: 1_000_000, sourceSize: size, sourceFrameRate: 30, renderSize: size, fps: 60))
        #expect(abs(doubled - 1_000_000 * 1.15 * 2.0.squareRoot()) < 1e-6)
        #expect(ExportEstimator.gifBytes(renderSize: CGSize(width: 100, height: 100), fps: 10, duration: 1, contentBitrate: 8_000) == 6_000)
    }

    @Test func tinyFramesStillGetAUsableBitrate() {
        #expect(ExportEstimator.videoBitrate(renderSize: CGSize(width: 16, height: 16), fps: 10, quality: .low) == 250_000)
    }

    @Test func gifFrameCountRoundsUp() {
        #expect(ExportEstimator.gifFrameCount(duration: 1.5, fps: 10) == 15)
        #expect(ExportEstimator.gifFrameCount(duration: 1.51, fps: 10) == 16)
        #expect(ExportEstimator.gifFrameCount(duration: 0, fps: 10) == 0)
        #expect(ExportEstimator.gifBytes(renderSize: CGSize(width: 100, height: 100), fps: 10, duration: 1) == 30_000)
    }

    @Test func originalFrameRateResolvesSensibly() {
        #expect(ExportFrameRate.original.resolve(sourceFrameRate: 59.94) == 60)
        #expect(ExportFrameRate.original.resolve(sourceFrameRate: 0) == 30)
        #expect(ExportFrameRate.original.resolve(sourceFrameRate: 240) == 60)
        #expect(ExportFrameRate.fps30.resolve(sourceFrameRate: 60) == 30)
    }

    @Test func settingsRoundTripThroughJSON() throws {
        let settings = ExportSettings(format: .gif, resolution: .hd720, quality: .low, frameRate: .fps60, gif: GIFOptions(width: nil, fps: 20))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }
}

@Suite("Frame renderer")
struct FrameRendererTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    /// RGBA8 pixels of `image` within its extent.
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

    private func project(_ configure: (inout VideoEditProject) -> Void = { _ in }) -> VideoEditProject {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        configure(&project)
        return project
    }

    @Test func plainPlanSkipsTheCustomCompositor() {
        let plan = RenderPlan(project: project(), sourceSize: CGSize(width: 100, height: 50))
        #expect(!plan.needsCustomCompositor)
        let zoomed = RenderPlan(project: project { $0.addZoom(at: 1) }, sourceSize: CGSize(width: 100, height: 50))
        #expect(zoomed.needsCustomCompositor)
        #expect(!RenderPlan(project: project { $0.addZoom(at: 1) }, sourceSize: CGSize(width: 100, height: 50), zoomEnabled: false).needsCustomCompositor)
        let framed = RenderPlan(project: project { $0.background.aspect = .square }, sourceSize: CGSize(width: 100, height: 50))
        #expect(framed.needsCustomCompositor)
        #expect(framed.renderSize == CGSize(width: 100, height: 100))
    }

    @Test func backgroundSurroundsThePaddedVideo() {
        let plan = RenderPlan(
            project: project {
                $0.background = VideoBackground(fill: .solid(RGBAColor(red: 1, green: 0, blue: 0)), padding: 0.2, cornerRadius: 0, shadow: false)
            },
            sourceSize: CGSize(width: 100, height: 50)
        )
        #expect(plan.videoRect == CGRect(x: 20, y: 10, width: 60, height: 30))
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let image = FrameRenderer(plan: plan).render(source: source, outputTime: 0)
        #expect(image.extent == CGRect(x: 0, y: 0, width: 100, height: 50))
        let pixel = pixels(image, size: plan.renderSize)
        #expect(pixel(2, 2) == (255, 0, 0))
        #expect(pixel(50, 25) == (0, 0, 255))
    }

    @Test func roundedCornersRevealTheBackground() {
        let plan = RenderPlan(
            project: project {
                $0.background = VideoBackground(fill: .solid(RGBAColor(red: 1, green: 0, blue: 0)), padding: 0.1, cornerRadius: 0.15, shadow: true)
            },
            sourceSize: CGSize(width: 200, height: 200)
        )
        let source = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
        let renderer = FrameRenderer(plan: plan)
        let pixel = pixels(renderer.render(source: source, outputTime: 0, backdrop: renderer.makeBackdrop()), size: plan.renderSize)
        let inset = Int(plan.videoRect.minX)
        // The video rect's very corner is rounded off; its middle edge isn't.
        #expect(pixel(inset + 1, inset + 1).b < 128)
        #expect(pixel(100, inset + 2).b > 200)
    }

    @Test func zoomShowsOnlyTheTargetArea() {
        // Left half green, right half blue; zoom into the top-right quadrant.
        let left = CIImage(color: CIColor(red: 0, green: 1, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 50, height: 50))
        let right = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 50, y: 0, width: 50, height: 50))
        let source = right.composited(over: left)
        let zoom = ZoomSegment(range: TimeRange(start: 0, end: 4), rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), easeDuration: 1)
        let plan = RenderPlan(project: project { $0.zooms = [zoom] }, sourceSize: CGSize(width: 100, height: 50))

        let zoomed = pixels(FrameRenderer(plan: plan).render(source: source, outputTime: 2), size: plan.renderSize)
        #expect(zoomed(2, 25) == (0, 0, 255))
        let unzoomed = pixels(FrameRenderer(plan: plan).render(source: source, outputTime: 5), size: plan.renderSize)
        #expect(unzoomed(2, 25) == (0, 255, 0))
    }
}
