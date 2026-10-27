import Annotation
import AppCore
import CoreGraphics
import Foundation
import Observation
import SwiftData

/// Where the library keeps its files and how it behaves. Tests inject a temp
/// folder, an in-memory store, and a fixed clock.
public struct LibraryConfiguration: Sendable {
    public var rootDirectory: URL
    public var isStoredInMemoryOnly: Bool
    /// Run on-device OCR on new screenshots (HI-3).
    public var recognizesText: Bool
    public var now: @Sendable () -> Date

    public init(
        rootDirectory: URL = AppPaths.library,
        isStoredInMemoryOnly: Bool = false,
        recognizesText: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.rootDirectory = rootDirectory
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.recognizesText = recognizesText
        self.now = now
    }

    /// `~/Library/Application Support/Pankapture/Library`.
    public static var standard: LibraryConfiguration { LibraryConfiguration() }
}

/// Capture history (M6): the app-facing entry point.
///
/// Main-actor facade over a background `LibraryStore` (SwiftData) plus
/// `@concurrent` file/OCR work. Observable: `revision` bumps on every change and
/// `recentCaptures` feeds the menu bar submenu (HI-6).
@MainActor
@Observable
public final class CaptureLibrary {
    /// How many items `recentCaptures` holds.
    public static let recentLimit = 10

    public let configuration: LibraryConfiguration
    /// Increments after every change to the index (insert, OCR, edit, delete).
    public private(set) var revision = 0
    /// Most recent captures, newest first (HI-6).
    public private(set) var recentCaptures: [RecentCapture] = []

    @ObservationIgnored let files: LibraryFiles
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storeTask: Task<LibraryStore, Never>
    /// Tail of the serial OCR queue (one recognition at a time keeps memory flat).
    @ObservationIgnored private var ocrTail: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?

    public init(configuration: LibraryConfiguration = .standard, defaults: UserDefaults = .standard) throws {
        self.configuration = configuration
        self.defaults = defaults
        let files = LibraryFiles(root: configuration.rootDirectory)
        self.files = files

        let schema = Schema(versionedSchema: LibrarySchemaV2.self)
        let modelConfiguration: ModelConfiguration
        if configuration.isStoredInMemoryOnly {
            modelConfiguration = ModelConfiguration(
                UUID().uuidString, schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none
            )
        } else {
            try AppPaths.ensure(configuration.rootDirectory)
            modelConfiguration = ModelConfiguration(schema: schema, url: files.storeURL, cloudKitDatabase: .none)
        }
        let container = try ModelContainer(
            for: schema, migrationPlan: LibraryMigrationPlan.self, configurations: [modelConfiguration]
        )
        // Create the model actor off the main thread so its context isn't bound to it.
        storeTask = Task.detached(priority: .utility) {
            LibraryStore(modelContainer: container, files: files)
        }
    }

    /// The current history preferences.
    public var settings: LibrarySettings { LibrarySettings(defaults: defaults) }

    // MARK: Lifecycle

