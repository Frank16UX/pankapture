import AppCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageOutputError: Error, Sendable {
    case encodingFailed
}

/// Encoding, saving, and clipboard handling for still captures.
public enum ImageOutput {
    /// - Parameter scale: pixels per point; recorded as DPI (72 × scale) so Retina
    ///   captures open and paste at their on-screen size, like system screenshots.
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: Double = 0.9, scale: CGFloat = 1) throws -> Data {
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageOutputError.encodingFailed
        }
        var options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ]
        if format != .png { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageOutputError.encodingFailed }
        return data as Data
    }

    /// Writes the image into `directory` with a unique timestamped name.
    @discardableResult
    public static func write(
        _ image: CGImage,
        to directory: URL,
        format: ImageFormat,
        scale: CGFloat = 1,
        namer: CaptureFileNamer = CaptureFileNamer(),
        date: Date = .now
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = namer.uniqueURL(in: directory, for: date, fileExtension: format.fileExtension)
        try encode(image, as: format, scale: scale).write(to: url, options: .atomic)
        Log.output.info("Saved \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Puts the image on the pasteboard as PNG (lossless, widely accepted) with a
    /// TIFF fallback for older apps.
    @MainActor
    public static func copyToClipboard(_ image: CGImage, scale: CGFloat = 1) throws {
        let png = try encode(image, as: .png, scale: scale)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        if let tiff = rep.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }
}

public extension ImageOutput {
    /// Writes a PNG into a private temporary folder (for sharing and dragging),
    /// named like a regular capture so receivers see a meaningful file name.
    static func writeTemporary(_ image: CGImage, scale: CGFloat = 1, date: Date = .now) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pankapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = CaptureFileNamer().uniqueURL(in: directory, for: date, fileExtension: ImageFormat.png.fileExtension)
        try encode(image, as: .png, scale: scale).write(to: url, options: .atomic)
        return url
    }
}
