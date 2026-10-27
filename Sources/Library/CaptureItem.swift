import CoreGraphics
import Foundation
import SwiftData

/// The current models. Always use these names; the schema enums hold the
/// versioned definitions.
typealias CaptureItem = LibrarySchemaV2.CaptureItem
typealias CaptureFolder = LibrarySchemaV2.CaptureFolder

/// The index schema since names, tags, and folders (HI-7…HI-9): V1 plus three
/// item attributes with defaults and the `CaptureFolder` model, so stores
/// migrate from V1 without a custom stage.
enum LibrarySchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [CaptureItem.self, CaptureFolder.self] }

    /// One capture in the history index (HI-1). Stored in SwiftData at
    /// `AppPaths.library/Library.store`; files live in `Captures/<id>/`.
    ///
    /// Enums are stored as raw strings, and tags as one delimited string
    /// (`TagCoding`), so `#Predicate` can filter on them. Only `LibraryStore`
    /// touches instances; the rest of the app uses `CaptureSnapshot`.
    @Model
    final class CaptureItem {
        #Index<CaptureItem>([\.createdAt], [\.kindRaw])

        @Attribute(.unique) var id: UUID
        var kindRaw: String
        var createdAt: Date
        var editedAt: Date
        /// File name (or the generated name of an unsaved capture).
        var title: String
        /// Name the user gave it in the library; empty when not renamed.
        var customName: String = ""
        /// `TagCoding.key(for:)` of the item's tags; empty when untagged.
        var tagsKey: String = ""
        /// The library folder it's in (`CaptureFolder.id`), if any.
        var folderID: UUID?

        var pixelWidth: Int
        var pixelHeight: Int
        var scale: Double
        var duration: Double

        var exportURL: URL?
        /// Plain (not security-scoped; the app isn't sandboxed) bookmark that follows
        /// the exported file when it's moved or renamed on the same volume.
        var exportBookmark: Data?
        var isExportCurrent: Bool
        var isExportMissing: Bool

        /// File names inside the item's library directory (nil when absent).
        var originalFileName: String?
        var thumbnailFileName: String?
        var annotationsFileName: String?
        var annotationCount: Int

        var hasCrop: Bool
        var cropX: Double
        var cropY: Double
        var cropWidth: Double
        var cropHeight: Double

        var ocrText: String
        var ocrStatusRaw: String
        var sourceAppName: String?

        var libraryByteSize: Int64
        var fileByteSize: Int64

        init(id: UUID, kind: CaptureKind, createdAt: Date, title: String) {
            self.id = id
            self.kindRaw = kind.rawValue
            self.createdAt = createdAt
            self.editedAt = createdAt
            self.title = title
            self.customName = ""
            self.tagsKey = ""
            self.folderID = nil
            self.pixelWidth = 0
            self.pixelHeight = 0
            self.scale = 1
            self.duration = 0
            self.exportURL = nil
            self.exportBookmark = nil
            self.isExportCurrent = true
            self.isExportMissing = false
            self.originalFileName = nil
            self.thumbnailFileName = nil
            self.annotationsFileName = nil
            self.annotationCount = 0
            self.hasCrop = false
            self.cropX = 0
            self.cropY = 0
            self.cropWidth = 0
            self.cropHeight = 0
            self.ocrText = ""
            self.ocrStatusRaw = (kind == .screenshot ? OCRStatus.pending : .notApplicable).rawValue
            self.sourceAppName = nil
            self.libraryByteSize = 0
            self.fileByteSize = 0
        }
    }

    /// A folder in the library window (HI-9). It only groups index entries;
    /// files on disk never move.
    @Model
    final class CaptureFolder {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date

        init(id: UUID, name: String, createdAt: Date) {
            self.id = id
            self.name = name
            self.createdAt = createdAt
        }
    }
}

extension CaptureItem {
    var kind: CaptureKind { CaptureKind(rawValue: kindRaw) ?? .screenshot }

    var tags: [String] {
        get { TagCoding.tags(from: tagsKey) }
        set { tagsKey = TagCoding.key(for: newValue) }
    }

    var cropRect: CGRect? {
        get { hasCrop ? CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight) : nil }
        set {
            hasCrop = newValue != nil
            let rect = newValue ?? .zero
            cropX = rect.minX
            cropY = rect.minY
            cropWidth = rect.width
            cropHeight = rect.height
        }
    }

    func snapshot(files: LibraryFiles) -> CaptureSnapshot {
        CaptureSnapshot(
            id: id,
            kind: kind,
            createdAt: createdAt,
            editedAt: editedAt,
            title: title,
            customName: customName,
            tags: tags,
            folderID: folderID,
            pixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            scale: scale,
            duration: kind.isVideoLike ? duration : nil,
            exportURL: exportURL,
            isExportCurrent: isExportCurrent,
            isExportMissing: isExportMissing,
            originalURL: originalFileName.map { files.url(for: id, fileName: $0) },
            thumbnailURL: thumbnailFileName.map { files.url(for: id, fileName: $0) },
            annotationCount: annotationCount,
            cropRect: cropRect,
            ocrText: ocrText,
            ocrStatus: OCRStatus(rawValue: ocrStatusRaw) ?? .failed,
            sourceAppName: sourceAppName,
            libraryByteSize: libraryByteSize,
            fileByteSize: fileByteSize
        )
    }
}

/// Tags are stored as one string, `"\nbug\ndesign\n"`, so `#Predicate` can
/// find an item's tag with a substring match (SwiftData can't query arrays of
/// values). Tag names never contain newlines (`LibraryTag.normalizedName`).
enum TagCoding {
    static func key(for tags: [String]) -> String {
        tags.isEmpty ? "" : "\n" + tags.joined(separator: "\n") + "\n"
    }

    static func tags(from key: String) -> [String] {
        key.split(separator: "\n").map(String.init)
    }

    /// The substring that marks `tag` in a key.
    static func needle(for tag: String) -> String {
        "\n\(tag)\n"
    }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self, LibrarySchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: LibrarySchemaV1.self, toVersion: LibrarySchemaV2.self)]
    }
}
