import CoreGraphics
import Foundation
import SwiftData

/// One capture in the history index (HI-1). Stored in SwiftData at
/// `AppPaths.library/Library.store`; files live in `Captures/<id>/`.
///
/// Enums are stored as raw strings so `#Predicate` can filter on them.
/// Only `LibraryStore` touches instances; the rest of the app uses `CaptureSnapshot`.
@Model
final class CaptureItem {
    #Index<CaptureItem>([\.createdAt], [\.kindRaw])

    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var createdAt: Date
    var editedAt: Date
    var title: String

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

    var kind: CaptureKind { CaptureKind(rawValue: kindRaw) ?? .screenshot }

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

/// Versioned schema so future model changes can migrate the store.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CaptureItem.self] }
}

enum LibraryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibrarySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