    /// Call once at launch: refreshes moved/missing files, applies retention,
    /// resumes unfinished OCR, then re-runs maintenance once a day. Between runs
    /// it is a single sleeping task, so there's no idle work.
    public func start() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [weak self] in
            await self?.runMaintenance()
            await self?.resumePendingTextRecognition()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.secondsUntilNextMaintenance(from: Date())))
                } catch {
                    break
                }
                await self?.runMaintenance()
            }
        }
    }

    public func stop() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    /// Retention + missing-file check (launch, daily, and on demand).
    public func runMaintenance() async {
        await refreshFileLinks()
        await applyRetention()
        await reloadRecents()
    }

    nonisolated static func secondsUntilNextMaintenance(from date: Date, calendar: Calendar = .current) -> TimeInterval {
        let startOfTomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: date) ?? date)
        // A few minutes past midnight, so it never races the date change.
        return max(60, startOfTomorrow.timeIntervalSince(date) + 5 * 60)
    }

    // MARK: Recording captures

    /// Records a screenshot (HI-1). Call after every capture, whether it was
    /// saved, copied, or closed.
    ///
    /// - Parameters:
    ///   - original: The **un-annotated** capture pixels (kept for re-editing, ED-3).
    ///   - scale: Pixels per point of `original`.
    ///   - annotations: The annotations drawn on it (capture-local points).
    ///   - exportedURL: Where the user's file was saved, or nil (copied only / closed).
    ///   - sourceAppName: Frontmost app at capture time, if known.
    ///   - cropRect: Crop applied on top of `original`, in capture-local points.
    ///   - wasDiscarded: The user closed the capture without saving or copying
    ///     (OUT-8). Skipped when "keep unsaved captures" is off.
    /// - Returns: The new item's id, or nil if history is off or writing failed.
    @discardableResult
    public func recordScreenshot(
        original: CGImage,
        scale: CGFloat,
        annotations: AnnotationDocument,
        exportedURL: URL?,
        sourceAppName: String?,
        cropRect: CGRect? = nil,
        wasDiscarded: Bool = false
    ) async -> UUID? {
        let settings = settings
        guard settings.isEnabled else { return nil }
        if wasDiscarded, !settings.keepsUnsavedCaptures { return nil }

        let id = UUID()
        let createdAt = configuration.now()
        let files = files
        do {
            let written = try await LibraryIO.writeScreenshot(
                id: id, original: original, scale: scale, annotations: annotations, cropRect: cropRect, files: files
            )
            let record = NewCaptureRecord(
                id: id,
                kind: .screenshot,
                createdAt: createdAt,
                title: Self.defaultTitle(for: createdAt),
                pixelSize: CGSize(width: original.width, height: original.height),
                scale: scale,
                duration: 0,
                exportURL: exportedURL,
                originalFileName: LibraryFiles.originalImageName,
                thumbnailFileName: written.thumbnailFileName,
                annotationsFileName: LibraryFiles.annotationsName,
                annotationCount: annotations.annotations.count,
                cropRect: cropRect,
                sourceAppName: sourceAppName,
                libraryByteSize: written.libraryBytes,
                fileByteSize: written.originalBytes
            )
            try await store().insert(record)
        } catch {
            Log.library.error("Couldn't record screenshot: \(error.localizedDescription, privacy: .public)")
            files.removeDirectory(for: id)
            return nil
        }
        Log.library.info("Recorded screenshot \(id.uuidString, privacy: .public)")

        if configuration.recognizesText {
            enqueueTextRecognition(id: id, image: original, fileURL: nil)
        } else {
            try? await store().setOCR(id: id, text: "", status: .notApplicable)
        }
        await applyRetention()
        await didChange()
        return id
    }

    /// Records a finished recording or GIF (HI-1). The file is referenced where
    /// it was exported, not copied; only a poster-frame thumbnail is stored.
    @discardableResult
    public func recordRecording(fileURL: URL, kind: CaptureKind = .recording, sourceAppName: String? = nil) async -> UUID? {
        guard settings.isEnabled else { return nil }
        let kind: CaptureKind = kind == .screenshot ? .recording : kind
        let id = UUID()
        let createdAt = configuration.now()
        let ingested = await LibraryIO.ingestMedia(id: id, fileURL: fileURL, kind: kind, files: files)
        let record = NewCaptureRecord(
            id: id,
            kind: kind,
            createdAt: createdAt,
            title: fileURL.lastPathComponent,
            pixelSize: ingested.info?.pixelSize ?? .zero,
            scale: 1,
            duration: ingested.info?.duration ?? 0,
            exportURL: fileURL,
            originalFileName: nil,
            thumbnailFileName: ingested.thumbnailFileName,
            annotationsFileName: nil,
            annotationCount: 0,
            cropRect: nil,
            sourceAppName: sourceAppName,
            libraryByteSize: ingested.libraryBytes,
            fileByteSize: ingested.fileBytes
        )
        do {
            try await store().insert(record)
        } catch {
            Log.library.error("Couldn't record \(kind.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)")
            files.removeDirectory(for: id)
            return nil
        }
        Log.library.info("Recorded \(kind.rawValue, privacy: .public) \(id.uuidString, privacy: .public)")
        await applyRetention()
        await didChange()
        return id
    }

    // MARK: Re-editing (ED-3)

    /// Loads a screenshot's original, scale, and live annotations for an editor.
    public func screenshotForEditing(id: UUID) async -> LibraryScreenshot? {
        guard let snapshot = await item(id: id), snapshot.kind == .screenshot else { return nil }
        return await LibraryIO.loadScreenshot(snapshot: snapshot, files: files)
    }

    /// Saves a re-edit: new annotations (and crop), refreshed thumbnail, and the
    /// new export location when the user saved again.
    public func updateAnnotations(
        for id: UUID,
        annotations: AnnotationDocument,
        exportedURL: URL?,
        cropRect: CGRect? = nil
    ) async {
        guard let snapshot = await item(id: id), snapshot.kind == .screenshot, let originalURL = snapshot.originalURL else {
            Log.library.error("Re-edit target \(id.uuidString, privacy: .public) not found")
            return
        }
        do {
            let rewritten = try await LibraryIO.rewriteAnnotations(
                id: id, originalURL: originalURL, scale: snapshot.scale,
                annotations: annotations, cropRect: cropRect, files: files
            )
            try await store().applyAnnotationUpdate(id: id, .init(
                annotationCount: annotations.annotations.count,
                annotationsFileName: LibraryFiles.annotationsName,
                thumbnailFileName: rewritten.thumbnailFileName,
                cropRect: cropRect,
                exportURL: exportedURL,
                editedAt: max(configuration.now(), snapshot.editedAt.addingTimeInterval(1)),
                libraryByteSize: rewritten.libraryBytes
            ))
        } catch {
            Log.library.error("Couldn't save re-edit: \(error.localizedDescription, privacy: .public)")
            return
        }
        await didChange()
    }

    /// Records that an item was saved to `url` (e.g. "Save As…" from the library).
    public func setExportURL(_ url: URL, for id: UUID) async {
        try? await store().setExportURL(id: id, url: url)
        await didChange()
    }

    // MARK: Queries

    public func item(id: UUID) async -> CaptureSnapshot? {
        try? await store().snapshot(id: id)
    }

    /// Searches OCR text and file names (HI-3), filtered by kind and date.
    public func search(
        text: String = "",
        kind: CaptureKind? = nil,
        dateRange: Range<Date>? = nil,
        sort: LibrarySort = .newest
    ) async -> [CaptureSnapshot] {
        await search(LibraryQuery(text: text, kind: kind, dateRange: dateRange, sort: sort))
    }

    public func search(_ query: LibraryQuery) async -> [CaptureSnapshot] {
        do {
            return try await store().search(query)
        } catch {
            Log.library.error("Search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Newest captures as lightweight values for the menu bar (HI-6).
    public func recent(limit: Int = CaptureLibrary.recentLimit) async -> [RecentCapture] {
        await search(LibraryQuery(limit: limit)).map {
            RecentCapture(
                id: $0.id,
                kind: $0.kind,
                title: $0.displayName,
                createdAt: $0.createdAt,
                thumbnailURL: $0.thumbnailURL,
                exportURL: $0.exportURL,
                isUnavailable: $0.isUnavailable
            )
        }
    }

    public func count() async -> Int {
        (try? await store().count()) ?? 0
    }

    /// Bytes used by the library folder (index, originals, thumbnails).
    public func storageUsed() async -> Int64 {
        await LibraryIO.totalByteSize(files: files)
    }

    /// The user's file for an item, or a flattened temporary PNG for screenshots
    /// that weren't saved (or were re-edited since). Nil if nothing is available.
    public func fileURL(for snapshot: CaptureSnapshot) async -> URL? {
        if let url = snapshot.currentUserFileURL { return url }
        guard snapshot.kind == .screenshot else { return nil }
        return await LibraryIO.temporaryFlattenedFile(snapshot: snapshot, files: files)
    }

    /// The screenshot with annotations and crop applied.
    public func flattenedImage(for snapshot: CaptureSnapshot) async -> CGImage? {
        guard snapshot.kind == .screenshot else { return nil }
        return await LibraryIO.flattenedImage(snapshot: snapshot, files: files)
    }

    // MARK: Organizing (HI-7…HI-9)

    /// Names an item in the library (HI-7). An empty name goes back to the file
    /// name. The file on disk keeps its name.
    public func rename(_ id: UUID, to name: String) async {
        await organize("Rename") { try $0.setCustomName(id: id, name: name) }
    }

    /// Adds a tag (HI-8), reusing an existing tag's spelling when one matches.
    public func addTag(_ tag: String, to ids: [UUID]) async {
        await organize("Add tag") { try $0.addTag(tag, to: ids) }
    }

    public func removeTag(_ tag: String, from ids: [UUID]) async {
        await organize("Remove tag") { try $0.removeTag(tag, from: ids) }
    }

    /// Renames a tag everywhere; renaming onto an existing tag merges the two.
    public func renameTag(_ tag: String, to name: String) async {
        await organize("Rename tag") { try $0.renameTag(tag, to: name) }
    }

    /// Removes a tag from every item. The items stay.
    public func deleteTag(_ tag: String) async {
        await organize("Delete tag") { try $0.deleteTag(tag) }
    }

    /// Tags in use, by name, with how many items carry each.
    public func tags() async -> [LibraryTag] {
        (try? await store().tagCounts()) ?? []
    }

    /// Library folders (HI-9), by name, with their item counts.
    public func folders() async -> [LibraryFolder] {
        (try? await store().folders()) ?? []
    }

    /// Creates a folder (default "New Folder", numbered if taken) holding `ids`.
    @discardableResult
    public func createFolder(named name: String? = nil, containing ids: [UUID] = []) async -> UUID? {
        let existing = await folders().map(\.name)
        let name = name.flatMap(LibraryTag.normalizedName) ?? LibraryFolder.untitledName(existing: existing)
        let id = UUID()
        let createdAt = configuration.now()
        do {
            let store = await store()
            try await store.createFolder(id: id, name: name, createdAt: createdAt)
            if !ids.isEmpty { try await store.moveItems(ids, toFolder: id) }
        } catch {
            Log.library.error("Couldn't create folder: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        await didChange()
        return id
    }

    /// Renames a folder; empty names are ignored.
    public func renameFolder(_ id: UUID, to name: String) async {
        await organize("Rename folder") { try $0.renameFolder(id: id, name: name) }
    }

    /// Deletes a folder. Its captures stay in the library, outside any folder.
    public func deleteFolder(_ id: UUID) async {
        await organize("Delete folder") { try $0.deleteFolder(id: id) }
    }

    /// Puts items in a folder, or takes them out with nil.
    public func move(_ ids: [UUID], toFolder folderID: UUID?) async {
        await organize("Move to folder") { try $0.moveItems(ids, toFolder: folderID) }
    }

    private func organize(_ action: String, _ change: @Sendable (isolated LibraryStore) throws -> Void) async {
        do {
            let store = await store()
            try await store.perform(change)
        } catch {
            Log.library.error("\(action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        await didChange()
    }

    // MARK: Deleting

    /// Removes items and their library files. Exported files are left alone
    /// unless `alsoTrashExportedFiles` (they then go to the Trash, not oblivion).
    public func delete(ids: [UUID], alsoTrashExportedFiles: Bool = false) async {
        guard !ids.isEmpty else { return }
        do {
            let removed = try await store().delete(ids: ids)
            if alsoTrashExportedFiles {
                await LibraryIO.moveToTrash(removed.compactMap(\.exportURL))
            }
            Log.library.info("Deleted \(removed.count) item(s)")
        } catch {
            Log.library.error("Delete failed: \(error.localizedDescription, privacy: .public)")
        }
        await didChange()
    }

    /// Empties the history. Exported files are never touched.
    public func deleteAll() async {
        let ids = (try? await store().allIDs()) ?? []
        await delete(ids: ids)
    }

    // MARK: Retention (HI-5)

    /// Deletes items outside the retention window, then the oldest items while
    /// the library exceeds the storage cap. Returns how many were removed.
    @discardableResult
    public func applyRetention(now: Date? = nil) async -> Int {
        let settings = settings
        let ids = await idsRemovedByRetention(settings.retention, storageCapBytes: settings.storageCapBytes, now: now)
        guard !ids.isEmpty else { return 0 }
        Log.library.info("Retention removes \(ids.count) item(s)")
        await delete(ids: ids)
        return ids.count
    }

    /// How many items a retention setting would remove right now (for confirming
    /// a settings change before it deletes anything).
    public func retentionPreview(retention: HistoryRetention, storageCapGB: Double, now: Date? = nil) async -> Int {
        let cap = LibrarySettings(retention: retention, storageCapGB: storageCapGB).storageCapBytes
        return await idsRemovedByRetention(retention, storageCapBytes: cap, now: now).count
    }

    private func idsRemovedByRetention(_ retention: HistoryRetention, storageCapBytes: Int64?, now: Date?) async -> [UUID] {
        guard retention != .forever || storageCapBytes != nil,
              let entries = try? await store().retentionEntries()
        else { return [] }
        return RetentionPlanner.idsToDelete(
            entries, retention: retention, storageCapBytes: storageCapBytes, now: now ?? configuration.now()
        )
    }

    // MARK: Missing files

    /// Follows moved/renamed exports and flags deleted ones (recordings shown as missing).
    public func refreshFileLinks() async {
        let changed = (try? await store().refreshExportLinks()) ?? false
        if changed { await didChange() }
    }

    // MARK: Background work

    /// Waits until queued OCR has finished (tests, and before quitting if desired).
    public func waitForBackgroundWork() async {
        while let tail = ocrTail {
            await tail.value
            if ocrTail == tail { break }
        }
    }

    private func enqueueTextRecognition(id: UUID, image: CGImage?, fileURL: URL?) {
        let previous = ocrTail
        ocrTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            var source = image
            if source == nil, let fileURL { source = await LibraryIO.loadImage(at: fileURL) }
            var text = ""
            var status = OCRStatus.failed
            if let source {
                do {
                    text = try await MediaProcessing.recognizeText(in: source)
                    status = .done
                } catch {
                    Log.library.error("OCR failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await self.store().setOCR(id: id, text: text, status: status)
            await self.didChange()
        }
    }

    private func resumePendingTextRecognition() async {
        guard configuration.recognizesText, let pending = try? await store().pendingOCR() else { return }
        for entry in pending {
            enqueueTextRecognition(id: entry.id, image: nil, fileURL: entry.originalURL)
        }
    }

    // MARK: Helpers

    private func store() async -> LibraryStore {
        await storeTask.value
    }

    private func didChange() async {
        revision += 1
        await reloadRecents()
    }

    private func reloadRecents() async {
        recentCaptures = await recent(limit: Self.recentLimit)
    }

    static func defaultTitle(for date: Date) -> String {
        CaptureFileNamer().baseName(for: date)
    }
}
