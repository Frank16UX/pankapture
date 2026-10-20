import CoreGraphics
import Foundation

/// Tools available in the inline and full annotation editors.
public enum AnnotationTool: String, CaseIterable, Codable, Sendable, Identifiable {
    case pen
    case line
    case arrow
    case rectangle
    case ellipse
    case highlighter
    case text
    case blur
    case pixelate
    case counter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pen: "Pen"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .blur: "Blur"
        case .pixelate: "Pixelate"
        case .counter: "Numbered Step"
        }
    }

    /// SF Symbol shown in the tool palette.
    public var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .blur: "drop.halffull"
        case .pixelate: "squareshape.split.3x3"
        case .counter: "1.circle"
        }
    }

    /// Single-key shortcut while the editor has focus.
    public var keyEquivalent: Character {
        switch self {
        case .pen: "p"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .highlighter: "h"
        case .text: "t"
        case .blur: "b"
        case .pixelate: "x"
        case .counter: "n"
        }
    }
}

/// Theme-independent color. Annotation colors are content, not chrome, so they
/// never change with light/dark appearance.
public struct RGBAColor: Hashable, Codable, Sendable {
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

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public static let red = RGBAColor(red: 1.00, green: 0.23, blue: 0.19)
    public static let orange = RGBAColor(red: 1.00, green: 0.58, blue: 0.00)
    public static let yellow = RGBAColor(red: 1.00, green: 0.80, blue: 0.00)
    public static let green = RGBAColor(red: 0.20, green: 0.78, blue: 0.35)
    public static let blue = RGBAColor(red: 0.00, green: 0.48, blue: 1.00)
    public static let purple = RGBAColor(red: 0.69, green: 0.32, blue: 0.87)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)

    /// Swatches shown in the color picker, in order. Red is the default.
    public static let palette: [RGBAColor] = [.red, .orange, .yellow, .green, .blue, .purple, .black, .white]
}

public struct AnnotationStyle: Hashable, Codable, Sendable {
    public var color: RGBAColor
    public var lineWidth: Double

    public init(color: RGBAColor = .red, lineWidth: Double = 4) {
        self.color = color
        self.lineWidth = lineWidth
    }
}

/// Geometry of a single annotation, in the capture's point space
/// (top-left origin, 1 unit = 1 point of the original screen).
public enum AnnotationShape: Hashable, Codable, Sendable {
    case freehand(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case line(from: CGPoint, to: CGPoint)
    case arrow(from: CGPoint, to: CGPoint)
    case rectangle(CGRect)
    case ellipse(CGRect)
    case text(origin: CGPoint, string: String, fontSize: Double)
    case blur(CGRect)
    case pixelate(CGRect)
    case counter(center: CGPoint, number: Int)
}

public struct Annotation: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var shape: AnnotationShape
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle = AnnotationStyle()) {
        self.id = id
        self.shape = shape
        self.style = style
    }
}

/// Size presets shown in the editor (AN-3). One control drives stroke width,
/// text size, and numbered-step size so the toolbar stays compact.
public enum StrokeSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case small
    case medium
    case large

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public var lineWidth: Double {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 8
        }
    }

    public var fontSize: Double {
        switch self {
        case .small: 16
        case .medium: 24
        case .large: 36
        }
    }

    /// Closest preset for a stored line width (used when restyling).
    public init(lineWidth: Double) {
        self = Self.allCases.min { abs($0.lineWidth - lineWidth) < abs($1.lineWidth - lineWidth) } ?? .medium
    }
}

public extension AnnotationTool {
    /// Tools that draw by dragging a rectangle or line (as opposed to clicking).
    var isDragTool: Bool {
        switch self {
        case .text, .counter: false
        default: true
        }
    }
}
