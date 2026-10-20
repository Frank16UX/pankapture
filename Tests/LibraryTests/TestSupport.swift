import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
@testable import Library

/// Adjustable clock for retention tests.
final class TestClock: Sendable {
    private let current: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = Mutex(date)
    }

    var now: Date { current.withLock { $0 } }

    func set(_ date: Date) { current.withLock { $0 = date } }
}

/// A library in a fresh temp folder with an in-memory store and private defaults.
@MainActor
struct LibraryFixture {
    let library: CaptureLibrary
    let root: URL
    let defaults: UserDefaults
    let clock: TestClock
    let scratch: URL

    init(recognizesText: Bool = false) throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PankaptureLibraryTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Library", isDirectory: true)
        scratch = base.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let suite = "PankaptureLibraryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let clock = TestClock()
        self.clock = clock
        library = try CaptureLibrary(
            configuration: LibraryConfiguration(
                rootDirectory: root,
                isStoredInMemoryOnly: true,
                recognizesText: recognizesText,
                now: { clock.now }
            ),
            defaults: defaults
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}

enum TestImages {
    static func solid(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
        let context = bitmapContext(width: width, height: height)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Large black text on white, for OCR.
    static func text(_ string: String, width: Int = 1400, height: Int = 240) -> CGImage {
        let context = bitmapContext(width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 80)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    private static func bitmapContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A 3-frame animated GIF, 0.1 s per frame.
    static func writeGIF(to url: URL, width: Int = 80, height: Int = 60) throws {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil)!
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary
        for gray in [0.2, 0.5, 0.8] {
            CGImageDestinationAddImage(destination, solid(width: width, height: height, gray: gray), frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// A tiny 1-second H.264 movie (10 frames at 10 fps).
    static func writeMovie(to url: URL, width: Int = 64, height: Int = 48) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 20), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 10, timescale: 10))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func pixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
