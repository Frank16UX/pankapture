import CoreGraphics

/// The eight resize handles around a selection.
public enum SelectionHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Handle center for `rect` (top-left origin space).
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        default: false
        }
    }

    var movesHorizontally: Bool { self != .top && self != .bottom }
    var movesVertically: Bool { self != .left && self != .right }
}

/// Pure selection math (SC-3). Rectangles are in display-local points,
/// top-left origin.
public enum SelectionGeometry {
    /// Handle under `point`, if any. Corners win over edges.
    public static func handle(at point: CGPoint, in rect: CGRect, hitRadius: CGFloat = 6) -> SelectionHandle? {
        let ordered = SelectionHandle.allCases.filter(\.isCorner) + SelectionHandle.allCases.filter { !$0.isCorner }
        return ordered.first { handle in
            let p = handle.point(in: rect)
            return abs(p.x - point.x) <= hitRadius && abs(p.y - point.y) <= hitRadius
        }
    }

    /// Resizes `original` by dragging `handle` to `point`.
    /// - keepAspect: preserve the original aspect ratio (⇧).
    /// - fromCenter: resize symmetrically around the center (⌥).
    /// Dragging past the opposite edge flips the selection, like a fresh drag.
    public static func resize(
        _ original: CGRect,
        handle: SelectionHandle,
        to point: CGPoint,
        keepAspect: Bool,
        fromCenter: Bool,
        bounds: CGRect
    ) -> CGRect {
        let r = original.standardized
        let aspect = r.height > 0 ? r.width / r.height : 1
        let leftSide = handle == .left || handle == .topLeft || handle == .bottomLeft
        let topSide = handle == .top || handle == .topLeft || handle == .topRight

        let anchorX = fromCenter ? r.midX : (leftSide ? r.maxX : r.minX)
        let anchorY = fromCenter ? r.midY : (topSide ? r.maxY : r.minY)

        var width = r.width, height = r.height
        var signX: CGFloat = 1, signY: CGFloat = 1
        if handle.movesHorizontally {
            let dx = point.x - anchorX
            signX = dx < 0 ? -1 : 1
            width = abs(dx) * (fromCenter ? 2 : 1)
        }
        if handle.movesVertically {
            let dy = point.y - anchorY
            signY = dy < 0 ? -1 : 1
            height = abs(dy) * (fromCenter ? 2 : 1)
        }
        if keepAspect, aspect > 0 {
            if handle.isCorner {
                if width / max(height, 0.0001) > aspect { height = width / aspect } else { width = height * aspect }
            } else if handle.movesHorizontally {
                height = width / aspect
            } else {
                width = height * aspect
            }
        }

        func span(anchor: CGFloat, size: CGFloat, sign: CGFloat, moves: Bool, center: CGFloat) -> (CGFloat, CGFloat) {
            if fromCenter { return (anchor - size / 2, anchor + size / 2) }
            if moves { return sign > 0 ? (anchor, anchor + size) : (anchor - size, anchor) }
            return (center - size / 2, center + size / 2)
        }
        let (minX, maxX) = span(anchor: anchorX, size: width, sign: signX, moves: handle.movesHorizontally, center: r.midX)
        let (minY, maxY) = span(anchor: anchorY, size: height, sign: signY, moves: handle.movesVertically, center: r.midY)

        return clamp(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), to: bounds)
    }

    /// Moves `rect` by `delta`, keeping it entirely inside `bounds`.
    public static func move(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        var moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return moved
    }

    /// Clips `rect` to `bounds`; never returns a negative size.
    public static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(bounds)
        return clipped.isNull ? CGRect(origin: rect.origin, size: .zero) : clipped
    }

    /// Rounds to whole points so crops land on pixel boundaries at any scale.
    public static func integral(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
               width: rect.width.rounded(), height: rect.height.rounded())
    }
}

/// Where the floating toolbars go around a selection (DESIGN §7: tools bar on
/// the right edge, actions bar under the bottom-right; flip when out of room).
public struct ToolbarLayout: Equatable, Sendable {
    public var tools: CGRect?
    public var actions: CGRect
    public var badge: CGRect

    public static func compute(
        selection: CGRect,
        bounds: CGRect,
        toolsSize: CGSize?,
        actionsSize: CGSize,
        badgeSize: CGSize,
        gap: CGFloat = 8,
        margin: CGFloat = 6
    ) -> ToolbarLayout {
        let minX = bounds.minX + margin, maxX = bounds.maxX - margin
        let minY = bounds.minY + margin, maxY = bounds.maxY - margin

        func clampX(_ x: CGFloat, width: CGFloat) -> CGFloat { min(max(x, minX), max(minX, maxX - width)) }
        func clampY(_ y: CGFloat, height: CGFloat) -> CGFloat { min(max(y, minY), max(minY, maxY - height)) }

        // Tools bar: right outside → left outside → inside right edge.
        var tools: CGRect?
        if let size = toolsSize {
            let x: CGFloat
            if selection.maxX + gap + size.width <= maxX {
                x = selection.maxX + gap
            } else if selection.minX - gap - size.width >= minX {
                x = selection.minX - gap - size.width
            } else {
                x = clampX(selection.maxX - gap - size.width, width: size.width)
            }
            tools = CGRect(x: x, y: clampY(selection.minY, height: size.height), width: size.width, height: size.height)
        }

        // Actions bar: below → above → inside bottom; right-aligned to the selection.
        var actionsY: CGFloat
        if selection.maxY + gap + actionsSize.height <= maxY {
            actionsY = selection.maxY + gap
        } else if selection.minY - gap - actionsSize.height >= minY {
            actionsY = selection.minY - gap - actionsSize.height
        } else {
            actionsY = clampY(selection.maxY - gap - actionsSize.height, height: actionsSize.height)
        }
        var actions = CGRect(
            x: clampX(selection.maxX - actionsSize.width, width: actionsSize.width),
            y: actionsY, width: actionsSize.width, height: actionsSize.height
        )
        if let tools, tools.intersects(actions) {
            // Move the actions bar clear of the tools bar (below it if possible).
            if tools.maxY + gap + actionsSize.height <= maxY {
                actionsY = tools.maxY + gap
            } else {
                actionsY = clampY(tools.minY - gap - actionsSize.height, height: actionsSize.height)
            }
            actions.origin.y = actionsY
        }

        // Dimension badge: above the top-left corner, or inside it near the top edge.
        let badgeY = selection.minY - gap / 2 - badgeSize.height >= minY
            ? selection.minY - gap / 2 - badgeSize.height
            : selection.minY + gap / 2
        let badgeX = selection.minY - gap / 2 - badgeSize.height >= minY
            ? clampX(selection.minX, width: badgeSize.width)
            : clampX(selection.minX + gap / 2, width: badgeSize.width)
        let badge = CGRect(x: badgeX, y: badgeY, width: badgeSize.width, height: badgeSize.height)

        return ToolbarLayout(tools: tools, actions: actions, badge: badge)
    }
}
