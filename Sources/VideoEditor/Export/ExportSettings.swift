import CoreGraphics
import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp4
    case gif

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
}

/// MP4 output size, as a cap on the shorter side (never upscales).
public enum ExportResolution: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case hd1080
    case hd720

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .hd1080: "1080p"
        case .hd720: "720p"
        }
    }

    public var shortSideCap: Double? {
        switch self {
        case .original: nil
        case .hd1080: 1080
        case .hd720: 720
        }
    }
}

public enum ExportQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case high
    case medium
    case low

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }

    /// H.264 bits per pixel per frame. Screen content compresses well, so
    /// these are lower than typical camera-footage targets.
    public var bitsPerPixel: Double {
        switch self {
        case .high: 0.12
        case .medium: 0.07
        case .low: 0.035
        }
    }
}

public enum ExportFrameRate: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case fps30
    case fps60

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .fps30: "30 fps"
        case .fps60: "60 fps"
        }
    }

    /// Concrete frame rate; "original" rounds the source's rate into 1…60
    /// (30 when unknown, e.g. variable-rate screen recordings report 0).
    public func resolve(sourceFrameRate: Double) -> Int {
        switch self {
        case .fps30: return 30
        case .fps60: return 60
        case .original:
            guard sourceFrameRate.isFinite, sourceFrameRate >= 1 else { return 30 }
            return Int(sourceFrameRate.rounded()).clamped(to: 1...60)
        }
    }
}

/// GIF export options. Also used to convert direct-GIF recordings (REC-14).
public struct GIFOptions: Codable, Hashable, Sendable {
    /// Output width in pixels; `nil` keeps the composition's width.
    public var width: Int?
    public var fps: Int
    /// 0 = loop forever; otherwise the number of times the animation plays.
    public var loopCount: Int

    public init(width: Int? = 640, fps: Int = 15, loopCount: Int = 0) {
        self.width = width
        self.fps = fps
        self.loopCount = loopCount
    }

    public static let widthPresets: [Int?] = [480, 640, 800, nil]
    public static let fpsPresets: [Int] = [10, 15, 20, 25]
}

/// Everything the export sheet lets the user pick. Persisted as JSON under
/// `PreferenceKey.videoEditorExportSettings` so the last choice sticks.
public struct ExportSettings: Codable, Hashable, Sendable {
    public var format: ExportFormat
    public var resolution: ExportResolution
    public var quality: ExportQuality
    public var frameRate: ExportFrameRate
    public var gif: GIFOptions

    public init(
        format: ExportFormat = .mp4,
        resolution: ExportResolution = .hd1080,
        quality: ExportQuality = .high,
        frameRate: ExportFrameRate = .original,
        gif: GIFOptions = GIFOptions()
    ) {
        self.format = format
        self.resolution = resolution
        self.quality = quality
        self.frameRate = frameRate
        self.gif = gif
    }
}

/// Size estimates shown before export (VE-8).
///
/// The exporter sets an average bitrate (`videoBitrate`), but the hardware
/// encoder undershoots it a lot on simple screen content. So when the source's
/// own data rate is known, the estimate uses that rate scaled to the output
/// size (`contentBitrate`), capped by the target. GIF is a rougher heuristic.
public enum ExportEstimator {
    public static let audioBitrate: Double = 128_000
    /// Upper bound: compressed bytes per pixel per GIF frame for busy content.
    public static let gifBytesPerPixel: Double = 0.3
    /// GIF output is typically several times larger than H.264 of the same content.
    static let gifToH264Ratio: Double = 6
    /// Margin for zoom/background detail the source didn't have.
    static let contentMargin: Double = 1.15
    static let containerOverhead: Double = 1.01

    /// Target average bitrate for the encoder.
    public static func videoBitrate(renderSize: CGSize, fps: Int, quality: ExportQuality) -> Double {
        let raw = Double(renderSize.width * renderSize.height) * Double(fps) * quality.bitsPerPixel
        return max(250_000, raw)
    }

    /// What the content probably needs at `renderSize` and `fps`, from the
    /// source's data rate (bits/s) scaled by pixel count and by the square
    /// root of the frame-rate change (extra frames are mostly cheap P-frames).
    public static func contentBitrate(
        sourceBitrate: Double,
        sourceSize: CGSize,
        sourceFrameRate: Double = 0,
        renderSize: CGSize,
        fps: Int = 0
    ) -> Double? {
        let sourcePixels = Double(sourceSize.width * sourceSize.height)
        guard sourceBitrate > 0, sourcePixels > 0 else { return nil }
        var bitrate = sourceBitrate * Double(renderSize.width * renderSize.height) / sourcePixels * contentMargin
        if sourceFrameRate > 0, fps > 0 {
            bitrate *= (Double(fps) / sourceFrameRate).squareRoot()
        }
        return bitrate
    }

    public static func mp4Bytes(
        renderSize: CGSize,
        fps: Int,
        duration: Double,
        quality: ExportQuality,
        hasAudio: Bool,
        contentBitrate: Double? = nil
    ) -> Int64 {
        guard duration > 0 else { return 0 }
        var video = videoBitrate(renderSize: renderSize, fps: fps, quality: quality)
        if let contentBitrate { video = min(video, contentBitrate) }
        let bitrate = video + (hasAudio ? audioBitrate : 0)
        return Int64((bitrate * duration / 8 * containerOverhead).rounded())
    }

    public static func gifFrameCount(duration: Double, fps: Int) -> Int {
        guard duration > 0, fps > 0 else { return 0 }
        return max(1, Int((duration * Double(fps)).rounded(.up)))
    }

    public static func gifBytes(renderSize: CGSize, fps: Int, duration: Double, contentBitrate: Double? = nil) -> Int64 {
        let frames = Double(gifFrameCount(duration: duration, fps: fps))
        var bytes = Double(renderSize.width * renderSize.height) * frames * gifBytesPerPixel
        if let contentBitrate {
            bytes = min(bytes, contentBitrate * duration / 8 * gifToH264Ratio)
        }
        return Int64(bytes.rounded())
    }
}
