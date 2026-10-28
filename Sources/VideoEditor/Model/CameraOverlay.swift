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
        case square
        case roundedRectangle

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .circle: "Circle"
            case .square: "Square"
            case .roundedRectangle: "Rectangle"
            }
        }

        /// Width ÷ height.
        public var aspect: Double { self == .roundedRectangle ? 4.0 / 3.0 : 1 }

        /// Square and rectangle take a corner radius; a circle is always round.
        public var hasCorners: Bool { self != .circle }
    }

    public var isVisible: Bool
    /// Center, normalized to the video (top-left origin). Values outside 0…1
    /// put it in the padding; it's kept inside the canvas when drawn.
    public var center: CGPoint
    /// Width as a fraction of the video's shorter side.
    public var size: Double
    public var shape: Shape
    /// Corner radius of a square or rectangle, as a fraction of its shorter
    /// side (0 = sharp corners, 0.5 = fully rounded ends).
    public var roundness: Double
    public var isMirrored: Bool
    /// Blur, replace, or remove what's behind the person (PRD CAM-1).
    public var background: CameraBackground

    public init(
        isVisible: Bool = true,
        center: CGPoint,
        size: Double,
        shape: Shape = .circle,
        roundness: Double = CameraOverlay.defaultRoundness,
        isMirrored: Bool = true,
        background: CameraBackground = CameraBackground()
    ) {
        self.isVisible = isVisible
        self.center = center
        self.size = size
        self.shape = shape
        self.roundness = roundness
        self.isMirrored = isMirrored
        self.background = background
    }

    /// Where the bubble was on screen while recording.
    public init(_ sidecar: RecordingSidecar.Camera) {
        self.init(
            center: sidecar.center,
            size: sidecar.size.clamped(to: Self.sizeRange),
            shape: sidecar.shape.flatMap(Shape.init(rawValue:)) ?? (sidecar.isCircle ? .circle : .roundedRectangle),
            isMirrored: sidecar.isMirrored
        )
    }

    private enum CodingKeys: String, CodingKey {
        case isVisible, center, size, shape, roundness, isMirrored, background
    }

    /// Projects saved before `roundness` or `background` existed still open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        center = try container.decode(CGPoint.self, forKey: .center)
        size = try container.decode(Double.self, forKey: .size)
        shape = try container.decode(Shape.self, forKey: .shape)
        roundness = try container.decodeIfPresent(Double.self, forKey: .roundness) ?? Self.defaultRoundness
        isMirrored = try container.decode(Bool.self, forKey: .isMirrored)
        background = try container.decodeIfPresent(CameraBackground.self, forKey: .background) ?? CameraBackground()
    }

    /// Corner radius for a layer of `size`, in the same units.
    public func cornerRadius(for size: CGSize) -> CGFloat {
        let shortSide = min(size.width, size.height)
        return shape.hasCorners ? shortSide * CGFloat(roundness.clamped(to: Self.roundnessRange)) : shortSide / 2
    }

    /// Bottom-left of the video, when the recording didn't say.
    public static let standard = CameraOverlay(center: CGPoint(x: 0.12, y: 0.8), size: 0.25)
    public static let sizeRange: ClosedRange<Double> = 0.08...1
    public static let roundnessRange: ClosedRange<Double> = 0...0.5
    public static let defaultRoundness = 0.18

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
