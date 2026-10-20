import CoreGraphics
import Foundation
import Testing
@testable import Capture

@Suite("ScrollStitcher")
struct ScrollStitcherTests {
    /// A tall "page" with distinct, deterministic stripes and blocks on every row.
    static func page(width: Int = 300, height: Int = 2000, header: Int = 0, footer: Int = 0) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SeededGenerator(seed: 42)
        for row in 0..<height {
            // Non-repeating rows, like real content (a periodic pattern would
            // legitimately match at several offsets).
            context.setFillColor(CGColor(red: CGFloat.random(in: 0...1, using: &generator),
                                         green: CGFloat.random(in: 0...1, using: &generator), blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: height - row - 1, width: width, height: 1))
            if row % 7 == 0 {
                let x = Int.random(in: 0..<(width - 40), using: &generator)
                context.setFillColor(CGColor(gray: CGFloat.random(in: 0...1, using: &generator), alpha: 1))
                context.fill(CGRect(x: x, y: height - row - 1, width: 40, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// The viewport at `offset`, optionally with sticky header/footer bars.
    static func frame(of page: CGImage, offset: Int, height: Int, header: Int = 0, footer: Int = 0) -> CGImage {
        let body = page.cropping(to: CGRect(x: 0, y: offset, width: page.width, height: height))!
        guard header > 0 || footer > 0 else { return body }
        let context = CGContext(data: nil, width: page.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(body, in: CGRect(x: 0, y: 0, width: page.width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: height - header, width: page.width, height: header)) // top bar
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: page.width, height: footer)) // bottom bar
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 20, y: height - header + 5, width: 80, height: 10)) // header detail
        return context.makeImage()!
    }

    @Test func stitchesASimpleScroll() throws {
        let page = Self.page()
        let stitcher = ScrollStitcher()
        #expect(stitcher.add(Self.frame(of: page, offset: 0, height: 600)) == .first)
        #expect(stitcher.add(Self.frame(of: page, offset: 250, height: 600)) == .appended(rows: 250))
        #expect(stitcher.add(Self.frame(of: page, offset: 250, height: 600)) == .unchanged)
        #expect(stitcher.add(Self.frame(of: page, offset: 610, height: 600)) == .appended(rows: 360))
        let image = try #require(stitcher.makeImage())
        #expect(image.height == 1210)
        #expect(image.width == page.width)
    }

    @Test func keepsStickyHeaderAndFooterOnce() throws {
        let page = Self.page()
        let stitcher = ScrollStitcher()
        stitcher.add(Self.frame(of: page, offset: 0, height: 600, header: 40, footer: 30))
        let second = stitcher.add(Self.frame(of: page, offset: 200, height: 600, header: 40, footer: 30))
        #expect(second == .appended(rows: 200))
        stitcher.add(Self.frame(of: page, offset: 450, height: 600, header: 40, footer: 30))
        let image = try #require(stitcher.makeImage())
        // 600 first frame + 200 + 250 new rows; footer counted once.
        #expect(image.height == 1050)
    }

    @Test func ignoresUpwardScrolls() {
        let page = Self.page()
        let stitcher = ScrollStitcher()
        stitcher.add(Self.frame(of: page, offset: 400, height: 500))
        let result = stitcher.add(Self.frame(of: page, offset: 300, height: 500))
        #expect(result == .unchanged || result == .unmatched)
        #expect(stitcher.height == 500)
    }
}

/// Deterministic RNG so test images never change.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
