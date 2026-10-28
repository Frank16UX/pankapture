import AppCore
import CoreGraphics
import Foundation
import SwiftData

/// Plain values for a new item; built off the main actor, inserted by `LibraryStore`.
struct NewCaptureRecord: Sendable {
    var id: UUID
    var kind: CaptureKind
    var createdAt: Date
    var title: String
    var pixelSize: CGSize
    var scale: CGFloat
    var duration: TimeInterval
    var exportURL: URL?
    var originalFileName: String?
    var thumbnailFileName: String?
    var annotationsFileName: String?
    var annotationCount: Int
    var cropRect: CGRect?
    var sourceAppName: String?
    var libraryByteSize: Int64
    var fileByteSize: Int64
}

/// Owns the SwiftData context. Every read and write of `CaptureItem` happens
/// here, on this actor's serial executor; callers get `CaptureSnapshot` values.
///
/// Hand-written equivalent of `@ModelActor` so it can also hold the file layout.
actor LibraryStore: ModelActor {
    nonisolated let modelExecutor: any ModelExecutor
    nonisolated let modelContainer: ModelContainer
    let files: LibraryFiles

    init(modelContainer: ModelContainer, files: LibraryFiles) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
        self.modelContainer = modelContainer
        self.files = files
    }

    // MARK: Writes

    func insert(_ record: NewCaptureRecord) throws {
        let item = CaptureItem(id: record.id, kind: record.kind, createdAt: record.createdAt, title: record.title)
        item.pixelWidth = Int(record.pixelSize.width)
        item.pixelHeight = Int(record.pixelSize.height)
        item.scale = Double(record.scale)
        item.duration = record.duration
        item.originalFileName = record.originalFileName
        item.thumbnailFileName = record.thumbnailFileName
        item.annotationsFileName = record.annotationsFileName
        item.annotationCount = record.annotationCount
        item.cropRect = record.cropRect
        item.sourceAppName = record.sourceAppName
        item.libraryByteSize = record.libraryByteSize
        item.fileByteSize = record.fileByteSize
        setExport(record.exportURL, on: item)
        modelContext.insert(item)
        try modelContext.save()
    }

    func setOCR(id: UUID, text: String, status: OCRStatus) throws {
        guard let item = try item(id: id) else { return }
        item.ocrText = text
        item.ocrStatusRaw = status.rawValue
        try modelContext.save()
    }

    struct AnnotationUpdate: Sendable {
        var annotationCount: Int
        var annotationsFileName: String
        var thumbnailFileName: String?
        var cropRect: CGRect?
        var exportURL: URL?
        var editedAt: Date
        var libraryByteSize: Int64
    }

    func applyAnnotationUpdate(id: UUID, _ update: AnnotationUpdate) throws {
        guard let item = try item(id: id) else { return }
        item.annotationCount = update.annotationCount
        item.annotationsFileName = update.annotationsFileName
        if let thumbnail = update.thumbnailFileName { item.thumbnailFileName = thumbnail }
        item.cropRect = update.cropRect
        item.editedAt = update.editedAt
        item.libraryByteSize = update.libraryByteSize
        if let exportURL = update.exportURL {
            setExport(exportURL, on: item)
        } else {
            // Re-edited but not saved again: the old export no longer matches.
            item.isExportCurrent = item.exportURL == nil
        }
        try modelContext.save()
    }

    func setExportURL(id: UUID, url: URL) throws {
        guard let item = try item(id: id) else { return }
        setExport(url, on: item)
        try modelContext.save()
    }

    private func setExport(_ url: URL?, on item: CaptureItem) {
        item.exportURL = url
        item.isExportCurrent = true
        item.isExportMissing = false
        guard let url else {
            item.exportBookmark = nil
            return
        }
        item.title = url.lastPathComponent
        item.exportBookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let size = LibraryFiles.fileSize(at: url)
        if size > 0 { item.fileByteSize = size }
    }

    // MARK: Organizing (HI-7…HI-9)

    /// Runs a change on the store's executor (lets `CaptureLibrary` share error handling).
    func perform(_ change: @Sendable (isolated LibraryStore) throws -> Void) throws {
        try change(self)
    }

    /// Sets the library name; an empty name goes back to the file name.
    func setCustomName(id: UUID, name: String) throws {
        guard let item = try item(id: id) else { return }
        let name = LibraryTag.normalizedName(name) ?? ""
        item.customName = name == item.title ? "" : name
        try modelContext.save()
    }

    func addTag(_ tag: String, to ids: [UUID]) throws {
        guard let name = LibraryTag.normalizedName(tag), !ids.isEmpty else { return }
        // Reuse an existing tag's spelling so "design" doesn't become a second "Design".
        let canonical = try tagCounts().first { LibraryTag.isSame($0.name, name) }?.name ?? name
        for item in try items(ids: ids) where !item.tags.contains(where: { LibraryTag.isSame($0, canonical) }) {
            item.tags = Self.sortedTags(item.tags + [canonical])
        }
        try modelContext.save()
    }

    func removeTag(_ tag: String, from ids: [UUID]) throws {
        for item in try items(ids: ids) {
            item.tags = item.tags.filter { !LibraryTag.isSame($0, tag) }
        }
        try modelContext.save()
    }

    /// Renames a tag on every item; renaming onto an existing tag merges them.
    func renameTag(_ tag: String, to newName: String) throws {
        guard let name = LibraryTag.normalizedName(newName) else { return }
        let canonical = try tagCounts().first { LibraryTag.isSame($0.name, name) && !LibraryTag.isSame($0.name, tag) }?.name ?? name
        for item in try items(taggedWith: tag) {
            let others = item.tags.filter { !LibraryTag.isSame($0, tag) && !LibraryTag.isSame($0, canonical) }
            item.tags = Self.sortedTags(others + [canonical])
        }
        try modelContext.save()
    }

    func deleteTag(_ tag: String) throws {
        for item in try items(taggedWith: tag) {
            item.tags = item.tags.filter { !LibraryTag.isSame($0, tag) }
        }
        try modelContext.save()
    }

    /// Every tag in use with its item count, sorted by name.
    func tagCounts() throws -> [LibraryTag] {
        var descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.tagsKey != "" })
        descriptor.propertiesToFetch = [\.tagsKey]
        var counts: [String: Int] = [:]
        for item in try modelContext.fetch(descriptor) {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts.map { LibraryTag(name: $0.key, itemCount: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Folders sorted by name, with how many items each holds.
    func folders() throws -> [LibraryFolder] {
        try modelContext.fetch(FetchDescriptor<CaptureFolder>()).map { folder in
            let id: UUID? = folder.id
            let count = try modelContext.fetchCount(FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.folderID == id }))
            return LibraryFolder(id: folder.id, name: folder.name, itemCount: count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createFolder(id: UUID, name: String, createdAt: Date) throws {
        modelContext.insert(CaptureFolder(id: id, name: name, createdAt: createdAt))
        try modelContext.save()
    }

    func renameFolder(id: UUID, name: String) throws {
        guard let name = LibraryTag.normalizedName(name), let folder = try folder(id: id) else { return }
        folder.name = name
        try modelContext.save()
    }

    /// Deletes a folder; its items stay in the library, outside any folder.
    func deleteFolder(id: UUID) throws {
        guard let folder = try folder(id: id) else { return }
        let folderID: UUID? = id
        for item in try modelContext.fetch(FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.folderID == folderID })) {
            item.folderID = nil
        }
        modelContext.delete(folder)
        try modelContext.save()
    }

    /// Puts items in a folder, or takes them out of any with nil.
    func moveItems(_ ids: [UUID], toFolder folderID: UUID?) throws {
        if let folderID, try folder(id: folderID) == nil { return }
        for item in try items(ids: ids) {
            item.folderID = folderID
        }
        try modelContext.save()
    }

    private static func sortedTags(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Deletes index entries and their library folders. Returns the removed items.
    @discardableResult
    func delete(ids: [UUID]) throws -> [CaptureSnapshot] {
        guard !ids.isEmpty else { return [] }
        let items = try modelContext.fetch(FetchDescriptor<CaptureItem>(predicate: #Predicate { ids.contains($0.id) }))
        let snapshots = items.map { $0.snapshot(files: files) }
        for item in items {
            modelContext.delete(item)
        }
        try modelContext.save()
        for snapshot in snapshots {
            files.removeDirectory(for: snapshot.id)
        }
        return snapshots
    }

    // MARK: Reads

    func snapshot(id: UUID) throws -> CaptureSnapshot? {
        try item(id: id)?.snapshot(files: files)
    }

    func search(_ query: LibraryQuery) throws -> [CaptureSnapshot] {
        var descriptor = FetchDescriptor<CaptureItem>(predicate: Self.predicate(for: query), sortBy: Self.sortDescriptors(for: query.sort))
        if let limit = query.limit { descriptor.fetchLimit = limit }
        return try modelContext.fetch(descriptor).map { $0.snapshot(files: files) }
    }

    func retentionEntries() throws -> [RetentionPlanner.Entry] {
        try modelContext.fetch(FetchDescriptor<CaptureItem>()).map {
            RetentionPlanner.Entry(id: $0.id, createdAt: $0.createdAt, byteSize: $0.libraryByteSize)
        }
    }

    func count() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<CaptureItem>())
    }

    func allIDs() throws -> [UUID] {
        try modelContext.fetch(FetchDescriptor<CaptureItem>()).map(\.id)
    }

    /// Screenshots whose OCR never finished (e.g. the app quit mid-way).
    func pendingOCR() throws -> [(id: UUID, originalURL: URL)] {
        let pending = OCRStatus.pending.rawValue
        let descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.ocrStatusRaw == pending })
        return try modelContext.fetch(descriptor).compactMap { item in
            guard let name = item.originalFileName else { return nil }
            return (item.id, files.url(for: item.id, fileName: name))
        }
    }

    // MARK: File links

    /// Follows exported files that were moved or renamed (via their bookmark) and
    /// flags ones that were deleted or trashed. Returns true if anything changed.
    @discardableResult
    func refreshExportLinks() throws -> Bool {
        let descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.exportURL != nil })
        var changed = false
        for item in try modelContext.fetch(descriptor) {
            guard let current = item.exportURL else { continue }
            let resolved = resolve(item.exportBookmark) ?? (LibraryFiles.exists(current) ? current : nil)
            if let resolved, LibraryFiles.exists(resolved) {
                if resolved.standardizedFileURL != current.standardizedFileURL {
                    Log.library.info("Export moved: \(resolved.lastPathComponent, privacy: .public)")
                    item.exportURL = resolved
                    item.title = resolved.lastPathComponent
                    item.exportBookmark = try? resolved.bookmarkData()
                    changed = true
                }
                if item.isExportMissing {
                    item.isExportMissing = false
                    changed = true
                }
            } else if !item.isExportMissing {
                item.isExportMissing = true
                changed = true
            }
        }
        if changed { try modelContext.save() }
        return changed
    }

    private func resolve(_ bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }

    // MARK: Helpers

    private func item(id: UUID) throws -> CaptureItem? {
        var descriptor = FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func items(ids: [UUID]) throws -> [CaptureItem] {
        guard !ids.isEmpty else { return [] }
        return try modelContext.fetch(FetchDescriptor<CaptureItem>(predicate: #Predicate { ids.contains($0.id) }))
    }

    private func items(taggedWith tag: String) throws -> [CaptureItem] {
        let needle = TagCoding.needle(for: tag)
        return try modelContext.fetch(FetchDescriptor<CaptureItem>(predicate: #Predicate { $0.tagsKey.localizedStandardContains(needle) }))
    }

    private func folder(id: UUID) throws -> CaptureFolder? {
        var descriptor = FetchDescriptor<CaptureFolder>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    static func sortDescriptors(for sort: LibrarySort) -> [SortDescriptor<CaptureItem>] {
        switch sort {
        case .newest: [SortDescriptor(\.createdAt, order: .reverse)]
        case .oldest: [SortDescriptor(\.createdAt, order: .forward)]
        case .largest: [SortDescriptor(\.fileByteSize, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
        }
    }

    static func predicate(for query: LibraryQuery) -> Predicate<CaptureItem> {
        let anyKind = query.kind == nil
        let kind = query.kind?.rawValue ?? ""
        let start = query.dateRange?.lowerBound ?? .distantPast
        let end = query.dateRange?.upperBound ?? .distantFuture
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let anyText = text.isEmpty

        let anyFolder = query.folderID == nil
        let folderID = query.folderID
        let anyTag = query.tag == nil
        let tagNeedle = query.tag.map(TagCoding.needle(for:)) ?? ""

        let scope = #Predicate<CaptureItem> { item in
            (anyKind || item.kindRaw == kind) && item.createdAt >= start && item.createdAt < end
        }
        // Tag lookups are case- and accent-insensitive, like `LibraryTag.isSame`.
        let organized = #Predicate<CaptureItem> { item in
            (anyFolder || item.folderID == folderID) && (anyTag || item.tagsKey.localizedStandardContains(tagNeedle))
        }
        let matchesText = #Predicate<CaptureItem> { item in
            anyText
                || item.title.localizedStandardContains(text)
                || item.customName.localizedStandardContains(text)
                || item.tagsKey.localizedStandardContains(text)
                || item.ocrText.localizedStandardContains(text)
        }
        return #Predicate<CaptureItem> { item in
            scope.evaluate(item) && organized.evaluate(item) && matchesText.evaluate(item)
        }
    }
}
