import Annotation
import AppCore
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// File work for `CaptureLibrary`, kept off the main actor (`@concurrent`).
enum LibraryIO {
    /// Writes original + annotations + thumbnail for a new screenshot.
    @concurrent
    static func writeScreenshot(
        id: UUID,
        original: CGImage,
        scale: CGFloat,
        annotations: AnnotationDocument,
        cropRect: CGRect?,
        files: LibraryFiles
    ) async throws -> (originalBytes: Int64, thumbnailFileName: String?, libraryBytes: Int64) {
        let signpostID = Log.signposter.makeSignpostID()
        let state = Log.signposter.beginInterval("library.recordScreenshot", id: signpostID)
        defer { Log.signposter.endInterval("library.recordScreenshot", state) }

        let directory = try files.ensureDirectory(for: id)
        let png = try MediaProcessing.encode(original, as: .png)
        try png.write(to: directory.appendingPathComponent(LibraryFiles.originalImageName), options: .atomic)
        _ = try files.writeAnnotations(annotations, for: id)

        var thumbnailFileName: String?
        if let flattened = MediaProcessing.flatten(original: original, annotations: annotations, scale: scale, cropRect: cropRect) {
            thumbnailFileName = try? MediaProcessing.writeThumbnail(of: flattened, toDirectory: directory).fileName
        }
        return (Int64(png.count), thumbnailFileName, files.byteSize(for: id))
    }

    /// Rewrites annotations and the thumbnail after a re-edit.
    @concurrent
    static func rewriteAnnotations(
        id: UUID,
        originalURL: URL,
        scale: CGFloat,
        annotations: AnnotationDocument,
        cropRect: CGRect?,
        files: LibraryFiles
    ) async throws -> (thumbnailFileName: String?, libraryBytes: Int64) {
        let directory = try files.ensureDirectory(for: id)
        _ = try files.writeAnnotations(annotations, for: id)
        var thumbnailFileName: String?
        if let original = MediaProcessing.loadImage(at: originalURL),
           let flattened = MediaProcessing.flatten(original: original, annotations: annotations, scale: scale, cropRect: cropRect) {
            thumbnailFileName = try? MediaProcessing.writeThumbnail(of: flattened, toDirectory: directory).fileName
        }
        return (thumbnailFileName, files.byteSize(for: id))
    }

    /// Probes a recording/GIF and writes its poster-frame thumbnail.
    @concurrent
    static func ingestMedia(
        id: UUID,
        fileURL: URL,
        kind: CaptureKind,
        files: LibraryFiles
    ) async -> (info: MediaProcessing.MediaInfo?, thumbnailFileName: String?, libraryBytes: Int64, fileBytes: Int64) {
        let info: MediaProcessing.MediaInfo?
        do {
            info = try await MediaProcessing.probe(fileURL: fileURL, kind: kind)
        } catch {
            Log.library.error("Couldn't read \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            info = nil
        }
        var thumbnailFileName: String?
        if let poster = info?.poster, let directory = try? files.ensureDirectory(for: id) {
            thumbnailFileName = try? MediaProcessing.writeThumbnail(of: poster, toDirectory: directory).fileName
        }
        return (info, thumbnailFileName, files.byteSize(for: id), LibraryFiles.fileSize(at: fileURL))
    }

    @concurrent
    static func loadImage(at url: URL) async -> CGImage? {
        MediaProcessing.loadImage(at: url)
    }

    @concurrent
    static func loadScreenshot(snapshot: CaptureSnapshot, files: LibraryFiles) async -> LibraryScreenshot? {
        guard let originalURL = snapshot.originalURL,
              let original = MediaProcessing.loadImage(at: originalURL)
        else { return nil }
        let annotations = files.readAnnotations(for: snapshot.id, fileName: LibraryFiles.annotationsName)
        return LibraryScreenshot(
            id: snapshot.id,
            original: original,
            scale: snapshot.scale,
            annotations: annotations,
            cropRect: snapshot.cropRect,
            exportURL: snapshot.exportURL,
            sourceAppName: snapshot.sourceAppName
        )
    }

    /// The screenshot as the user would export it (annotations + crop applied).
    @concurrent
    static func flattenedImage(snapshot: CaptureSnapshot, files: LibraryFiles) async -> CGImage? {
        guard let screenshot = await loadScreenshot(snapshot: snapshot, files: files) else { return nil }
        return MediaProcessing.flatten(
            original: screenshot.original,
            annotations: screenshot.annotations,
            scale: screenshot.scale,
            cropRect: screenshot.cropRect
        )
    }

    /// Writes (or reuses) a flattened PNG in the temporary folder, for sharing,
    /// dragging, opening, and Quick Look of screenshots that have no current export.
    @concurrent
    static func temporaryFlattenedFile(snapshot: CaptureSnapshot, files: LibraryFiles) async -> URL? {
        let base = (snapshot.title as NSString).deletingPathExtension
        let name = (base.isEmpty ? "Capture" : base) + ".png"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pankapture Library", isDirectory: true)
            .appendingPathComponent("\(snapshot.id.uuidString)-\(Int(snapshot.editedAt.timeIntervalSince1970))", isDirectory: true)
        let url = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let image = await flattenedImage(snapshot: snapshot, files: files),
              let data = try? MediaProcessing.encode(image, as: .png)
        else { return nil }
        do {
            try AppPaths.ensure(folder)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.library.error("Temporary export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @concurrent
    static func moveToTrash(_ urls: [URL]) async {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                Log.library.error("Couldn't trash \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @concurrent
    static func totalByteSize(files: LibraryFiles) async -> Int64 {
        files.totalByteSize()
    }

    @concurrent
    static func writePNG(_ image: CGImage, to url: URL) async throws {
        try MediaProcessing.encode(image, as: .png).write(to: url, options: .atomic)
    }
}
