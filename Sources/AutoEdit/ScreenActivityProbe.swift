import AppCore
import AVFoundation
import CoreGraphics
import Foundation

/// Measures what happens on screen during pauses (PRD AE-2 "screen action"):
/// recorded clicks, and how much of the picture changes between a few small
/// frames sampled across the pause. Only the pause spans are decoded.
public enum ScreenActivityProbe {
    /// Pauses shorter than this are never screen actions worth keeping.
    public static let minimumDuration = 0.6
    static let sampleWidth = 160
    /// A pixel "changed" when its gray level moved by more than this (0…255).
    static let pixelThreshold = 14

    public static func measure(asset: AVURLAsset, pauses: [TimeRange], clicks: [Double]) async -> [ScreenActivity] {
        let signpostID = Log.signposter.makeSignpostID()
        let interval = Log.signposter.beginInterval("screenActivity", id: signpostID)
        defer { Log.signposter.endInterval("screenActivity", interval) }

        var activity = pauses.map { pause in
            ScreenActivity(clicks: clicks.filter { pause.contains($0) }.count)
        }
        guard (try? await asset.loadTracks(withMediaType: .video).isEmpty) == false else { return activity }

        // Sample times per pause: both ends, plus the middle of longer ones.
        var requests: [(pause: Int, time: CMTime)] = []
        for (index, pause) in pauses.enumerated() where pause.duration >= minimumDuration {
            var times = [pause.start + 0.1, pause.end - 0.1]
            if pause.duration >= 1.5 { times.insert(pause.midpoint, at: 1) }
            requests += times.map { (index, CMTime(seconds: $0, preferredTimescale: 600)) }
        }
        guard !requests.isEmpty else { return activity }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: sampleWidth, height: sampleWidth)
        let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var frames: [Int64: [UInt8]] = [:]
        var size: (width: Int, height: Int)?
        for await result in generator.images(for: requests.map(\.time)) {
            if Task.isCancelled { break }
            guard let image = try? result.image else { continue }
            if size == nil { size = (image.width, image.height) }
            if let size, let pixels = grayscale(image, width: size.width, height: size.height) {
                frames[result.requestedTime.value] = pixels
            }
        }

        for (pauseIndex, group) in Dictionary(grouping: requests, by: \.pause) {
            let samples = group.compactMap { frames[$0.time.value] }
            guard samples.count >= 2 else {
                activity[pauseIndex].changedFraction = nil
                continue
            }
            var largest = 0.0
            for (a, b) in zip(samples, samples.dropFirst()) { largest = max(largest, changedFraction(a, b)) }
            activity[pauseIndex].changedFraction = largest
        }
        return activity
    }

    /// 8-bit gray pixels of `image` drawn at `width` × `height`.
    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Share of pixels whose gray level moved by more than `pixelThreshold`.
    static func changedFraction(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > pixelThreshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }
}
