import CoreGraphics
import Foundation

/// Background / beautify options (ED-2): put a capture on a padded background
/// with rounded corners and a soft shadow, optionally at a fixed aspect ratio.
public struct BeautifyOptions: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    /// Padding around the image, in points.
    public var padding: Double
    public var background: Background
    /// Corner radius applied to the image, in points.
    public var cornerRadius: Double
    public var shadow: Bool
    public var aspect: Aspect

    public init(isEnabled: Bool = false, padding: Double = 64, background: Background = .gradient(.ocean),
                cornerRadius: Double = 12, shadow: Bool = true, aspect: Aspect = .automatic) {
        self.isEnabled = isEnabled
        self.padding = padding
        self.background = background
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
    }

    public enum Background: Codable, Hashable, Sendable {
        case transparent
        case solid(RGBAColor)
        case gradient(GradientPreset)
        case customGradient(Gradient)
        /// A picture, scaled to fill the canvas. The file is a private copy
        /// (`BackgroundFiles`), so the options survive the original moving.
        case image(URL)

        /// The two gradient colors and direction, for preset or custom gradients.
        public var gradient: Gradient? {
            switch self {
            case let .gradient(preset): Gradient(preset)
            case let .customGradient(gradient): gradient
            default: nil
            }
        }

        /// The background picture, if the fill is one.
        public var imageURL: URL? {
            if case let .image(url) = self { return url }
            return nil
        }
    }

    /// Solid swatches offered in the editor, after Transparent.
    public static let solidPresets: [RGBAColor] = [
        .white,
        RGBAColor(red: 0.91, green: 0.92, blue: 0.94),
        RGBAColor(red: 0.17, green: 0.18, blue: 0.20),
        .black,
        RGBAColor(red: 0.18, green: 0.42, blue: 1.00),
        RGBAColor(red: 1.00, green: 0.42, blue: 0.24),
        RGBAColor(red: 0.20, green: 0.70, blue: 0.45),
    ]

    /// A user-made two-stop linear gradient.
    public struct Gradient: Codable, Hashable, Sendable {
        public var start: RGBAColor
        public var end: RGBAColor
        /// Direction in degrees as seen on screen: 0 runs left → right, 90 top →
        /// bottom. 45 matches the presets (top-leading → bottom-trailing).
        public var angle: Double

        public init(start: RGBAColor, end: RGBAColor, angle: Double = 45) {
            self.start = start
            self.end = end
            self.angle = angle
        }

        public init(_ preset: GradientPreset) {
            let (start, end) = preset.colors
            self.init(start: start, end: end)
        }

        public static let angleRange: ClosedRange<Double> = 0...360

        /// Start and end points of the gradient line in `rect` with a
        /// **top-left** origin, spanning the rect's corners.
        public func endpoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
            let radians = angle * .pi / 180
            let direction = CGVector(dx: cos(radians), dy: sin(radians))
            let halfLength = (abs(direction.dx) * rect.width + abs(direction.dy) * rect.height) / 2
            let center = CGPoint(x: rect.midX, y: rect.midY)
            return (
                CGPoint(x: center.x - direction.dx * halfLength, y: center.y - direction.dy * halfLength),
                CGPoint(x: center.x + direction.dx * halfLength, y: center.y + direction.dy * halfLength)
            )
        }
    }

    public enum GradientPreset: String, Codable, CaseIterable, Sendable, Identifiable {
        case ocean, sunset, forest, lavender, graphite, peach

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }

        /// Top-left → bottom-right colors.
        public var colors: (RGBAColor, RGBAColor) {
            switch self {
            case .ocean: (RGBAColor(red: 0.27, green: 0.55, blue: 0.98), RGBAColor(red: 0.47, green: 0.86, blue: 0.92))
            case .sunset: (RGBAColor(red: 0.98, green: 0.45, blue: 0.40), RGBAColor(red: 0.99, green: 0.76, blue: 0.40))
            case .forest: (RGBAColor(red: 0.16, green: 0.58, blue: 0.45), RGBAColor(red: 0.62, green: 0.86, blue: 0.48))
            case .lavender: (RGBAColor(red: 0.56, green: 0.45, blue: 0.96), RGBAColor(red: 0.93, green: 0.60, blue: 0.90))
            case .graphite: (RGBAColor(red: 0.18, green: 0.19, blue: 0.22), RGBAColor(red: 0.38, green: 0.40, blue: 0.45))
            case .peach: (RGBAColor(red: 1.00, green: 0.80, blue: 0.70), RGBAColor(red: 0.98, green: 0.62, blue: 0.68))
            }
        }
    }

    public enum Aspect: String, Codable, CaseIterable, Sendable, Identifiable {
        case automatic, wide16x9, standard4x3, square, portrait4x5, story9x16

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .automatic: "Auto"
            case .wide16x9: "16:9"
            case .standard4x3: "4:3"
            case .square: "1:1"
            case .portrait4x5: "4:5"
            case .story9x16: "9:16"
            }
        }

        /// Width ÷ height, or nil for "fit the image".
        public var ratio: Double? {
            switch self {
            case .automatic: nil
            case .wide16x9: 16.0 / 9
            case .standard4x3: 4.0 / 3
            case .square: 1
            case .portrait4x5: 4.0 / 5
            case .story9x16: 9.0 / 16
            }
        }
    }
}

