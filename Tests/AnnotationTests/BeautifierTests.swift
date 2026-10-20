import CoreGraphics
import Testing
@testable import Annotation

@Suite("Beautifier")
struct BeautifierTests {
    @Test func disabledIsPassThrough() {
        let (canvas, rect) = Beautifier.layout(imageSize: CGSize(width: 300, height: 200), options: BeautifyOptions(isEnabled: false))
        #expect(canvas == CGSize(width: 300, height: 200))
        #expect(rect.origin == .zero)
    }

    @Test func paddingSurroundsTheImage() {
        let options = BeautifyOptions(isEnabled: true, padding: 50)
        let (canvas, rect) = Beautifier.layout(imageSize: CGSize(width: 300, height: 200), options: options)
        #expect(canvas == CGSize(width: 400, height: 300))
        #expect(rect == CGRect(x: 50, y: 50, width: 300, height: 200))
    }

    @Test func aspectRatioGrowsTheShortSide() {
        let options = BeautifyOptions(isEnabled: true, padding: 0, aspect: .square)
        let (canvas, rect) = Beautifier.layout(imageSize: CGSize(width: 300, height: 100), options: options)
        #expect(canvas == CGSize(width: 300, height: 300))
        #expect(rect.midY == 150)

        let wide = BeautifyOptions(isEnabled: true, padding: 0, aspect: .wide16x9)
        let (wideCanvas, _) = Beautifier.layout(imageSize: CGSize(width: 100, height: 100), options: wide)
        #expect(abs(wideCanvas.width / wideCanvas.height - 16.0 / 9) < 0.02)
    }

    @Test func renderProducesCanvasSizedImage() throws {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        let image = try #require(context.makeImage())

        let options = BeautifyOptions(isEnabled: true, padding: 20, background: .solid(.blue), cornerRadius: 0, shadow: false)
        let output = try #require(Beautifier.render(image, scale: 2, options: options))
        #expect(output.width == 280 && output.height == 180)

        let corner = try #require(AnnotationRendererCropTests.pixel(output, x: 2, y: 2))
        #expect(corner.b > 200 && corner.r < 50)
        let center = try #require(AnnotationRendererCropTests.pixel(output, x: 140, y: 90))
        #expect(center.r > 200 && center.b < 50)
    }
}
