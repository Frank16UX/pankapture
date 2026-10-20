import CoreGraphics
import Foundation

/// Output frame geometry: canvas size for an aspect ratio, export scaling, and
/// where the video sits inside the canvas. Pure; all sizes are pixels.
public enum CanvasLayout {
    /// Smallest canvas with `aspect` that fully contains `source` (so nothing
    /// is upscaled before export scaling), rounded to even pixels.
    public static func canvasSize(source: CGSize, aspect: OutputAspect) -> CGSize {
        guard source.width > 0, source.height > 0 else { return source }
        guard let ratio = aspect.ratio else { return even(source) }
        let sourceRatio = source.width / source.height
        if ratio >= sourceRatio {
            return even(CGSize(width: source.height * ratio, height: source.height))
        }
        return even(CGSize(width: source.width, height: source.width / ratio))
    }

    /// Scales `size` down so its shorter side is at most `shortSideCap`
    /// (never up), keeping the aspect ratio. `nil` cap = unchanged.
    public static func scaled(_ size: CGSize, shortSideCap: Double?) -> CGSize {
        guard let cap = shortSideCap, size.width > 0, size.height > 0 else { return even(size) }
        let factor = min(1, cap / min(size.width, size.height))
        return even(CGSize(width: size.width * factor, height: size.height * factor))
    }

    /// Scales `size` down to `width` (never up), keeping the aspect ratio.
    public static func scaled(_ size: CGSize, width: Int?) -> CGSize {
        guard let width, size.width > 0, size.height > 0 else { return even(size) }
        let factor = min(1, Double(width) / size.width)
        return even(CGSize(width: size.width * factor, height: size.height * factor))
    }

    /// The aspect-fit video rect inside `canvas`, inset by `padding` × the
    /// canvas' shorter side, centered. Symmetric, so it's the same in
    /// top-left and bottom-left coordinate systems.
    public static func videoRect(canvas: CGSize, source: CGSize, padding: Double) -> CGRect {
        let inset = padding.clamped(to: 0...0.45) * min(canvas.width, canvas.height)
        let available = CGRect(origin: .zero, size: canvas).insetBy(dx: inset, dy: inset)
        return aspectFit(source, in: available)
    }

    public static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let factor = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * factor, height: size.height * factor)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// Video encoders want even dimensions; never returns less than 2×2.
    public static func even(_ size: CGSize) -> CGSize {
        CGSize(width: even(size.width), height: even(size.height))
    }

    static func even(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 2 }
        return max(2, (value / 2).rounded() * 2)
    }
}
