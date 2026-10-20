import CoreGraphics
import Foundation

/// An sRGB color stored in the edit project. Background colors are *content*
/// (they end up in the exported video), so they don't follow the app theme.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `0xRRGGBB`.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public static let white = RGBAColor(hex: 0xFFFFFF)
    public static let black = RGBAColor(hex: 0x000000)
}

/// Built-in two-stop linear gradients for the background (VE-6, mirrors ED-2).
public enum GradientPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case sunrise
    case ocean
    case meadow
    case lavender
    case ember
    case graphite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sunrise: "Sunrise"
        case .ocean: "Ocean"
        case .meadow: "Meadow"
        case .lavender: "Lavender"
        case .ember: "Ember"
        case .graphite: "Graphite"
        }
    }

    /// Start color (top-leading) and end color (bottom-trailing).
    public var colors: (start: RGBAColor, end: RGBAColor) {
        switch self {
        case .sunrise: (RGBAColor(hex: 0xFFB36B), RGBAColor(hex: 0xF0568C))
        case .ocean: (RGBAColor(hex: 0x4FACFE), RGBAColor(hex: 0x3A47D5))
        case .meadow: (RGBAColor(hex: 0x9BE15D), RGBAColor(hex: 0x00A37A))
        case .lavender: (RGBAColor(hex: 0xC3A6FF), RGBAColor(hex: 0x6A5AE0))
        case .ember: (RGBAColor(hex: 0xF9D423), RGBAColor(hex: 0xE65C00))
        case .graphite: (RGBAColor(hex: 0x5B6270), RGBAColor(hex: 0x1C1F26))
        }
    }
}

/// A user-made two-stop linear gradient (VE-6).
public struct CustomGradient: Codable, Hashable, Sendable {
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
        self.init(start: preset.colors.start, end: preset.colors.end)
    }

    public static let angleRange: ClosedRange<Double> = 0...360

    /// Start and end points of the gradient line in a `rect` with a
    /// **bottom-left** origin (Core Image), spanning the rect's corners.
    func endpoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        let radians = angle * .pi / 180
        // Screen direction (y down) → bottom-left space (y up).
        let direction = CGVector(dx: cos(radians), dy: -sin(radians))
        let halfLength = (abs(direction.dx) * rect.width + abs(direction.dy) * rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return (
            CGPoint(x: center.x - direction.dx * halfLength, y: center.y - direction.dy * halfLength),
            CGPoint(x: center.x + direction.dx * halfLength, y: center.y + direction.dy * halfLength)
        )
    }
}

/// Output frame shape. `original` keeps the source video's aspect ratio.
public enum OutputAspect: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case widescreen // 16:9
    case standard // 4:3
    case square // 1:1
    case portrait // 9:16

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .widescreen: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        case .portrait: "9:16"
        }
    }

    /// Width ÷ height, or `nil` for "same as the source".
    public var ratio: Double? {
        switch self {
        case .original: nil
        case .widescreen: 16.0 / 9.0
        case .standard: 4.0 / 3.0
        case .square: 1
        case .portrait: 9.0 / 16.0
        }
    }
}

/// The "beautify" frame around the video: fill, padding, rounded corners,
/// shadow, and output aspect ratio (VE-6).
public struct VideoBackground: Codable, Hashable, Sendable {
    public enum Fill: Codable, Hashable, Sendable {
        /// No background: padding, corners, and shadow are ignored.
        case none
        case solid(RGBAColor)
        case gradient(GradientPreset)
        case customGradient(CustomGradient)
        /// A picture, scaled to fill the canvas. The file is a private copy
        /// (`BackgroundLibrary`), so the project survives the original moving.
        case image(URL)
        /// A muted movie, scaled to fill the canvas and looped.
        case video(URL)

        /// The background movie, if the fill is one.
        public var videoURL: URL? {
            if case let .video(url) = self { return url }
            return nil
        }

        /// The two gradient colors and direction, for preset or custom gradients.
        public var gradient: CustomGradient? {
            switch self {
            case let .gradient(preset): CustomGradient(preset)
            case let .customGradient(gradient): gradient
            default: nil
            }
        }
    }

    public var fill: Fill
    /// Inset around the video as a fraction of the canvas' shorter side (0…0.3).
    public var padding: Double
    /// Corner radius as a fraction of the video's shorter side (0…0.15).
    public var cornerRadius: Double
    public var shadow: Bool
    public var aspect: OutputAspect

    public init(
        fill: Fill = .none,
        padding: Double = 0.08,
        cornerRadius: Double = 0.03,
        shadow: Bool = true,
        aspect: OutputAspect = .original
    ) {
        self.fill = fill
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.shadow = shadow
        self.aspect = aspect
    }

    public static let paddingRange: ClosedRange<Double> = 0...0.3
    public static let cornerRadiusRange: ClosedRange<Double> = 0...0.15

    public var hasFill: Bool { fill != .none }

    /// Padding/corners/shadow only apply when there's a fill to show them against.
    public var effectivePadding: Double { hasFill ? padding.clamped(to: Self.paddingRange) : 0 }
    public var effectiveCornerRadius: Double { hasFill ? cornerRadius.clamped(to: Self.cornerRadiusRange) : 0 }
    public var effectiveShadow: Bool { hasFill && shadow && effectivePadding > 0 }

    /// Whether frames differ from a plain (scaled) copy of the source.
    public var altersFrame: Bool { hasFill || aspect != .original }

    /// Solid swatches offered in the inspector.
    public static let solidPresets: [RGBAColor] = [
        .white,
        RGBAColor(hex: 0xE9EBEF),
        RGBAColor(hex: 0x2B2D33),
        .black,
        RGBAColor(hex: 0x2F6BFF),
        RGBAColor(hex: 0xFF6B3D),
    ]
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
