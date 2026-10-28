import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import VideoEditor

/// The camera person's outline steadied over time (PRD CAM-1, ADR-39).
@Suite("Camera matte over time")
struct MatteSmootherTests {
    private let width = 32, height = 8

    private func filled(_ value: Float) -> [Float] {
        [Float](repeating: value, count: width * height)
    }

    /// A mask covering columns left of `edge`.
    private func mask(edge: Int) -> [Float] {
        (0..<(width * height)).map { $0 % width < edge ? 1 : 0 }
    }

    @Test func stillPartsAverageAndMovingPartsFollow() {
        let smoother = MatteSmoother()
        let still = filled(0.5)
        _ = smoother.smooth(filled(0), luma: still, width: width, height: height, time: 1)
        // The right half of the picture changed; the left didn't.
        var moved = still
        for index in moved.indices where index % width >= 16 { moved[index] = 0.9 }
        let next = smoother.smooth(filled(1), luma: moved, width: width, height: height, time: 1 + 1 / 30)
        #expect(abs(next[3 * width + 2] - MatteSmoother.stillWeight) < 1e-6)
        #expect(next[3 * width + 30] == 1)
        // Movement reaches a little past where the picture changed.
        #expect(next[3 * width + 16 - MatteSmoother.motionReach] == 1)
        #expect(next[3 * width + 16 - MatteSmoother.motionReach - 1] < 1)
    }

    /// A seek, a cut, a frame out of order, or another size starts over.
    @Test func aJumpStartsOverFromTheNewMask() {
        let smoother = MatteSmoother()
        let luma = filled(0.5)
        #expect(smoother.smooth(filled(0), luma: luma, width: width, height: height, time: 1) == filled(0))
        #expect(smoother.smooth(filled(1), luma: luma, width: width, height: height, time: 2) == filled(1))
        #expect(smoother.smooth(filled(0), luma: luma, width: width, height: height, time: 1.9) == filled(0))
        let wide = [Float](repeating: 1, count: 64 * height)
        #expect(smoother.smooth(wide, luma: [Float](repeating: 0.5, count: 64 * height), width: 64, height: height, time: 1.93) == wide)
    }

    /// An outline that wobbles from frame to frame over a still picture
    /// (what Vision gives) changes much less once steadied.
    @Test func aWobblingEdgeSettles() {
        let smoother = MatteSmoother()
        let luma = filled(0.5)
        var raw: [[Float]] = [], steadied: [[Float]] = []
        for frame in 0..<30 {
            let wobble = mask(edge: frame.isMultiple(of: 2) ? 14 : 17)
            raw.append(wobble)
            steadied.append(smoother.smooth(wobble, luma: luma, width: width, height: height, time: Double(frame) / 30))
        }
        func change(_ frames: [[Float]]) -> Float {
            var total: Float = 0
            for (previous, next) in zip(frames.dropFirst(10), frames.dropFirst(11)) {
                for (a, b) in zip(previous, next) { total += abs(a - b) }
            }
            return total
        }
        #expect(change(steadied) < change(raw) * 0.4)
    }

    /// A paused frame drawn again reuses its mask; the same time with
    /// another picture (mirrored, say) doesn't.
    @Test func aPausedFrameReusesItsMask() throws {
        let smoother = MatteSmoother()
        let luma = filled(0.5)
        let first = smoother.smooth(mask(edge: 10), luma: luma, width: width, height: height, time: 3)
        var asked: (Int, Int)?
        let reused = try #require(smoother.reusableMask(at: 3) { w, h in asked = (w, h); return luma })
        #expect(reused.mask == first && reused.width == width && reused.height == height)
        #expect(asked?.0 == width && asked?.1 == height)
        let other = filled(0.8)
        #expect(smoother.reusableMask(at: 3) { _, _ in other } == nil)
        #expect(smoother.reusableMask(at: 3.1) { _, _ in luma } == nil)
    }

    /// Luminance and Vision's buffer both start at the top row, like the mask
    /// image made from them.
    @Test func rowsStartAtTheTop() throws {
        // Core Image's y goes up: the top half is white.
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 40, width: 64, height: 40))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 80)))
        let luma = try #require(CameraMatte.luminance(of: image, width: 8, height: 8))
        #expect(luma[0] > 0.9 && luma[8 * 7] < 0.1)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_OneComponent8, nil, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        for x in 0..<4 {
            base[x] = 255
            base[rowBytes + x] = 0
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        #expect(CameraMatte.values(of: pixels) == [1, 1, 1, 1, 0, 0, 0, 0])

        // The mask image keeps the first row on top.
        let maskImage = CameraMatte.maskImage([1, 1, 1, 1, 0, 0, 0, 0], width: 4, height: 2)
        var rendered = [UInt8](repeating: 0, count: 4 * 2 * 4)
        CIContext(options: [.workingColorSpace: NSNull()]).render(maskImage, toBitmap: &rendered, rowBytes: 16,
                                                                  bounds: maskImage.extent, format: .RGBA8, colorSpace: nil)
        #expect(rendered[0] == 255 && rendered[16] == 0)
    }
}
