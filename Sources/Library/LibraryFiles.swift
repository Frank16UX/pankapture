import Annotation
import AppCore
import Foundation

/// On-disk layout of the library (ARCHITECTURE §7):
///
/// ```
/// <root>/Library.store            SwiftData index
/// <root>/Captures/<uuid>/
///     original.png                un-annotated screenshot (screenshots only)
///     annotations.json            AnnotationDocument
///     thumbnail.heic              ≤ 512 px long side
/// ```
///
/// Recordings are not copied in (they can be huge); only their thumbnail lives here.
/// Pure value type with no isolation, so any actor can use it.
struct LibraryFiles: Sendable {
    static let originalImageName = "original.png"
    static let annotationsName = "annotations.json"
    static let thumbnailName = "thumbnail.heic"
    static let thumbnailFallbackName = "thumbnail.jpg"

    let root: URL

    var storeURL: URL { root.appendingPathComponent("Library.store") }
    var capturesDirectory: URL { root.appendingPathComponent("Captures", isDirectory: true) }

    func directory(for id: UUID) -> URL {
        capturesDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for id: UUID, fileName: String) -> URL {
        directory(for: id).appendingPathComponent(fileName)
    }

    @discardableResult
    func ensureDirectory(for id: UUID) throws -> URL {
        try AppPaths.ensure(directory(for: id))
    }

    func removeDirectory(for id: UUID) {
        let url = directory(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Log.library.error("Couldn't remove \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func writeAnnotations(_ document: AnnotationDocument, for id: UUID) throws -> Int64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url(for: id, fileName: Self.annotationsName), options: .atomic)
        return Int64(data.count)
    }

    func readAnnotations(for id: UUID, fileName: String?) -> AnnotationDocument {
        guard let fileName,
              let data = try? Data(contentsOf: url(for: id, fileName: fileName)),
              let document = try? JSONDecoder().decode(AnnotationDocument.self, from: data)
        else { return AnnotationDocument() }
        return document
    }

    /// Total bytes of every file in an item's directory.
    func byteSize(for id: UUID) -> Int64 {
        Self.byteSize(ofDirectory: directory(for: id))
    }

    /// Total bytes used by the library folder (store + captures).
    func totalByteSize() -> Int64 {
        Self.byteSize(ofDirectory: root)
    }

    static func byteSize(ofDirectory url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func fileSize(at url: URL) -> Int64 {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(size ?? 0)
    }

    /// A file moved to the Trash still resolves through its bookmark; treat it as gone.
    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes")
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) && !isInTrash(url)
    }
}
