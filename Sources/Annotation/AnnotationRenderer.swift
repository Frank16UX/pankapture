import AppKit
import CoreGraphics
import CoreImage

/// Flattens a capture plus its annotations into a single bitmap for
/// save / copy / print / share. Live editing draws the same shapes through
/// `draw(_:in:imageScale:source:cache:)` so on-screen and exported output match.
public enum AnnotationRenderer {
    /// Core Image context shared by every blur/pixelate render (thread-safe).
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders annotations over the whole `base` image.
    /// - Parameters:
    ///   - base: The captured image (pixels).
    ///   - scale: Pixels per point of the capture (annotations are stored in points).
    public static func render(_ document: AnnotationDocument, onto base: CGImage, scale: CGFloat) -> CGImage? {
        render(document, source: base, scale: scale, crop: nil)
    }

    /// Renders the `crop` region (in `source` points, top-left origin) of `source`
    /// with annotations stored in `source` point space. Blur and pixelate sample
    /// the full source, so regions at the crop edge blur correctly.
    public static func render(_ document: AnnotationDocument, source: CGImage, scale: CGFloat, crop: CGRect?) -> CGImage? {
        let sourcePoints = CGRect(x: 0, y: 0, width: CGFloat(source.width) / scale, height: CGFloat(source.height) / scale)
        let cropPoints = (crop ?? sourcePoints).intersection(sourcePoints)
        let pixelRect = CGRect(
            x: cropPoints.minX * scale, y: cropPoints.minY * scale,
            width: cropPoints.width * scale, height: cropPoints.height * scale
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1,
              let base = source.cropping(to: pixelRect) else { return nil }

        let width = base.width
        let height = base.height
        let colorSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

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
        guard !document.annotations.isEmpty else { return context.makeImage() }

        // Flip to top-left origin, scale points → pixels, and move the crop origin to (0, 0).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -pixelRect.minX / scale, y: -pixelRect.minY / scale)

        for annotation in document.annotations {
            draw(annotation, in: context, imageScale: scale, source: source)
        }
        return context.makeImage()
    }

    /// Draws one annotation into a context already in top-left point space
    /// (the same point space as `source`).
    public static func draw(
        _ annotation: Annotation,
        in context: CGContext,
        imageScale: CGFloat,
        source: CGImage,
        cache: FilterCache? = nil
    ) {
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
            context.setLineWidth(highlighterWidth(for: style.lineWidth))
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
            drawFiltered(annotation.shape, rect, source: source, imageScale: imageScale, in: context, cache: cache) { image in
                image.clampedToExtent()
                    .applyingGaussianBlur(sigma: 12 * imageScale)
                    .cropped(to: image.extent)
            }

        case let .pixelate(rect):
            drawFiltered(annotation.shape, rect, source: source, imageScale: imageScale, in: context, cache: cache) { image in
                image.clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [
                        kCIInputScaleKey: 12 * imageScale,
                        kCIInputCenterKey: CIVector(x: image.extent.minX, y: image.extent.minY),
                    ])
                    .cropped(to: image.extent)
            }

        case let .counter(center, number):
            drawCounter(number, at: center, style: style, in: context)
        }
    }

    /// Marker stroke width for a given style width.
    public static func highlighterWidth(for lineWidth: Double) -> Double {
        max(lineWidth * 4, 14)
    }

    /// Numbered-step circle diameter for a given style width.
    public static func counterDiameter(for lineWidth: Double) -> Double {
        max(24, lineWidth * 7)
    }

    // MARK: - Helpers

    private static func strokePolyline(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: first) // a dot
        }
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
    }

    private static func drawText(_ string: String, at origin: CGPoint, fontSize: Double, color: RGBAColor, in context: CGContext) {
        let attributed = NSAttributedString(string: string, attributes: TextMetrics.attributes(fontSize: fontSize, color: color))
        let size = TextMetrics.size(of: string, fontSize: fontSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(with: CGRect(origin: origin, size: size), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCounter(_ number: Int, at center: CGPoint, style: AnnotationStyle, in context: CGContext) {
        let diameter = counterDiameter(for: style.lineWidth)
        let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.fillEllipse(in: circle)

        let label = "\(number)" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: diameter * 0.55, weight: .bold)
        // Dark digits on light fills (yellow, white) so the number stays readable.
        let luminance = 0.299 * style.color.red + 0.587 * style.color.green + 0.114 * style.color.blue
        let textColor: NSColor = luminance > 0.7 ? .black : .white
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = label.size(withAttributes: attributes)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Re-draws a region of the *original* capture through a Core Image filter.
    /// Always samples the source, so blur/pixelate can't be undone by stacking.
    private static func drawFiltered(
        _ shape: AnnotationShape,
        _ rect: CGRect,
        source: CGImage,
        imageScale: CGFloat,
        in context: CGContext,
        cache: FilterCache?,
        filter: (CIImage) -> CIImage
    ) {
        let rect = rect.standardized
        let pixelRect = CGRect(
            x: rect.minX * imageScale,
            y: rect.minY * imageScale,
            width: rect.width * imageScale,
            height: rect.height * imageScale
        ).integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return }

        let filtered: CGImage
        if let cached = cache?.image(for: shape) {
            filtered = cached
        } else {
            guard let region = source.cropping(to: pixelRect) else { return }
            let input = CIImage(cgImage: region)
            guard let output = ciContext.createCGImage(filter(input), from: input.extent) else { return }
            cache?.store(output, for: shape)
            filtered = output
        }

        // The context is flipped (top-left origin); flip locally so the image isn't upside down.
        let drawRect = CGRect(
            x: pixelRect.minX / imageScale, y: pixelRect.minY / imageScale,
            width: pixelRect.width / imageScale, height: pixelRect.height / imageScale
        )
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(filtered, in: CGRect(origin: .zero, size: drawRect.size))
        context.restoreGState()
    }
}

/// Caches blur/pixelate results for live editing, where the same regions are
/// redrawn on every mouse move. Keyed by shape, so moving or resizing a region
/// naturally misses the cache. Main-thread use only (owned by a canvas view).
public final class FilterCache {
    private var images: [AnnotationShape: CGImage] = [:]

    public init() {}

    func image(for shape: AnnotationShape) -> CGImage? { images[shape] }

    func store(_ image: CGImage, for shape: AnnotationShape) {
        if images.count > 64 { images.removeAll() }
        images[shape] = image
    }

    public func removeAll() { images.removeAll() }
}
