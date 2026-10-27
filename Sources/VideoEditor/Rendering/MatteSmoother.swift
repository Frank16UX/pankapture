import CoreImage
import Foundation
import Synchronization

/// Steadies the person mask from one frame to the next (PRD CAM-1, ADR-39).
///
/// Vision finds the person in each frame on its own, so the outline it
/// draws wobbles by a pixel or two between frames, which shows as a
/// flickering edge. Where the picture hasn't changed since the previous
/// frame, the new mask is averaged with the previous one; where something
/// moved, the new mask is taken as is, so the outline keeps up with the
/// person instead of trailing them.
///
/// One per compositor (the preview and each export have their own), so
/// frames arrive in order. Anything else (a seek, a cut, a frame out of
/// order, a different size) starts over from the new mask.
public final class MatteSmoother: Sendable {
    /// Weight of the new mask where nothing moved.
    static let stillWeight: Float = 0.25
    /// Luminance change (0…1) still counted as no movement: camera noise,
    /// and an outline shifting by less than a pixel (measured on recordings:
    /// lower, and high-contrast edges like hair against a wall always count
    /// as moving, so the edge that flickers most never gets steadied).
    static let noise: Float = 0.06
    /// How quickly a larger change counts as full movement.
    static let motionGain: Float = 6
    /// Movement this many mask pixels away still counts, so an outline
    /// that moved takes its new mask even where the old one was off by a
    /// little.
    static let motionReach = 2
    /// Frames further apart than this (source seconds) aren't neighbors.
    static let maximumGap = 0.25

    /// A frame's luminance and steadied mask, both `width` × `height`,
    /// 0…1, top row first.
    struct Frame: Sendable {
        var time: Double
        var width: Int
        var height: Int
        var luma: [Float]
        var mask: [Float]
    }

    private let previous = Mutex<Frame?>(nil)

    public init() {}

    /// The mask already worked out for this very frame (a paused preview
    /// drawn again with another setting), so Vision needn't run again.
    /// `luma` gives the frame's luminance at a size, only asked for when
    /// the time matches.
    func reusableMask(at time: Double, luma: (_ width: Int, _ height: Int) -> [Float]?) -> (mask: [Float], width: Int, height: Int)? {
        guard let last = previous.withLock({ $0 }), abs(last.time - time) < 1e-4,
              let current = luma(last.width, last.height), current.count == last.luma.count else { return nil }
        // Same time but another picture (mirrored, say) needs its own mask.
        var difference: Float = 0
        for index in current.indices { difference += abs(current[index] - last.luma[index]) }
        guard difference / Float(max(1, current.count)) < 0.002 else { return nil }
        return (last.mask, last.width, last.height)
    }

    /// `raw` steadied against the previous frame, which it then replaces.
    func smooth(_ raw: [Float], luma: [Float], width: Int, height: Int, time: Double) -> [Float] {
        let last = previous.withLock { $0 }
        var mask = raw
        if let last, last.width == width, last.height == height, time > last.time, time - last.time <= Self.maximumGap {
            mask = Self.blend(raw, luma: luma, onto: last)
        }
        previous.withLock { $0 = Frame(time: time, width: width, height: height, luma: luma, mask: mask) }
        return mask
    }

    /// `raw` averaged into the previous mask where the luminance stayed put,
    /// taken as is where it changed.
    static func blend(_ raw: [Float], luma: [Float], onto last: Frame) -> [Float] {
        let count = last.width * last.height
        guard raw.count == count, luma.count == count, last.luma.count == count, last.mask.count == count else { return raw }
        var change = [Float](repeating: 0, count: count)
        for index in 0..<count { change[index] = abs(luma[index] - last.luma[index]) }
        let moved = spread(change, width: last.width, height: last.height, reach: motionReach)
        var mask = raw
        for index in 0..<count {
            let motion = min(1, max(0, (moved[index] - noise) * motionGain))
            let weight = stillWeight + (1 - stillWeight) * motion
            mask[index] = weight * raw[index] + (1 - weight) * last.mask[index]
        }
        return mask
    }

    /// Each value replaced by the largest within `reach` pixels (a square).
    static func spread(_ values: [Float], width: Int, height: Int, reach: Int) -> [Float] {
        guard reach > 0, width > 0, height > 0, values.count == width * height else { return values }
        var rows = values
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var largest: Float = 0
                for nx in max(0, x - reach)...min(width - 1, x + reach) { largest = max(largest, values[row + nx]) }
                rows[row + x] = largest
            }
        }
        var spread = rows
        for y in 0..<height {
            for x in 0..<width {
                var largest: Float = 0
                for ny in max(0, y - reach)...min(height - 1, y + reach) { largest = max(largest, rows[ny * width + x]) }
                spread[y * width + x] = largest
            }
        }
        return spread
    }
}
