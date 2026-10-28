import AppKit
import CoreImage
import CoreText
import Synchronization

/// Draws a caption cue into an image with Core Text, once per text, style,
/// and output size: frames only composite the cached image (PRD CAP-3).
/// `Sendable`: its only mutable state, the cache, lives in a `Mutex`.
final class CaptionRasterizer: Sendable {
    static let shared = CaptionRasterizer()

    private struct Key: Hashable {
        var text: String
        var style: CaptionSettings.Style
        var size: CaptionSettings.Size
        var canvas: CGSize

        func hash(into hasher: inout Hasher) {
            hasher.combine(text)
            hasher.combine(style)
            hasher.combine(size)
            hasher.combine(canvas.width)
            hasher.combine(canvas.height)
        }
    }

    private let cache = Mutex<[Key: CIImage]>([:])
    /// Cues are short; a few dozen cover any scrubbing back and forth.
    private static let capacity = 48

    /// The cue placed on the canvas (Core Image coordinates), or `nil`.
    func image(for cue: CaptionCue, track: CaptionTrack, canvas: CGSize) -> CIImage? {
        let key = Key(text: cue.text, style: track.style, size: track.size, canvas: canvas)
        let bitmap: CIImage
        if let cached = cache.withLock({ $0[key] }) {
            bitmap = cached
        } else {
            guard let rendered = Self.rasterize(lines: cue.lines, style: track.style, size: track.size, canvas: canvas) else { return nil }
            bitmap = CIImage(cgImage: rendered)
            cache.withLock { cache in
                if cache.count >= Self.capacity { cache.removeAll() }
                cache[key] = bitmap
            }
        }
        let margin = canvas.height * 0.06
        let x = (canvas.width - bitmap.extent.width) / 2
        let y = track.position == .bottom ? margin : canvas.height - margin - bitmap.extent.height
        return bitmap.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }

    static func rasterize(lines: [String], style: CaptionSettings.Style, size: CaptionSettings.Size, canvas: CGSize) -> CGImage? {
        let textColor: CGColor = style == .highlight ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 1, alpha: 1)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        func measure(_ fontSize: CGFloat) -> (lines: [CTLine], widths: [CGFloat]) {
            let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold) as CTFont
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor,
            ]
            let ctLines = lines.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
            return (ctLines, ctLines.map { CGFloat(CTLineGetTypographicBounds($0, &ascent, &descent, &leading)) })
        }
        // The font follows the output height, so a narrow (portrait) canvas
        // can be too slim for a full line: shrink the font until it fits.
        // Width grows linearly with the font size, so one rescale does it.
        let maxWidth = canvas.width * 0.92
        var fontSize = max(12, canvas.height * size.heightFraction)
        var (ctLines, widths) = measure(fontSize)
        let needed = (widths.max() ?? 0) + fontSize
        if needed > maxWidth {
            fontSize = max(6, fontSize * maxWidth / needed)
            (ctLines, widths) = measure(fontSize)
        }
        let lineHeight = (ascent + descent) * 1.18
        let horizontal = fontSize * 0.5
        let vertical = fontSize * 0.28
        let width = min(maxWidth, (widths.max() ?? 0) + 2 * horizontal)
        let height = CGFloat(ctLines.count) * lineHeight + 2 * vertical
        guard width > 1, height > 1,
              let context = CGContext(data: nil, width: Int(width.rounded(.up)), height: Int(height.rounded(.up)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        let box = CGRect(x: 0, y: 0, width: width, height: height)
        switch style {
        case .box:
            context.setFillColor(CGColor(gray: 0, alpha: 0.72))
            context.addPath(CGPath(roundedRect: box, cornerWidth: fontSize * 0.3, cornerHeight: fontSize * 0.3, transform: nil))
            context.fillPath()
        case .highlight:
            context.setFillColor(CGColor(red: 1, green: 0.86, blue: 0.2, alpha: 1))
            context.addPath(CGPath(roundedRect: box, cornerWidth: fontSize * 0.25, cornerHeight: fontSize * 0.25, transform: nil))
            context.fillPath()
        case .outline:
            break
        }

        for (index, line) in ctLines.enumerated() {
            let x = (width - widths[index]) / 2
            // Lines run top to bottom; Core Graphics' origin is bottom-left.
            let baseline = height - vertical - CGFloat(index) * lineHeight - ascent - (lineHeight - ascent - descent) / 2
            context.textPosition = CGPoint(x: x, y: baseline)
            if style == .outline {
                context.setLineWidth(fontSize * 0.14)
                context.setLineJoin(.round)
                context.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
                context.setTextDrawingMode(.stroke)
                CTLineDraw(line, context)
                context.textPosition = CGPoint(x: x, y: baseline)
                context.setTextDrawingMode(.fill)
            }
            CTLineDraw(line, context)
        }
        return context.makeImage()
    }
}
