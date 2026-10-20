import CoreGraphics
import Testing
@testable import Overlay

@Suite("SelectionGeometry")
struct SelectionGeometryTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let rect = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func cornerHandleMovesOppositeCornerFixed() {
        let resized = SelectionGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 400, y: 260),
                                               keepAspect: false, fromCenter: false, bounds: bounds)
        #expect(resized == CGRect(x: 100, y: 100, width: 300, height: 160))
    }

    @Test func edgeHandleChangesOneDimension() {
        let resized = SelectionGeometry.resize(rect, handle: .left, to: CGPoint(x: 50, y: 999),
                                               keepAspect: false, fromCenter: false, bounds: bounds)
        #expect(resized == CGRect(x: 50, y: 100, width: 250, height: 100))
    }

    @Test func draggingPastTheAnchorFlips() {
        let resized = SelectionGeometry.resize(rect, handle: .right, to: CGPoint(x: 60, y: 150),
                                               keepAspect: false, fromCenter: false, bounds: bounds)
        #expect(resized == CGRect(x: 60, y: 100, width: 40, height: 100))
    }

    @Test func shiftKeepsAspectRatio() {
        let resized = SelectionGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 500, y: 150),
                                               keepAspect: true, fromCenter: false, bounds: bounds)
        #expect(resized.width / resized.height == 2)
        #expect(resized.origin == rect.origin)
        #expect(resized.width == 400)
    }

    @Test func optionResizesFromCenter() {
        let resized = SelectionGeometry.resize(rect, handle: .right, to: CGPoint(x: 350, y: 150),
                                               keepAspect: false, fromCenter: true, bounds: bounds)
        #expect(resized.midX == rect.midX)
        #expect(resized.width == 300)
        #expect(resized.height == rect.height)
    }

    @Test func resizeIsClampedToDisplay() {
        let resized = SelectionGeometry.resize(rect, handle: .bottomRight, to: CGPoint(x: 5000, y: 5000),
                                               keepAspect: false, fromCenter: false, bounds: bounds)
        #expect(resized == CGRect(x: 100, y: 100, width: 900, height: 700))
    }

    @Test func moveStaysInsideBounds() {
        let moved = SelectionGeometry.move(rect, by: CGVector(dx: -500, dy: 1000), within: bounds)
        #expect(moved == CGRect(x: 0, y: 700, width: 200, height: 100))
    }

    @Test func handleHitTestPrefersCorners() {
        #expect(SelectionGeometry.handle(at: CGPoint(x: 102, y: 98), in: rect) == .topLeft)
        #expect(SelectionGeometry.handle(at: CGPoint(x: 200, y: 101), in: rect) == .top)
        #expect(SelectionGeometry.handle(at: CGPoint(x: 200, y: 150), in: rect) == nil)
    }
}

@Suite("ToolbarLayout")
struct ToolbarLayoutTests {
    let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let tools = CGSize(width: 40, height: 420)
    let actions = CGSize(width: 220, height: 40)
    let badge = CGSize(width: 80, height: 20)

    @Test func prefersRightAndBelow() {
        let selection = CGRect(x: 200, y: 200, width: 400, height: 300)
        let layout = ToolbarLayout.compute(selection: selection, bounds: bounds, toolsSize: tools,
                                           actionsSize: actions, badgeSize: badge)
        #expect(layout.tools?.minX == selection.maxX + 8)
        #expect(layout.tools?.minY == selection.minY)
        #expect(layout.actions.minY == selection.maxY + 8)
        #expect(layout.actions.maxX == selection.maxX)
        #expect(layout.badge.maxY <= selection.minY)
    }

    @Test func flipsLeftAndAboveAtTheEdges() {
        let selection = CGRect(x: 1100, y: 500, width: 330, height: 390)
        let layout = ToolbarLayout.compute(selection: selection, bounds: bounds, toolsSize: tools,
                                           actionsSize: actions, badgeSize: badge)
        #expect(layout.tools!.maxX <= selection.minX)
        #expect(layout.actions.maxY <= selection.minY)
    }

    @Test func fullScreenSelectionPutsBarsInside() {
        let layout = ToolbarLayout.compute(selection: bounds, bounds: bounds, toolsSize: tools,
                                           actionsSize: actions, badgeSize: badge)
        #expect(bounds.contains(layout.tools!))
        #expect(bounds.contains(layout.actions))
        #expect(bounds.contains(layout.badge))
        #expect(!layout.tools!.intersects(layout.actions))
    }

    @Test func barsNeverOverlap() {
        // Small selection near the right edge: tools flip left, actions must avoid them.
        let selection = CGRect(x: 1380, y: 100, width: 50, height: 40)
        let layout = ToolbarLayout.compute(selection: selection, bounds: bounds, toolsSize: tools,
                                           actionsSize: actions, badgeSize: badge)
        #expect(!layout.tools!.intersects(layout.actions))
        #expect(bounds.contains(layout.actions))
    }
}
