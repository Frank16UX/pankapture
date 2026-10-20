import AppCore
import CoreGraphics
import Foundation

/// The webcam layer of a recording made with the camera as its own track
/// (ADR-25): where it sits, how big, its shape, and whether it shows.
/// Drawn above the video, so zooms don't hide it (unless the zoom fills the
/// frame, which moves the camera with everything else).
public struct CameraOverlay: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, CaseIterable, Sendable, Identifiable {
        case circle
        case roundedRectangle

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .circle: "Circle"
            case .roundedRectangle: "Rectangle"
            }
        }

        /// Width ÷ height.
        public var aspect: Double { self == .circle ? 1 : 4.0 / 3.0 }
    }

    public var isVisible: Bool
    /// Center, normalized to the video (top-left origin). Values outside 0…1
    /// put it in the padding; it's kept inside the canvas when drawn.
    public var center: CGPoint
    /// Width as a fraction of the video's shorter side.
    public var size: Double
    public var shape: Shape
    public var isMirrored: Bool

    public init(isVisible: Bool = true, center: CGPoint, size: Double, shape: Shape = .circle, isMirrored: Bool = true) {
        self.isVisible = isVisible
        self.center = center
        self.size = size
        self.shape = shape
        self.isMirrored = isMirrored
    }

    /// Where the bubble was on screen while recording.
    public init(_ sidecar: RecordingSidecar.Camera) {
        self.init(
            center: sidecar.center,
            size: sidecar.size.clamped(to: Self.sizeRange),
            shape: sidecar.isCircle ? .circle : .roundedRectangle,
            isMirrored: sidecar.isMirrored
        )
    }

    /// Bottom-left of the video, when the recording didn't say.
    public static let standard = CameraOverlay(center: CGPoint(x: 0.12, y: 0.8), size: 0.25)
    public static let sizeRange: ClosedRange<Double> = 0.08...0.6

    /// The layer's rect in a **top-left** coordinate space, given the video
    /// rect and the canvas in that space. Kept inside the canvas.
    public func frame(video: CGRect, canvas: CGRect) -> CGRect {
        let width = min(CGFloat(size) * min(video.width, video.height), canvas.width, canvas.height * CGFloat(shape.aspect))
        let height = width / CGFloat(shape.aspect)
        let x = (video.minX + center.x * video.width - width / 2).clamped(to: canvas.minX...max(canvas.minX, canvas.maxX - width))
        let y = (video.minY + center.y * video.height - height / 2).clamped(to: canvas.minY...max(canvas.minY, canvas.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Moves the layer so its center is at `point` (top-left space).
    public mutating func setCenter(_ point: CGPoint, video: CGRect) {
        guard video.width > 0, video.height > 0 else { return }
        center = CGPoint(x: (point.x - video.minX) / video.width, y: (point.y - video.minY) / video.height)
    }
}
