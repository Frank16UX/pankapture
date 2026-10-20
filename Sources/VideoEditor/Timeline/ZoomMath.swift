import CoreGraphics
import Foundation

/// The visible part of the source frame at one moment.
public struct ZoomTransform: Equatable, Sendable {
    /// Normalized, top-left origin. `(0, 0, 1, 1)` means "no zoom".
    public var visibleRect: CGRect

    public static let identity = ZoomTransform(visibleRect: CGRect(x: 0, y: 0, width: 1, height: 1))

    public var scale: Double {
        let side = max(visibleRect.width, visibleRect.height)
        return side > 0 ? 1 / side : 1
    }

    public var isIdentity: Bool { abs(scale - 1) < 1e-9 }
}

/// Zoom & pan evaluation (VE-4). Pure; called per frame by the compositor.
public enum ZoomMath {
    public static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Ease-in-out (cubic): slow start, slow finish, symmetric.
    public static func ease(_ x: Double) -> Double {
        let x = x.clamped(to: 0...1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// 0 outside the segment, eases up to 1 over `easeDuration`, holds, and
    /// eases back to 0 by the end. Segments shorter than two eases peak lower
    /// but stay continuous.
    public static func progress(of zoom: ZoomSegment, at time: Double) -> Double {
        let range = zoom.range
        guard range.duration > 0, time > range.start, time < range.end else { return 0 }
        let ease = max(1e-3, min(zoom.easeDuration, range.duration / 2))
        let rampIn = (time - range.start) / ease
        let rampOut = (range.end - time) / ease
        return Self.ease(min(1, rampIn, rampOut))
    }

    /// Square (in normalized units) version of `rect`, at most the full frame,
    /// shifted so it lies entirely inside the frame.
    public static func clampInsideFrame(_ rect: CGRect) -> CGRect {
        var side = max(rect.width, rect.height)
        if !side.isFinite || side <= 0 { side = 1 }
        side = min(side, 1)
        let centerX = rect.isNull ? 0.5 : rect.midX
        let centerY = rect.isNull ? 0.5 : rect.midY
        let x = (centerX - side / 2).clamped(to: 0...(1 - side))
        let y = (centerY - side / 2).clamped(to: 0...(1 - side))
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Linear interpolation between the full frame and `target`. Both are
    /// inside the frame, so every intermediate rect is too (convexity).
    public static func interpolate(to target: CGRect, progress: Double) -> CGRect {
        let p = CGFloat(progress.clamped(to: 0...1))
        let from = fullFrame
        return CGRect(
            x: from.minX + (target.minX - from.minX) * p,
            y: from.minY + (target.minY - from.minY) * p,
            width: from.width + (target.width - from.width) * p,
            height: from.height + (target.height - from.height) * p
        )
    }

    /// The zoom at source `time`. Where zooms overlap, the most zoomed-in
    /// (highest progress) wins; ties go to the later segment.
    public static func transform(at time: Double, zooms: [ZoomSegment]) -> ZoomTransform {
        var best: (progress: Double, zoom: ZoomSegment)?
        for zoom in zooms {
            let p = progress(of: zoom, at: time)
            if p > 0, p >= (best?.progress ?? 0) { best = (p, zoom) }
        }
        guard let best else { return .identity }
        let target = clampInsideFrame(best.zoom.rect)
        return ZoomTransform(visibleRect: interpolate(to: target, progress: best.progress))
    }
}
