import Foundation
import SwiftData

/// The M6 schema as it shipped, frozen so stores written by it can migrate to
/// the current one (`LibraryMigrationPlan`). Never edit these models: the
/// migration finds a store's version by comparing them with what's on disk.
enum LibrarySchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [CaptureItem.self] }

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
        var exportBookmark: Data?
        var isExportCurrent: Bool
        var isExportMissing: Bool

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

        init(id: UUID, kindRaw: String, createdAt: Date, title: String) {
            self.id = id
            self.kindRaw = kindRaw
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
            self.ocrStatusRaw = OCRStatus.notApplicable.rawValue
            self.sourceAppName = nil
            self.libraryByteSize = 0
            self.fileByteSize = 0
        }
    }
}
