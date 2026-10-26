import CoreGraphics
import Foundation

public enum ExportFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case mp4
    case gif

    public var id: String { rawValue }
    public var title: String { rawValue.uppercased() }
    public var fileExtension: String { rawValue }
}

/// MP4 output size: the shorter side of the frame. Presets scale up as well
/// as down (a 4K export of a 1080p recording is 2160 px tall); `original`
/// keeps the canvas size.
public enum ExportResolution: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case uhd4K
    case qhd1440
    case hd1080
    case hd720

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .original: "Original"
        case .uhd4K: "4K"
        case .qhd1440: "1440p"
        case .hd1080: "1080p"
        case .hd720: "720p"
        }
    }

    /// Target shorter side in pixels, `nil` = canvas size.
    public var shortSide: Double? {
        switch self {
        case .original: nil
        case .uhd4K: 2160
        case .qhd1440: 1440
        case .hd1080: 1080
        case .hd720: 720
        }
    }
}

/// How the MP4 size is picked: a standard resolution, or a percentage of the
/// canvas (for Retina recordings, 50% is the size the screen showed).
public enum ExportSizeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case resolution
    case percentage

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// MP4 output size as a fraction of the canvas; never upscales.
public enum ExportScale: String, Codable, CaseIterable, Sendable, Identifiable {
    case original
    case percent75
    case percent50
    case percent33
    case percent25
    case percent20
    case percent10

    public var id: String { rawValue }

    public var title: String {
        self == .original ? "Original" : "\(Int((factor * 100).rounded()))%"
    }

    public var factor: Double {
        switch self {
        case .original: 1
        case .percent75: 0.75
        case .percent50: 0.5
        case .percent33: 0.33
        case .percent25: 0.25
        case .percent20: 0.2
        case .percent10: 0.1
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

/// H.264 encoder targets for an MP4 export: a quality preset's, or the
/// sharing profile's. Always H.264 (not HEVC), so the file plays inline in
/// every browser, chat app, and mail client.
public struct MP4Encoding: Sendable, Equatable {
    /// Bits per pixel per frame for the average-bitrate target.
    public var bitsPerPixel: Double
    /// Longest gap between keyframes, seconds. Screen recordings are mostly
    /// still, so keyframes are a large share of the file; spacing them out
    /// shrinks it at the cost of coarser seeking.
    public var keyFrameInterval: Double
    /// AAC bitrate of the mixed stereo track.
    public var audioBitrate: Double

    public init(bitsPerPixel: Double, keyFrameInterval: Double = 2, audioBitrate: Double = ExportEstimator.audioBitrate) {
        self.bitsPerPixel = bitsPerPixel
        self.keyFrameInterval = keyFrameInterval
        self.audioBitrate = audioBitrate
    }

    public init(quality: ExportQuality) {
        self.init(bitsPerPixel: quality.bitsPerPixel)
    }

    /// Small files that still keep text legible: between the Low and Medium
    /// targets, sparse keyframes, and voice-grade audio.
    public static let sharing = MP4Encoding(bitsPerPixel: 0.045, keyFrameInterval: 10, audioBitrate: 96_000)
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
    public var sizeMode: ExportSizeMode
    public var resolution: ExportResolution
    public var scale: ExportScale
    public var quality: ExportQuality
    public var frameRate: ExportFrameRate
    /// A small MP4 for chat and email: caps the size and frame rate, and
    /// encodes with `MP4Encoding.sharing` instead of the quality and frame
    /// rate picks.
    public var optimizeForSharing: Bool
    public var gif: GIFOptions

    /// Sharing exports' shorter-side ceiling: text stays legible and the
    /// file stays small.
    public static let sharingShortSideCap: Double = 1080
    /// Sharing exports' frame-rate ceiling; screen content rarely needs more.
    public static let sharingFrameRateCap = 30

    public init(
        format: ExportFormat = .mp4,
        sizeMode: ExportSizeMode = .resolution,
        resolution: ExportResolution = .hd1080,
        scale: ExportScale = .original,
        quality: ExportQuality = .high,
        frameRate: ExportFrameRate = .original,
        optimizeForSharing: Bool = false,
        gif: GIFOptions = GIFOptions()
    ) {
        self.format = format
        self.sizeMode = sizeMode
        self.resolution = resolution
        self.scale = scale
        self.quality = quality
        self.frameRate = frameRate
        self.optimizeForSharing = optimizeForSharing
        self.gif = gif
    }

    /// Settings saved before a field existed decode with its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportSettings()
        format = try container.decodeIfPresent(ExportFormat.self, forKey: .format) ?? defaults.format
        sizeMode = try container.decodeIfPresent(ExportSizeMode.self, forKey: .sizeMode) ?? defaults.sizeMode
        resolution = try container.decodeIfPresent(ExportResolution.self, forKey: .resolution) ?? defaults.resolution
        scale = try container.decodeIfPresent(ExportScale.self, forKey: .scale) ?? defaults.scale
        quality = try container.decodeIfPresent(ExportQuality.self, forKey: .quality) ?? defaults.quality
        frameRate = try container.decodeIfPresent(ExportFrameRate.self, forKey: .frameRate) ?? defaults.frameRate
        optimizeForSharing = try container.decodeIfPresent(Bool.self, forKey: .optimizeForSharing) ?? defaults.optimizeForSharing
        gif = try container.decodeIfPresent(GIFOptions.self, forKey: .gif) ?? defaults.gif
    }

    // MARK: MP4 output

    /// Exact shorter side (resolution mode), `nil` = canvas size.
    public var mp4ShortSide: Double? { sizeMode == .resolution ? resolution.shortSide : nil }
    /// Fraction of the canvas (percentage mode), `nil` = canvas size.
    public var mp4Scale: Double? { sizeMode == .percentage ? scale.factor : nil }
    /// Shorter-side ceiling applied after the size pick.
    public var mp4ShortSideCap: Double? { optimizeForSharing ? Self.sharingShortSideCap : nil }

    /// Sharing ignores the frame-rate pick: the source's rate, up to 30 fps.
    public func mp4FrameRate(sourceFrameRate: Double) -> Int {
        guard optimizeForSharing else { return frameRate.resolve(sourceFrameRate: sourceFrameRate) }
        return min(ExportFrameRate.original.resolve(sourceFrameRate: sourceFrameRate), Self.sharingFrameRateCap)
    }

    public var mp4Encoding: MP4Encoding {
        optimizeForSharing ? .sharing : MP4Encoding(quality: quality)
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
    public static func videoBitrate(renderSize: CGSize, fps: Int, bitsPerPixel: Double) -> Double {
        let raw = Double(renderSize.width * renderSize.height) * Double(fps) * bitsPerPixel
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
        encoding: MP4Encoding,
        hasAudio: Bool,
        contentBitrate: Double? = nil
    ) -> Int64 {
        guard duration > 0 else { return 0 }
        var video = videoBitrate(renderSize: renderSize, fps: fps, bitsPerPixel: encoding.bitsPerPixel)
        if let contentBitrate { video = min(video, contentBitrate) }
        let bitrate = video + (hasAudio ? encoding.audioBitrate : 0)
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
