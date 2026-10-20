import CoreGraphics
import Foundation
import Testing
@testable import Annotation

@Suite("Annotation geometry")
struct AnnotationGeometryTests {
    @Test func rectangleIsHitOnItsStrokeNotInside() {
        let box = Annotation(shape: .rectangle(CGRect(x: 0, y: 0, width: 100, height: 100)))
        #expect(box.hitTest(CGPoint(x: 1, y: 50)))
        #expect(!box.hitTest(CGPoint(x: 50, y: 50)))
        #expect(!box.hitTest(CGPoint(x: 150, y: 50)))
    }

    @Test func lineHitTestUsesDistanceToSegment() {
        let line = Annotation(shape: .line(from: .zero, to: CGPoint(x: 100, y: 0)))
        #expect(line.hitTest(CGPoint(x: 50, y: 5)))
        #expect(!line.hitTest(CGPoint(x: 50, y: 20)))
        #expect(!line.hitTest(CGPoint(x: 130, y: 0)))
    }

    @Test func ellipseIsHitNearItsOutline() {
        let ellipse = Annotation(shape: .ellipse(CGRect(x: 0, y: 0, width: 200, height: 100)))
        #expect(ellipse.hitTest(CGPoint(x: 100, y: 1)))
        #expect(!ellipse.hitTest(CGPoint(x: 100, y: 50)))
    }

    @Test func documentHitTestReturnsTopmost() {
        let bottom = Annotation(shape: .line(from: .zero, to: CGPoint(x: 100, y: 0)))
        let top = Annotation(shape: .line(from: CGPoint(x: 0, y: 2), to: CGPoint(x: 100, y: 2)))
        let document = AnnotationDocument(annotations: [bottom, top])
        #expect(document.hitTest(CGPoint(x: 50, y: 1))?.id == top.id)
    }

    @Test func translatingMovesEveryPoint() {
        let shape = AnnotationShape.arrow(from: CGPoint(x: 1, y: 2), to: CGPoint(x: 3, y: 4))
        #expect(shape.translated(by: CGVector(dx: 10, dy: -1)) == .arrow(from: CGPoint(x: 11, y: 1), to: CGPoint(x: 13, y: 3)))
        let document = AnnotationDocument(annotations: [Annotation(shape: .rectangle(CGRect(x: 5, y: 5, width: 1, height: 1)))])
        let moved = document.translated(by: CGVector(dx: -5, dy: -5))
        #expect(moved.annotations.first?.shape == .rectangle(CGRect(x: 0, y: 0, width: 1, height: 1)))
        #expect(!moved.canUndo)
    }

    @Test func snap45RoundsTheAngle() {
        let snapped = ShapeConstraints.snap45(from: .zero, to: CGPoint(x: 100, y: 10))
        #expect(abs(snapped.y) < 0.0001)
        let diagonal = ShapeConstraints.snap45(from: .zero, to: CGPoint(x: 100, y: 90))
        #expect(abs(diagonal.x - diagonal.y) < 0.0001)
    }

    @Test func constrainedRects() {
        let square = ShapeConstraints.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 0, y: 50), square: true, fromCenter: false)
        #expect(square == CGRect(x: -30, y: 10, width: 40, height: 40))
        let centered = ShapeConstraints.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 60, y: 70), square: false, fromCenter: true)
        #expect(centered == CGRect(x: 40, y: 30, width: 20, height: 40))
    }

    @Test func strokeSizeFromLineWidth() {
        #expect(StrokeSize(lineWidth: 3.5) == .medium)
        #expect(StrokeSize(lineWidth: 9) == .large)
    }
}

@Suite("AnnotationRenderer crop")
struct AnnotationRendererCropTests {
    private func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    @Test func cropRendersAnnotationsRelativeToTheCrop() throws {
        // 200×100 pt source at 2×; a filled counter at (60, 40) pt; crop starts at (50, 30) pt.
        let source = whiteImage(width: 400, height: 200)
        var style = AnnotationStyle(color: .red, lineWidth: 4)
        style.color = .red
        let document = AnnotationDocument(annotations: [Annotation(shape: .counter(center: CGPoint(x: 60, y: 40), number: 1), style: style)])
        let output = try #require(AnnotationRenderer.render(document, source: source, scale: 2,
                                                            crop: CGRect(x: 50, y: 30, width: 100, height: 50)))
        #expect(output.width == 200 && output.height == 100)

        // The counter center lands at (10, 10) pt = (20, 20) px in the crop; its fill
        // is red but the digit is white, so probe just off-center inside the circle.
        let probe = try #require(Self.pixel(output, x: 20 + 18, y: 20))
        #expect(probe.r > 200 && probe.g < 100)
        let corner = try #require(Self.pixel(output, x: 190, y: 90))
        #expect(corner.r > 240 && corner.g > 240)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (data[0], data[1], data[2])
    }
}
