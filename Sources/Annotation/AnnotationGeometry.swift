import AppKit
import CoreGraphics
import Foundation

/// Bounds, hit-testing, and translation for annotations. All values are in the
/// same point space the annotation is stored in.
public extension AnnotationShape {
    /// Tight bounds of the geometry, not including stroke width.
    var geometryBounds: CGRect {
        switch self {
        case let .freehand(points), let .highlighter(points):
            return Self.bounds(of: points)
        case let .line(from, to), let .arrow(from, to):
            return Self.bounds(of: [from, to])
        case let .rectangle(rect), let .ellipse(rect), let .blur(rect), let .pixelate(rect):
            return rect.standardized
        case let .text(origin, string, fontSize):
            return CGRect(origin: origin, size: TextMetrics.size(of: string, fontSize: fontSize))
        case let .counter(center, _):
            return CGRect(origin: center, size: .zero)
        }
    }

    /// Returns the same shape moved by `offset`.
    func translated(by offset: CGVector) -> AnnotationShape {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + offset.dx, y: p.y + offset.dy) }
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: offset.dx, dy: offset.dy) }
        switch self {
        case let .freehand(points): return .freehand(points: points.map(move))
        case let .highlighter(points): return .highlighter(points: points.map(move))
        case let .line(from, to): return .line(from: move(from), to: move(to))
        case let .arrow(from, to): return .arrow(from: move(from), to: move(to))
        case let .rectangle(rect): return .rectangle(move(rect))
        case let .ellipse(rect): return .ellipse(move(rect))
        case let .text(origin, string, fontSize): return .text(origin: move(origin), string: string, fontSize: fontSize)
        case let .blur(rect): return .blur(move(rect))
        case let .pixelate(rect): return .pixelate(move(rect))
        case let .counter(center, number): return .counter(center: move(center), number: number)
        }
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public extension Annotation {
    /// Bounds including stroke width and decorations: what needs redrawing.
    var visualBounds: CGRect {
        let width = style.lineWidth
        switch shape {
        case .highlighter:
            let grow = AnnotationRenderer.highlighterWidth(for: width)
            return shape.geometryBounds.insetBy(dx: -grow, dy: -grow)
        case .arrow:
            let grow = max(12, width * 4)
            return shape.geometryBounds.insetBy(dx: -grow, dy: -grow)
        case let .counter(center, _):
            let d = AnnotationRenderer.counterDiameter(for: width)
            return CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
        case .text, .blur, .pixelate:
            return shape.geometryBounds
        default:
            return shape.geometryBounds.insetBy(dx: -width, dy: -width)
        }
    }

    /// Whether `point` touches the annotation. Strokes are hit near the line,
    /// not inside closed shapes, so you can still draw inside a rectangle.
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Bool {
        let slop = tolerance + style.lineWidth / 2
        switch shape {
        case let .freehand(points):
            return Self.distance(from: point, toPolyline: points) <= slop
        case let .highlighter(points):
            return Self.distance(from: point, toPolyline: points)
                <= tolerance + AnnotationRenderer.highlighterWidth(for: style.lineWidth) / 2
        case let .line(from, to), let .arrow(from, to):
            return Self.distance(from: point, toSegment: from, to) <= slop
        case let .rectangle(rect):
            let r = rect.standardized
            return r.insetBy(dx: -slop, dy: -slop).contains(point) && !r.insetBy(dx: slop, dy: slop).contains(point)
        case let .ellipse(rect):
            return Self.isNearEllipse(point, rect.standardized, slop: slop)
        case .text, .blur, .pixelate, .counter:
            return visualBounds.insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(point)
        }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func distance(from p: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = CGFloat.infinity
        for (a, b) in zip(points, points.dropFirst()) {
            best = min(best, distance(from: p, toSegment: a, b))
        }
        return best
    }

    private static func isNearEllipse(_ p: CGPoint, _ rect: CGRect, slop: CGFloat) -> Bool {
        let rx = rect.width / 2, ry = rect.height / 2
        guard rx > 0, ry > 0 else { return rect.insetBy(dx: -slop, dy: -slop).contains(p) }
        // Inside the ellipse grown by `slop`, outside the one shrunk by it.
        func value(_ grow: CGFloat) -> CGFloat {
            let ax = max(rx + grow, 0.001), ay = max(ry + grow, 0.001)
            return pow((p.x - rect.midX) / ax, 2) + pow((p.y - rect.midY) / ay, 2)
        }
        return value(slop) <= 1 && value(-slop) >= 1
    }
}

public extension AnnotationDocument {
    /// Topmost annotation under `point` (last drawn wins).
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 6) -> Annotation? {
        annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    /// The same annotations moved by `offset`, without undo history
    /// (used to convert display-local → capture-local coordinates).
    func translated(by offset: CGVector) -> AnnotationDocument {
        AnnotationDocument(annotations: annotations.map {
            Annotation(id: $0.id, shape: $0.shape.translated(by: offset), style: $0.style)
        })
    }
}

/// Text measurement shared by the renderer, the inline text editor, and
/// hit-testing, so typed and rendered text line up exactly.
public enum TextMetrics {
    public static func font(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    public static func attributes(fontSize: Double, color: RGBAColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: NSColor(cgColor: color.cgColor) ?? .red]
    }

    public static func size(of string: String, fontSize: Double) -> CGSize {
        let text = string.isEmpty ? " " : string
        let measured = NSAttributedString(string: text, attributes: [.font: font(size: fontSize)])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }
}
