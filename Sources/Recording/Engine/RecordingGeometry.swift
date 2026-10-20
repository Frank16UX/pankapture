import CoreGraphics

/// Pure coordinate math for recording (ARCHITECTURE §5). Every function names
/// the space of its inputs and outputs:
/// - **AppKit global**: bottom-left of the primary display, y up (`NSEvent.mouseLocation`, `NSScreen.frame`).
/// - **Quartz global**: top-left of the primary display, y down (`CGDisplayBounds`, `CGWindowList`, `SCDisplay.frame`).
/// - **Display-local**: top-left of one display, y down (area rects, `sourceRect`).
public enum RecordingGeometry {
    /// Video encoders want even dimensions (4:2:0 chroma subsampling).
    /// Rounds to the nearest even integer, minimum 2.
    public static func evenPixels(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 2 }
        return max(2, Int((value / 2).rounded()) * 2)
    }

    /// Even pixel count that never exceeds `value` (minimum 2).
    public static func evenPixelsNotExceeding(_ value: CGFloat) -> Int {
        guard value.isFinite, value > 0 else { return 2 }
        return max(2, Int((value / 2).rounded(.down)) * 2)
    }

    /// Output pixel size for content of `pointSize` at `scale` pixels per point.
    public static func outputPixelSize(forPointSize pointSize: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        (evenPixels(pointSize.width * scale), evenPixels(pointSize.height * scale))
    }

    public struct AreaCapture: Equatable, Sendable {
        /// `SCStreamConfiguration.sourceRect`: display-local points, snapped to the pixel grid.
        public var sourceRect: CGRect
        public var width: Int
        public var height: Int
    }

    /// Prepares an area recording: clamps `rect` (display-local points) to the
    /// display, snaps it to whole pixels, and shrinks it so the pixel size is even.
    /// Because `sourceRect × scale == width × height` exactly, frames are copied
    /// 1:1 with no resampling blur. Returns `nil` for an empty area.
    public static func areaCapture(rect: CGRect, displaySize: CGSize, scale: CGFloat) -> AreaCapture? {
        guard scale > 0 else { return nil }
        let clamped = rect.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clamped.isNull, clamped.width * scale >= 2, clamped.height * scale >= 2 else { return nil }

        // Snap the origin to the pixel grid (round outward), then take an even
        // pixel size that still fits within the clamped rect's far edge.
        let originX = (clamped.minX * scale).rounded(.down)
        let originY = (clamped.minY * scale).rounded(.down)
        let maxX = (clamped.maxX * scale).rounded(.down)
        let maxY = (clamped.maxY * scale).rounded(.down)
        let width = evenPixelsNotExceeding(maxX - originX)
        let height = evenPixelsNotExceeding(maxY - originY)

        let sourceRect = CGRect(
            x: originX / scale,
            y: originY / scale,
            width: CGFloat(width) / scale,
            height: CGFloat(height) / scale
        )
        return AreaCapture(sourceRect: sourceRect, width: width, height: height)
    }

    // MARK: Space conversions

    /// AppKit global point → Quartz global point. `primaryDisplayHeight` is the
    /// height of the display whose AppKit origin is (0,0) (`NSScreen.screens[0]`).
    public static func quartzPoint(fromAppKit point: CGPoint, primaryDisplayHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// Quartz global rect → AppKit global rect (the flip is symmetric).
    public static func appKitRect(fromQuartz rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryDisplayHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// AppKit global rect → Quartz global rect.
    public static func quartzRect(fromAppKit rect: CGRect, primaryDisplayHeight: CGFloat) -> CGRect {
        appKitRect(fromQuartz: rect, primaryDisplayHeight: primaryDisplayHeight)
    }

    /// Display-local rect (top-left origin) → Quartz global, given the display's Quartz bounds.
    public static func quartzRect(fromDisplayLocal rect: CGRect, displayBounds: CGRect) -> CGRect {
        rect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
    }

    /// Position of `point` (Quartz global) inside `frame` (Quartz global) as a
    /// fraction: (0,0) top-left, (1,1) bottom-right. `nil` if outside the frame
    /// (the click isn't visible in the video).
    public static func normalizedLocation(ofQuartzPoint point: CGPoint, in frame: CGRect) -> CGPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Convenience: an AppKit-global click → normalized position in a recorded
    /// frame given in Quartz global coordinates.
    public static func normalizedLocation(
        ofAppKitPoint point: CGPoint,
        inQuartzFrame frame: CGRect,
        primaryDisplayHeight: CGFloat
    ) -> CGPoint? {
        normalizedLocation(
            ofQuartzPoint: quartzPoint(fromAppKit: point, primaryDisplayHeight: primaryDisplayHeight),
            in: frame
        )
    }
}
