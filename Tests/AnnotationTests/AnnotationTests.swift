import CoreGraphics
import Foundation
import Testing
@testable import Annotation

@Suite("AnnotationDocument")
struct AnnotationDocumentTests {
    private func rectangle() -> Annotation {
        Annotation(shape: .rectangle(CGRect(x: 10, y: 10, width: 50, height: 30)))
    }

    @Test func undoRedoRestoresState() {
        var document = AnnotationDocument()
        let first = rectangle()
        document.add(first)
        document.add(rectangle())
        #expect(document.annotations.count == 2)

        document.undo()
        #expect(document.annotations == [first])
        #expect(document.canRedo)

        document.redo()
        #expect(document.annotations.count == 2)
    }

    @Test func newEditClearsRedo() {
        var document = AnnotationDocument()
        document.add(rectangle())
        document.undo()
        document.add(rectangle())
        #expect(!document.canRedo)
    }

    @Test func updateReplacesInPlace() {
        var document = AnnotationDocument()
        var annotation = rectangle()
        document.add(annotation)
        annotation.style.color = .blue
        document.update(annotation)
        #expect(document.annotations.first?.style.color == .blue)
        document.undo()
        #expect(document.annotations.first?.style.color == .red)
    }

    @Test func counterNumbersIncrement() {
        var document = AnnotationDocument()
        #expect(document.nextCounterNumber == 1)
        document.add(Annotation(shape: .counter(center: .zero, number: 1)))
        document.add(Annotation(shape: .counter(center: .zero, number: 2)))
        #expect(document.nextCounterNumber == 3)
    }

    @Test func undoLimitIsRespected() {
        var document = AnnotationDocument(undoLimit: 3)
        for _ in 0..<10 { document.add(rectangle()) }
        var undos = 0
        while document.canUndo { document.undo(); undos += 1 }
        #expect(undos == 3)
    }
}

@Suite("ArrowGeometry")
struct ArrowGeometryTests {
    @Test func headTipIsTheEndPoint() {
        let arrow = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)
        #expect(arrow.head.first == CGPoint(x: 100, y: 0))
    }

    @Test func shaftStopsBeforeTip() {
        let arrow = ArrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4)
        #expect(arrow.shaftEnd.x < 100)
        #expect(abs(arrow.shaftEnd.y) < 0.0001)
    }

    @Test func headNeverExceedsHalfTheLength() {
        let arrow = ArrowGeometry(from: .zero, to: CGPoint(x: 10, y: 0), lineWidth: 20)
        #expect(arrow.shaftEnd.x >= 5 - 0.0001)
    }
}

@Suite("AnnotationRenderer")
struct AnnotationRendererTests {
    private func whiteImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Reads one pixel as (r, g, b) using top-left coordinates.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    @Test func preservesPixelSizeAtRetinaScale() throws {
        let base = whiteImage(width: 200, height: 100)
        let output = try #require(AnnotationRenderer.render(AnnotationDocument(), onto: base, scale: 2))
        #expect(output.width == 200)
        #expect(output.height == 100)
    }

    @Test func drawsRectangleInTopLeftPointSpace() throws {
        var document = AnnotationDocument()
        document.add(Annotation(
            shape: .rectangle(CGRect(x: 10, y: 10, width: 30, height: 20)),
            style: AnnotationStyle(color: .red, lineWidth: 4)
        ))
        let base = whiteImage(width: 200, height: 100)
        let output = try #require(AnnotationRenderer.render(document, onto: base, scale: 2))

        // Top edge of the rectangle at y = 10pt → 20px; x = 25pt → 50px.
        let (r, g, b) = pixel(output, x: 50, y: 20)
        #expect(r > 200 && g < 120 && b < 120)

        // Inside the rectangle stays white.
        let (ir, ig, ib) = pixel(output, x: 50, y: 40)
        #expect(ir > 240 && ig > 240 && ib > 240)
    }
}
