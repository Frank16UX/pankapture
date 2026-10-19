import AppKit
import CoreGraphics
import CoreImage

/// Flattens a capture plus its annotations into a single bitmap for
/// save / copy / print / share. Live editing draws the same shapes through
/// `draw(_:in:imageScale:source:)` so on-screen and exported output match.
public enum AnnotationRenderer {
    /// - Parameters:
    ///   - base: The captured image (pixels).
    ///   - scale: Pixels per point of the capture (annotations are stored in points).
    public static func render(_ document: AnnotationDocument, onto base: CGImage, scale: CGFloat) -> CGImage? {
        let width = base.width
        let height = base.height
        let colorSpace = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip to top-left origin and scale points → pixels.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        for annotation in document.annotations {
            draw(annotation, in: context, imageScale: scale, source: base)
        }
        return context.makeImage()
    }

    /// Draws one annotation into a context already in top-left point space.
    public static func draw(_ annotation: Annotation, in context: CGContext, imageScale: CGFloat, source: CGImage) {
        let style = annotation.style
        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(style.color.cgColor)
        context.setFillColor(style.color.cgColor)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.shape {
        case let .freehand(points):
            strokePolyline(points, in: context)

        case let .highlighter(points):
            context.setBlendMode(.multiply)
            context.setStrokeColor(style.color.withAlpha(0.35).cgColor)
            context.setLineWidth(max(style.lineWidth * 4, 14))
            context.setLineCap(.butt)
            strokePolyline(points, in: context)

        case let .line(from, to):
            context.strokeLineSegments(between: [from, to])

        case let .arrow(from, to):
            let arrow = ArrowGeometry(from: from, to: to, lineWidth: style.lineWidth)
            context.strokeLineSegments(between: [arrow.shaftStart, arrow.shaftEnd])
            context.addLines(between: arrow.head)
            context.closePath()
            context.fillPath()

        case let .rectangle(rect):
            context.stroke(rect.standardized)

        case let .ellipse(rect):
            context.strokeEllipse(in: rect.standardized)

        case let .text(origin, string, fontSize):
            drawText(string, at: origin, fontSize: fontSize, color: style.color, in: context)

        case let .blur(rect):
            drawFiltered(rect, source: source, imageScale: imageScale, in: context) { image in
                image.clampedToExtent()
                    .applyingGaussianBlur(sigma: 12 * imageScale)
                    .cropped(to: image.extent)
            }

        case let .pixelate(rect):
            drawFiltered(rect, source: source, imageScale: imageScale, in: context) { image in
                image.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 12 * imageScale])
                    .cropped(to: image.extent)
            }

        case let .counter(center, number):
            drawCounter(number, at: center, style: style, in: context)
        }
    }

    // MARK: - Helpers

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    private static func drawText(_ string: String, at origin: CGPoint, fontSize: Double, color: RGBAColor, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red,
        ]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAttributedString(string: string, attributes: attributes).draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCounter(_ number: Int, at center: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let diameter = max(24, style.lineWidth * 7)
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.fillEllipse(in: circle)

        let label = "\(number)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.55, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Re-draws a region of the *original* capture through a Core Image filter.
    /// Always samples the source, so blur/pixelate can't be undone by stacking.
    private static func drawFiltered(
        _ rect: CGRect,
        source: CGImage,
        imageScale: CGFloat,
        in context: CGContext,
        filter: (CIImage) -> CIImage
    ) {
        let rect = rect.standardized
        let pixelRect = CGRect(
            x: rect.minX * imageScale,
            y: rect.minY * imageScale,
            width: rect.width * imageScale,
            height: rect.height * imageScale
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let region = source.cropping(to: pixelRect) else { return }

        let input = CIImage(cgImage: region)
        let output = filter(input)
        guard let filtered = CIContext(options: [.cacheIntermediates: false]).createCGImage(output, from: input.extent) else { return }

        // The context is flipped (top-left origin); flip locally so the image isn't upside down.
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(filtered, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}
