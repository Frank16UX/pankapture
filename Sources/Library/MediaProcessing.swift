import Annotation
import AppCore
@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

enum MediaProcessingError: Error, Sendable {
    case encodingFailed
    case unreadableImage
    case noVideoTrack
}

/// Image/video work for the library. Every entry point is `nonisolated` and the
/// async ones are `@concurrent`, so they never run on the main actor.
enum MediaProcessing {
    /// Long side of library thumbnails, in pixels.
    static let thumbnailMaxPixelSize = 512

    // MARK: Encoding

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw MediaProcessingError.encodingFailed
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaProcessingError.encodingFailed }
        return data as Data
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: Thumbnails

    /// Downscales so the long side is at most `maxPixelSize` (never upscales).
    static func downscale(_ image: CGImage, maxPixelSize: Int = thumbnailMaxPixelSize) -> CGImage? {
        let longSide = max(image.width, image.height)
        guard longSide > maxPixelSize else { return image }
        let factor = Double(maxPixelSize) / Double(longSide)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Writes `thumbnail.heic` (falls back to JPEG if HEIC encoding is unavailable).
    /// Returns the file name and its size.
    static func writeThumbnail(of image: CGImage, toDirectory directory: URL) throws -> (fileName: String, bytes: Int64) {
        guard let small = downscale(image) else { throw MediaProcessingError.encodingFailed }
        let data: Data
        let fileName: String
        if let heic = try? encode(small, as: .heic, quality: 0.8) {
            data = heic
            fileName = LibraryFiles.thumbnailName
        } else {
            data = try encode(small, as: .jpeg, quality: 0.8)
            fileName = LibraryFiles.thumbnailFallbackName
        }
        // Remove a previous thumbnail of the other format (re-edits).
        for name in [LibraryFiles.thumbnailName, LibraryFiles.thumbnailFallbackName] where name != fileName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return (fileName, Int64(data.count))
    }

    // MARK: Flattening

    /// Original + annotations (+ crop), exactly as the editor exports it.
    static func flatten(original: CGImage, annotations: AnnotationDocument, scale: CGFloat, cropRect: CGRect?) -> CGImage? {
        let rendered = annotations.isEmpty
            ? original
            : AnnotationRenderer.render(annotations, onto: original, scale: scale)
        guard let rendered else { return nil }
        guard let cropRect else { return rendered }
        let pixelRect = CGRect(
            x: cropRect.minX * scale,
            y: cropRect.minY * scale,
            width: cropRect.width * scale,
            height: cropRect.height * scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        guard !pixelRect.isEmpty else { return rendered }
        return rendered.cropping(to: pixelRect) ?? rendered
    }

    // MARK: Text recognition (HI-3)

    /// Accurate on-device OCR with language correction and automatic language
    /// detection. Lines are joined with newlines, top to bottom.
    @concurrent
    static func recognizeText(in image: CGImage) async throws -> String {
        let signpostID = Log.signposter.makeSignpostID()
        let state = Log.signposter.beginInterval("library.ocr", id: signpostID)
        defer { Log.signposter.endInterval("library.ocr", state) }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    // MARK: Recordings and GIFs

    struct MediaInfo: Sendable {
        var pixelSize: CGSize
        var duration: TimeInterval
        var poster: CGImage?
    }

    @concurrent
    static func probe(fileURL: URL, kind: CaptureKind) async throws -> MediaInfo {
        if kind == .gif || UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .gif) == true {
            return try probeAnimatedImage(at: fileURL)
        }
        return try await probeVideo(at: fileURL)
    }

    static func probeAnimatedImage(at url: URL) throws -> MediaInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw MediaProcessingError.unreadableImage }

        var duration: TimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            duration += delay
        }
        return MediaInfo(pixelSize: CGSize(width: first.width, height: first.height), duration: duration, poster: first)
    }

    @concurrent
    static func probeVideo(at url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaProcessingError.noVideoTrack
        }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform).size
        let pixelSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let maxSide = CGFloat(thumbnailMaxPixelSize)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        // Screen recordings often start on a countdown or black frame; take the
        // poster a little way in.
        let posterSeconds = duration.isFinite ? min(1, duration * 0.1) : 0
        let poster = try? await generator.image(at: CMTime(seconds: posterSeconds, preferredTimescale: 600)).image

        return MediaInfo(pixelSize: pixelSize, duration: duration.isFinite ? duration : 0, poster: poster)
    }
}
