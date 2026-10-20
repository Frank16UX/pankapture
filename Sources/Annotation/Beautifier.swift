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
    public static func render(_ image: CGImage, scale: CGFloat, options: BeautifyOptions) -> CGImage? {
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

        drawBackground(options.background, size: canvas, in: context)

        let radius = min(options.cornerRadius, min(imageRect.width, imageRect.height) / 2)
        let clip = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        if options.shadow {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 12), blur: 40,
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

    public static func drawBackground(_ background: BeautifyOptions.Background, size: CGSize, in context: CGContext) {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case .transparent:
            context.clear(rect)
        case let .solid(color):
            context.setFillColor(color.cgColor)
            context.fill(rect)
        case let .gradient(preset):
            let (start, end) = preset.colors
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: [start.cgColor, end.cgColor] as CFArray,
                                            locations: [0, 1]) else { return }
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
        }
    }
}
