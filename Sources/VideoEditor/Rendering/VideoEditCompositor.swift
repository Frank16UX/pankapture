import AppCore
import AVFoundation
import CoreImage
import Synchronization

/// The single instruction our compositions use: it spans the whole output and
/// carries the immutable `FrameRenderer` (plan + timeline) to the compositor.
final class VideoEditInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let sourceTrackID: CMPersistentTrackID
    let renderer: FrameRenderer

    var requiredSourceTrackIDs: [NSValue]? { [NSNumber(value: sourceTrackID)] }

    init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, renderer: FrameRenderer) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.renderer = renderer
    }
}

/// Custom `AVVideoCompositing` that renders zoom/pan and the background with
/// Core Image on the GPU. Used by the preview player, MP4 export, and GIF
/// export alike, so what you see is what you export.
///
/// AVFoundation calls this object from its own (arbitrary) queues. It's
/// `Sendable` because its only mutable state, the backdrop cache, lives in a
/// `Mutex`; `CIContext` and `CIImage` are thread-safe.
final class VideoEditCompositor: NSObject, AVVideoCompositing, Sendable {
    /// One GPU context for the whole app: creating one is expensive (ARCH §10).
    static let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .name: "Pankapture.VideoEditor",
    ])
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct Backdrop {
        var key: RenderPlan.BackdropKey
        var image: CIImage
    }

    private let backdrop = Mutex<Backdrop?>(nil)

    private static let pixelFormat: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelFormat }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelFormat }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? VideoEditInstruction else {
            request.finish(with: VideoEditorError.compositionFailed("Unexpected instruction"))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: VideoEditorError.compositionFailed("No output buffer"))
            return
        }

        let renderer = instruction.renderer
        let backdrop = cachedBackdrop(for: renderer)
        var image: CIImage
        if let sourceBuffer = request.sourceFrame(byTrackID: instruction.sourceTrackID) {
            image = renderer.render(
                source: CIImage(cvPixelBuffer: sourceBuffer),
                outputTime: request.compositionTime.seconds,
                backdrop: backdrop
            )
        } else {
            image = backdrop
        }

        // The player may render at a reduced size (renderScale); fit to it.
        let contextSize = request.renderContext.size
        let planSize = renderer.plan.renderSize
        if contextSize != planSize, planSize.width > 0, planSize.height > 0 {
            image = image.transformed(by: CGAffineTransform(
                scaleX: contextSize.width / planSize.width,
                y: contextSize.height / planSize.height
            ))
        }

        Self.ciContext.render(
            image,
            to: output,
            bounds: CGRect(origin: .zero, size: contextSize),
            colorSpace: Self.colorSpace
        )
        request.finish(withComposedVideoFrame: output)
    }

    /// The fill + shadow for this plan, rendered to a bitmap once and reused
    /// for every frame (the blur is the most expensive part of a frame).
    private func cachedBackdrop(for renderer: FrameRenderer) -> CIImage {
        let key = renderer.plan.backdropKey
        if let cached = backdrop.withLock({ $0?.key == key ? $0?.image : nil }) {
            return cached
        }
        let recipe = renderer.makeBackdrop()
        let image: CIImage
        if let cgImage = Self.ciContext.createCGImage(recipe, from: renderer.canvasRect, format: .BGRA8, colorSpace: Self.colorSpace) {
            image = CIImage(cgImage: cgImage)
        } else {
            image = recipe
        }
        backdrop.withLock { $0 = Backdrop(key: key, image: image) }
        return image
    }
}
