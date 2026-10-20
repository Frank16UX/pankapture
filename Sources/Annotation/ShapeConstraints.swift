import CoreGraphics
import Foundation

/// Modifier-key constraints applied while drawing (AN-4).
public enum ShapeConstraints {
    /// Snaps `end` so the segment from `start` is at a multiple of 45°.
    public static func snap45(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return end }
        let step = Double.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
    }

    /// Rectangle spanned by a drag from `anchor` to `current`.
    /// - square: make width == height (the larger side wins, keeping the drag direction).
    /// - fromCenter: `anchor` is the center rather than a corner.
    public static func rect(from anchor: CGPoint, to current: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = current.x - anchor.x
        var dy = current.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: anchor.x, y: anchor.y, width: dx, height: dy).standardized
    }
}
