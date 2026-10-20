import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

/// Everything needed to draw one output frame, resolved from a project for a
/// specific output size. Immutable and `Sendable`: it travels inside the
/// compositor instruction to AVFoundation's render queue.
public struct RenderPlan: Sendable, Equatable {
    /// Display-oriented source frame size, pixels.
    public var sourceSize: CGSize
    /// Rotation that turns the decoded buffer upright (from `preferredTransform`).
    public var orientation: CGImagePropertyOrientation
    /// Output frame size, pixels.
    public var renderSize: CGSize
    /// Where the video sits in the output (pixels; centered, so origin-agnostic).
    public var videoRect: CGRect
    /// Rounded-corner radius of the video, pixels.
    public var cornerRadius: CGFloat
    public var shadow: Bool
    public var fill: VideoBackground.Fill
    public var zooms: [ZoomSegment]
    public var timeline: Timeline
    /// The editor turns zoom off while the user positions a zoom rectangle.
    public var zoomEnabled: Bool
    public var altersFrame: Bool

    /// - Parameters:
    ///   - shortSideCap: export resolution cap (MP4 presets).
    ///   - width: exact output width cap (GIF).
    public init(
        project: VideoEditProject,
        sourceSize: CGSize,
        orientation: CGImagePropertyOrientation = .up,
        shortSideCap: Double? = nil,
        width: Int? = nil,
        zoomEnabled: Bool = true
    ) {
        let background = project.background
        let canvas = CanvasLayout.canvasSize(source: sourceSize, aspect: background.aspect)
        var renderSize = CanvasLayout.scaled(canvas, shortSideCap: shortSideCap)
        if width != nil { renderSize = CanvasLayout.scaled(renderSize, width: width) }
        let videoRect = CanvasLayout.videoRect(canvas: renderSize, source: sourceSize, padding: background.effectivePadding)

        self.sourceSize = sourceSize
        self.orientation = orientation
        self.renderSize = renderSize
        self.videoRect = videoRect
        self.cornerRadius = CGFloat(background.effectiveCornerRadius) * min(videoRect.width, videoRect.height)
        self.shadow = background.effectiveShadow
        self.fill = background.fill
        self.zooms = project.zooms
        self.timeline = Timeline(project: project)
        self.zoomEnabled = zoomEnabled
        self.altersFrame = background.altersFrame
    }

    /// When false, frames are a plain scaled copy of the source and the much
    /// cheaper built-in compositor is used instead of `VideoEditCompositor`.
    public var needsCustomCompositor: Bool {
        altersFrame || (zoomEnabled && !zooms.isEmpty)
    }

    /// Identity of the static backdrop (fill + shadow) so it can be cached.
    var backdropKey: BackdropKey {
        BackdropKey(
            geometry: [renderSize.width, renderSize.height, videoRect.minX, videoRect.minY,
                       videoRect.width, videoRect.height, cornerRadius].map(Double.init),
            shadow: shadow,
            fill: fill
        )
    }

    struct BackdropKey: Hashable, Sendable {
        var geometry: [Double]
        var shadow: Bool
        var fill: VideoBackground.Fill
    }
}

/// Draws output frames with Core Image: zoom/pan, then the video placed on its
/// background with rounded corners and a shadow. Pure function of the plan,
/// time, and source image; `VideoEditCompositor` supplies the GPU context.
public struct FrameRenderer: Sendable {
    public let plan: RenderPlan

    public init(plan: RenderPlan) {
        self.plan = plan
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: plan.renderSize) }

    /// The static part behind the video: fill and shadow. Cache it per plan
    /// (`VideoEditCompositor` renders it once into a bitmap).
    public func makeBackdrop() -> CIImage {
        let canvas = canvasRect
        var backdrop: CIImage
        switch plan.fill {
        case .none:
            backdrop = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        case let .solid(color):
            backdrop = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: canvas)
        case let .gradient(preset):
            let gradient = CIFilter.linearGradient()
            // Core Image is bottom-left origin: top-leading → bottom-trailing.
            gradient.point0 = CGPoint(x: canvas.minX, y: canvas.maxY)
            gradient.point1 = CGPoint(x: canvas.maxX, y: canvas.minY)
            gradient.color0 = CIColor(cgColor: preset.colors.start.cgColor)
            gradient.color1 = CIColor(cgColor: preset.colors.end.cgColor)
            backdrop = (gradient.outputImage ?? CIImage.empty()).cropped(to: canvas)
        }

        if plan.shadow {
            let shortSide = min(plan.videoRect.width, plan.videoRect.height)
            let shape = roundedRect(plan.videoRect, radius: plan.cornerRadius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            let blurred = shape
                .clampedToExtent()
                .applyingGaussianBlur(sigma: Double(shortSide) * 0.025)
                .cropped(to: plan.videoRect.insetBy(dx: -shortSide * 0.2, dy: -shortSide * 0.2))
                .transformed(by: CGAffineTransform(translationX: 0, y: -shortSide * 0.015))
            backdrop = blurred.composited(over: backdrop).cropped(to: canvas)
        }
        return backdrop
    }

    /// Composes the output frame at output `time` (seconds).
    public func render(source: CIImage, outputTime time: Double, backdrop: CIImage? = nil) -> CIImage {
        let upright = source.oriented(plan.orientation)
        let frame = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let size = frame.extent.size

        let sourceTime = plan.timeline.sourceTime(forOutput: time)
        let zoom = plan.zoomEnabled ? ZoomMath.transform(at: sourceTime, zooms: plan.zooms) : .identity

        // Visible rect: normalized top-left → Core Image pixels (bottom-left).
        let visible = zoom.visibleRect
        let crop = CGRect(
            x: visible.minX * size.width,
            y: (1 - visible.maxY) * size.height,
            width: max(1, visible.width * size.width),
            height: max(1, visible.height * size.height)
        )
        let target = plan.videoRect
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: target.width / crop.width, y: target.height / crop.height))
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        var video = frame.clampedToExtent().transformed(by: transform).cropped(to: target)

        if plan.cornerRadius > 0.5 {
            let mask = roundedRect(target, radius: plan.cornerRadius, color: CIColor(red: 1, green: 1, blue: 1))
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = video
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask
            video = blend.outputImage ?? video
        }

        let background = backdrop ?? (plan.altersFrame ? makeBackdrop() : nil)
        guard let background else { return video.cropped(to: canvasRect) }
        return video.composited(over: background).cropped(to: canvasRect)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage ?? CIImage(color: color).cropped(to: rect)
    }
}
