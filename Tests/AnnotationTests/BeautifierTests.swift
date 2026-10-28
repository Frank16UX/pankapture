import CoreGraphics
import Foundation
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

    @Test func gradientAngleRunsInScreenDirection() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }
        let across = BeautifyOptions.Gradient(start: .red, end: .blue, angle: 0).endpoints(in: rect)
        #expect(near(across.start, CGPoint(x: 0, y: 50)) && near(across.end, CGPoint(x: 200, y: 50)))
        let down = BeautifyOptions.Gradient(start: .red, end: .blue, angle: 90).endpoints(in: rect)
        #expect(near(down.start, CGPoint(x: 100, y: 0)) && near(down.end, CGPoint(x: 100, y: 100)))
    }

    @Test func customGradientStartsAtTheTopAt90Degrees() throws {
        let gradient = BeautifyOptions.Gradient(start: .red, end: .blue, angle: 90)
        let options = BeautifyOptions(isEnabled: true, padding: 20, background: .customGradient(gradient), cornerRadius: 0, shadow: false)
        let output = try #require(Beautifier.render(Self.solidImage(width: 200, height: 100, color: .white), scale: 2, options: options))
        // `.red` has some blue in it (0.19); `.blue` has no red.
        let top = try #require(AnnotationRendererCropTests.pixel(output, x: 2, y: 2))
        #expect(top.r > 200 && top.b < 100)
        let bottom = try #require(AnnotationRendererCropTests.pixel(output, x: 2, y: output.height - 3))
        #expect(bottom.b > 200 && bottom.r < 50)
    }

    @Test func pictureBackgroundIsUpright() throws {
        // Canvas: (100 + 2·20) × (50 + 2·20) pt at 2× = 280 × 180 px. The
        // picture has that shape: red on top, blue below.
        let context = CGContext(data: nil, width: 140, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(RGBAColor.blue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 140, height: 45))
        context.setFillColor(RGBAColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 45, width: 140, height: 45))
        let picture = try #require(context.makeImage())

        let options = BeautifyOptions(isEnabled: true, padding: 20, background: .image(URL(fileURLWithPath: "/tmp/unused.png")),
                                      cornerRadius: 0, shadow: false)
        let output = try #require(Beautifier.render(Self.solidImage(width: 200, height: 100, color: .white), scale: 2,
                                                    options: options, backgroundImage: picture))
        let top = try #require(AnnotationRendererCropTests.pixel(output, x: 4, y: 4))
        #expect(top.r > 200 && top.b < 80)
        let bottom = try #require(AnnotationRendererCropTests.pixel(output, x: 4, y: output.height - 5))
        #expect(bottom.b > 200 && bottom.r < 80)
    }

    private static func solidImage(width: Int, height: Int, color: RGBAColor) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
