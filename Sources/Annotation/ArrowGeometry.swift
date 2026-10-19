import CoreGraphics
import Foundation

/// Geometry for a filled-head arrow. The shaft stops at the base of the head so
/// thick strokes don't poke through the arrow tip.
public struct ArrowGeometry: Equatable, Sendable {
    public let shaftStart: CGPoint
    public let shaftEnd: CGPoint
    /// Tip, left wing, right wing.
    public let head: [CGPoint]

    public init(from start: CGPoint, to end: CGPoint, lineWidth: Double) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.0001)
        let angle = atan2(dy, dx)

        // Head scales with stroke width but never exceeds half the arrow length.
        let headLength = min(max(12, lineWidth * 4), length / 2)
        let spread = Double.pi / 7 // ~25.7° either side of the shaft

        let left = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let right = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        let base = CGPoint(
            x: end.x - headLength * cos(spread) * cos(angle),
            y: end.y - headLength * cos(spread) * sin(angle)
        )

        self.shaftStart = start
        self.shaftEnd = base
        self.head = [end, left, right]
    }
}
