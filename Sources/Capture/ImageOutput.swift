import AppCore
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageOutputError: Error, Sendable {
    case encodingFailed
}

/// Encoding, saving, and clipboard handling for still captures.
public enum ImageOutput {
    public static func encode(_ image: CGImage, as format: ImageFormat, quality: Double = 0.9) throws -> Data {
        let type: UTType = switch format {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw ImageOutputError.encodingFailed
        }
        var options: [CFString: Any] = [:]
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
        namer: CaptureFileNamer = CaptureFileNamer(),
        date: Date = .now
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = namer.uniqueURL(in: directory, for: date, fileExtension: format.fileExtension)
        try encode(image, as: format).write(to: url, options: .atomic)
        Log.output.info("Saved \(url.lastPathComponent, privacy: .public)")
        return url
    }

    /// Puts the image on the pasteboard as PNG (lossless, widely accepted) with a
    /// TIFF fallback for older apps.
    @MainActor
    public static func copyToClipboard(_ image: CGImage) throws {
        let png = try encode(image, as: .png)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        pasteboard.writeObjects([item])
    }
}

public extension ImageOutput {
    /// Writes a PNG into a private temporary folder (for sharing and dragging),
    /// named like a regular capture so receivers see a meaningful file name.
    static func writeTemporary(_ image: CGImage, date: Date = .now) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Pankapture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = CaptureFileNamer().uniqueURL(in: directory, for: date, fileExtension: ImageFormat.png.fileExtension)
        try encode(image, as: .png).write(to: url, options: .atomic)
        return url
    }
}