public enum Beautifier {
    /// Canvas size and where the image sits on it, in points.
    public static func layout(imageSize: CGSize, options: BeautifyOptions) -> (canvas: CGSize, imageRect: CGRect) {
        guard options.isEnabled else {
            return (imageSize, CGRect(origin: .zero, size: imageSize))
        }
        var canvas = CGSize(width: imageSize.width + options.padding * 2, height: imageSize.height + options.padding * 2)
        if let ratio = options.aspect.ratio {
            // Grow the shorter dimension so the padded image fits the ratio.
            if canvas.width / canvas.height < ratio {
                canvas.width = canvas.height * ratio
            } else {
                canvas.height = canvas.width / ratio
            }
        }
        canvas = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let origin = CGPoint(x: ((canvas.width - imageSize.width) / 2).rounded(),
                             y: ((canvas.height - imageSize.height) / 2).rounded())
        return (canvas, CGRect(origin: origin, size: imageSize))
    }

    /// Composites `image` (pixels at `scale`) onto the background. Returns the
    /// image unchanged when beautify is off.
    /// - Parameter backgroundImage: the picture for an `.image` background,
    ///   loaded by the caller (this module does no file I/O).
    public static func render(_ image: CGImage, scale: CGFloat, options: BeautifyOptions,
                              backgroundImage: CGImage? = nil) -> CGImage? {
        guard options.isEnabled else { return image }
        let imageSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let (canvas, imageRect) = layout(imageSize: imageSize, options: options)

        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: Int(canvas.width * scale), height: Int(canvas.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Top-left origin, point units.
        context.translateBy(x: 0, y: canvas.height * scale)
        context.scaleBy(x: scale, y: -scale)

        drawBackground(options.background, size: canvas, image: backgroundImage, in: context)

        let radius = min(options.cornerRadius, min(imageRect.width, imageRect.height) / 2)
        let clip = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if options.shadow {
            context.saveGState()
            // Shadow offset/blur are in device pixels with y up, regardless of the CTM.
            context.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 40 * scale,
                              color: CGColor(gray: 0, alpha: 0.35))
            context.addPath(clip)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(clip)
        context.clip()
        // Undo the flip locally so the image isn't drawn upside down.
        context.translateBy(x: imageRect.minX, y: imageRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: imageRect.size))
        context.restoreGState()

        return context.makeImage()
    }

    /// Fills `size` with the background. `context` has a **top-left** origin
    /// (y down), like `render`'s.
    public static func drawBackground(_ background: BeautifyOptions.Background, size: CGSize,
                                      image: CGImage? = nil, in context: CGContext) {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case .transparent:
            context.clear(rect)
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case .gradient, .customGradient:
            guard let fill = background.gradient,
                  let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [fill.start.cgColor, fill.end.cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            let (start, end) = fill.endpoints(in: rect)
            context.drawLinearGradient(gradient, start: start, end: end,
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .image:
            // A picture that can't be read leaves the canvas clear.
            guard let image else {
                context.clear(rect)
                return
            }
            context.saveGState()
            context.clip(to: rect)
            let filled = aspectFill(CGSize(width: image.width, height: image.height), in: rect)
            // Undo the flip locally so the picture isn't drawn upside down.
            context.translateBy(x: filled.minX, y: filled.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: filled.size))
            context.restoreGState()
        }
    }

    /// `size` scaled to cover `rect`, centered.
    static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let filled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - filled.width / 2, y: rect.midY - filled.height / 2,
                      width: filled.width, height: filled.height)
    }
}
