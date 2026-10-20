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
    /// Rotation that turns background-video frames upright.
    public var backgroundOrientation: CGImagePropertyOrientation
    public var zooms: [ZoomSegment]
    /// Zoom moves a camera over the whole canvas (see `VideoEditProject.zoomFillsFrame`).
    public var zoomFillsFrame: Bool
    /// The webcam layer to draw (visible, and the source has a camera track).
    public var camera: CameraOverlay?
    /// Rotation that turns camera frames upright.
    public var cameraOrientation: CGImagePropertyOrientation
    public var timeline: Timeline
    /// The editor turns zoom off while the user positions a zoom rectangle.
    public var zoomEnabled: Bool
    public var altersFrame: Bool

    /// - Parameters:
    ///   - shortSideCap: resolution cap, never upscaling (the preview).
    ///   - shortSide: exact shorter side, up or down (MP4 export presets).
    ///   - width: exact output width cap (GIF).
    public init(
        project: VideoEditProject,
        sourceSize: CGSize,
        orientation: CGImagePropertyOrientation = .up,
        shortSideCap: Double? = nil,
        shortSide: Double? = nil,
        width: Int? = nil,
        zoomEnabled: Bool = true,
        backgroundOrientation: CGImagePropertyOrientation = .up,
        hasCameraTrack: Bool = false,
        cameraOrientation: CGImagePropertyOrientation = .up
    ) {
        let background = project.background
        let canvas = CanvasLayout.canvasSize(source: sourceSize, aspect: background.aspect)
        var renderSize = shortSide != nil
            ? CanvasLayout.scaled(canvas, shortSide: shortSide)
            : CanvasLayout.scaled(canvas, shortSideCap: shortSideCap)
        if width != nil { renderSize = CanvasLayout.scaled(renderSize, width: width) }
        let videoRect = CanvasLayout.videoRect(canvas: renderSize, source: sourceSize, padding: background.effectivePadding)

        self.sourceSize = sourceSize
        self.orientation = orientation
        self.renderSize = renderSize
        self.videoRect = videoRect
        self.cornerRadius = CGFloat(background.effectiveCornerRadius) * min(videoRect.width, videoRect.height)
        self.shadow = background.effectiveShadow
        self.fill = background.fill
        self.backgroundOrientation = backgroundOrientation
        self.zooms = project.zooms
        self.zoomFillsFrame = project.zoomFillsFrame
        let camera = hasCameraTrack ? (project.camera ?? .standard) : nil
        self.camera = camera?.isVisible == true ? camera : nil
        self.cameraOrientation = cameraOrientation
        self.timeline = Timeline(project: project)
        self.zoomEnabled = zoomEnabled
        self.altersFrame = background.altersFrame
    }

    /// When false, frames are a plain scaled copy of the source and the much
    /// cheaper built-in compositor is used instead of `VideoEditCompositor`.
    public var needsCustomCompositor: Bool {
        altersFrame || camera != nil || (zoomEnabled && !zooms.isEmpty)
    }

    /// Where the camera layer sits in the output, pixels, **bottom-left**
    /// origin (Core Image), before any full-frame zoom.
    public var cameraRect: CGRect? {
        guard let camera else { return nil }
        // `videoRect` is centered, so it's the same in both origins.
        let topLeft = camera.frame(video: videoRect, canvas: CGRect(origin: .zero, size: renderSize))
        return CGRect(x: topLeft.minX, y: renderSize.height - topLeft.maxY, width: topLeft.width, height: topLeft.height)
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

/// Draws output frames with Core Image: the video placed on its background
/// with rounded corners and a shadow, zoomed either inside the video or (full
/// frame) as a camera over the whole canvas. Pure function of the plan, time,
/// and source images; `VideoEditCompositor` supplies the GPU context.
public struct FrameRenderer: Sendable {
    public let plan: RenderPlan

    public init(plan: RenderPlan) {
        self.plan = plan
    }

    public var canvasRect: CGRect { CGRect(origin: .zero, size: plan.renderSize) }

    /// The static part behind the video: fill and shadow. Cache it per plan
    /// (`VideoEditCompositor` renders it once into a bitmap). With a video
    /// fill it's only the shadow, over transparency; each frame's background
    /// picture goes underneath (`render(…, background:)`).
    public func makeBackdrop() -> CIImage {
        let canvas = canvasRect
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
        var backdrop: CIImage
        switch plan.fill {
        case .none:
            backdrop = black
        case let .solid(color):
            backdrop = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: canvas)
        case .gradient, .customGradient:
            backdrop = plan.fill.gradient.map { gradientImage($0, in: canvas) } ?? black
        case let .image(url):
            let picture = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
            backdrop = picture.map { aspectFill($0, in: canvas) } ?? black
        case .video:
            backdrop = CIImage(color: .clear).cropped(to: canvas)
        }

        if plan.shadow {
            backdrop = shadowImage().composited(over: backdrop).cropped(to: canvas)
        }
        return backdrop
    }

    /// Composes the output frame at output `time` (seconds). `background` is
    /// the background video's frame when the fill is a video; `camera` the
    /// webcam track's frame.
    public func render(
        source: CIImage,
        outputTime time: Double,
        backdrop: CIImage? = nil,
        background: CIImage? = nil,
        camera cameraFrame: CIImage? = nil
    ) -> CIImage {
        let upright = source.oriented(plan.orientation)
        let frame = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let size = frame.extent.size
        let canvas = canvasRect

        let sourceTime = plan.timeline.sourceTime(forOutput: time)
        // Full-frame zoom moves a camera over the canvas; otherwise the zoom
        // crops the source inside the (fixed) video rect.
        var camera = CGAffineTransform.identity
        var visible = ZoomMath.fullFrame
        if plan.zoomEnabled {
            if plan.zoomFillsFrame {
                if let shown = ZoomMath.canvasVisibleRect(at: sourceTime, zooms: plan.zooms, canvas: plan.renderSize, videoRect: plan.videoRect),
                   shown.width > 0 {
                    let scale = canvas.width / shown.width
                    camera = CGAffineTransform(translationX: -shown.minX, y: -shown.minY)
                        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                }
            } else {
                visible = ZoomMath.transform(at: sourceTime, zooms: plan.zooms).visibleRect
            }
        }

        // Visible rect: normalized top-left → Core Image pixels (bottom-left).
        let crop = CGRect(
            x: visible.minX * size.width,
            y: (1 - visible.maxY) * size.height,
            width: max(1, visible.width * size.width),
            height: max(1, visible.height * size.height)
        )
        let target = plan.videoRect.applying(camera)
        let radius = plan.cornerRadius * abs(camera.a)
        let transform = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: target.width / crop.width, y: target.height / crop.height))
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        var video = frame.clampedToExtent().transformed(by: transform).cropped(to: target)

        if radius > 0.5 {
            let mask = roundedRect(target, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = video
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask
            video = blend.outputImage ?? video
        }

        var frameImage: CIImage
        if plan.altersFrame || camera != .identity {
            var back = backdrop ?? makeBackdrop()
            if let background, plan.fill.videoURL != nil {
                back = back.composited(over: aspectFill(background.oriented(plan.backgroundOrientation), in: canvas))
            }
            if camera != .identity {
                back = back.transformed(by: camera)
            }
            frameImage = video.composited(over: back.cropped(to: canvas))
        } else {
            frameImage = video
        }
        // The webcam stays put while the video zooms; a full-frame zoom
        // moves it along with everything else.
        if let cameraFrame, let layer = cameraLayer(cameraFrame) {
            frameImage = layer.transformed(by: camera).composited(over: frameImage)
        }
        return frameImage.cropped(to: canvas)
    }

    /// The webcam frame cropped to the layer's shape, with a soft shadow,
    /// placed at `plan.cameraRect`.
    func cameraLayer(_ frame: CIImage) -> CIImage? {
        guard let overlay = plan.camera, let rect = plan.cameraRect, rect.width > 1, rect.height > 1 else { return nil }
        var image = frame.oriented(plan.cameraOrientation)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if overlay.isMirrored {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        // Center-crop to the shape's aspect, then fill the layer.
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let aspect = CGFloat(overlay.shape.aspect)
        let cropSize = size.width / size.height > aspect
            ? CGSize(width: size.height * aspect, height: size.height)
            : CGSize(width: size.width, height: size.width / aspect)
        let crop = CGRect(x: (size.width - cropSize.width) / 2, y: (size.height - cropSize.height) / 2,
                          width: cropSize.width, height: cropSize.height)
        let scale = rect.width / crop.width
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
            .cropped(to: rect)

        let radius = overlay.cornerRadius(for: rect.size)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = placed
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = roundedRect(rect, radius: radius, color: CIColor(red: 1, green: 1, blue: 1))
        let masked = blend.outputImage ?? placed

        let sigma = Double(rect.height) * 0.04
        let reach = CGFloat(sigma * 4)
        let padded = rect.insetBy(dx: -reach, dy: -reach)
        let shadow = roundedRect(rect, radius: radius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .composited(over: CIImage(color: .clear).cropped(to: padded))
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: padded)
            .transformed(by: CGAffineTransform(translationX: 0, y: -rect.height * 0.02))
        return masked.composited(over: shadow)
    }

    // MARK: Pieces

    /// The soft shadow under the video, on transparency.
    ///
    /// The shape is padded with transparent pixels before blurring. Clamping
    /// it to its extent instead smears its edge rows outward into bands that
    /// the crop then cuts off: a dark frame around the video.
    func shadowImage() -> CIImage {
        let rect = plan.videoRect
        let shortSide = min(rect.width, rect.height)
        let sigma = Double(shortSide) * 0.025
        let reach = CGFloat(sigma * 4)
        let padded = rect.insetBy(dx: -reach, dy: -reach)
        let shape = roundedRect(rect, radius: plan.cornerRadius, color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45))
            .composited(over: CIImage(color: .clear).cropped(to: padded))
        return shape
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: padded)
            .transformed(by: CGAffineTransform(translationX: 0, y: -shortSide * 0.015))
    }

    private func gradientImage(_ gradient: CustomGradient, in canvas: CGRect) -> CIImage {
        let filter = CIFilter.linearGradient()
        let points = gradient.endpoints(in: canvas)
        filter.point0 = points.start
        filter.point1 = points.end
        filter.color0 = CIColor(cgColor: gradient.start.cgColor)
        filter.color1 = CIColor(cgColor: gradient.end.cgColor)
        return (filter.outputImage ?? CIImage.empty()).cropped(to: canvas)
    }

    /// Scales `image` to cover `rect` (cropping the overflow), centered.
    func aspectFill(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite else { return image }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let size = CGSize(width: extent.width * scale, height: extent.height * scale)
        let transform = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        return image.transformed(by: transform).cropped(to: rect)
    }

    private func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor) -> CIImage {
        let generator = CIFilter.roundedRectangleGenerator()
        generator.extent = rect
        generator.radius = Float(radius)
        generator.color = color
        return generator.outputImage ?? CIImage(color: color).cropped(to: rect)
    }
}
