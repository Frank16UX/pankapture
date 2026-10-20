import Annotation
import AppCore
import CoreGraphics
import Foundation
import Testing
@testable import Library

@MainActor
@Suite("CaptureLibrary")
struct CaptureLibraryTests {
    private func arrow() -> Annotation {
        Annotation(shape: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 120, y: 80)), style: AnnotationStyle(color: .blue, lineWidth: 6))
    }

    @Test func recordsScreenshotFilesThumbnailAndItem() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 1200, height: 600)
        var document = AnnotationDocument()
        document.add(arrow())

        let id = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 2, annotations: document, exportedURL: nil, sourceAppName: "Notes"
        ))

        let item = try #require(await fixture.library.item(id: id))
        #expect(item.kind == .screenshot)
        #expect(item.pixelSize == CGSize(width: 1200, height: 600))
        #expect(item.scale == 2)
        #expect(item.annotationCount == 1)
        #expect(item.exportURL == nil)
        #expect(item.sourceAppName == "Notes")
        #expect(item.title.hasPrefix("Pankapture "))
        #expect(item.libraryByteSize > 0)

        let directory = fixture.root.appendingPathComponent("Captures/\(id.uuidString)", isDirectory: true)
        let original = directory.appendingPathComponent("original.png")
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("annotations.json").path))
        #expect(item.originalURL == original)
        #expect(TestImages.pixelSize(ofImageAt: original) == CGSize(width: 1200, height: 600))

        let thumbnail = try #require(item.thumbnailURL)
        #expect(thumbnail.deletingLastPathComponent() == directory)
        let thumbnailSize = try #require(TestImages.pixelSize(ofImageAt: thumbnail))
        #expect(max(thumbnailSize.width, thumbnailSize.height) == 512)

        #expect(fixture.library.recentCaptures.map(\.id) == [id])
        #expect(fixture.library.revision > 0)
    }

    @Test func respectsHistorySettings() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 40, height: 40)

        fixture.defaults.set(false, forKey: PreferenceKey.historyKeepsUnsavedCaptures)
        let discarded = await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil, wasDiscarded: true
        )
        #expect(discarded == nil)
        let copied = await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        )
        #expect(copied != nil)

        fixture.defaults.set(false, forKey: PreferenceKey.historyEnabled)
        let disabled = await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        )
        #expect(disabled == nil)
        #expect(await fixture.library.count() == 1)
    }

    @Test func recognizesTextAndSearchesIt() async throws {
        let fixture = try LibraryFixture(recognizesText: true)
        defer { fixture.cleanUp() }
        let id = try #require(await fixture.library.recordScreenshot(
            original: TestImages.text("Hello Pankapture 2026"), scale: 1,
            annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        ))
        await fixture.library.recordScreenshot(
            original: TestImages.solid(width: 300, height: 200), scale: 1,
            annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        )
        await fixture.library.waitForBackgroundWork()

        let item = try #require(await fixture.library.item(id: id))
        #expect(item.ocrStatus == .done)
        #expect(item.ocrText.localizedCaseInsensitiveContains("hello"))
        #expect(item.ocrText.localizedCaseInsensitiveContains("pankapture"))
        #expect(item.ocrText.contains("2026"))

        let hits = await fixture.library.search(text: "pankapture")
        #expect(hits.map(\.id).contains(id))
        let byOCROnly = await fixture.library.search(text: "hello")
        #expect(byOCROnly.map(\.id) == [id])
        #expect(await fixture.library.search(text: "xylophone").isEmpty)
    }

    @Test func searchesByFileNameKindAndDate() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 50, height: 50)
        let exportURL = fixture.scratch.appendingPathComponent("Invoice Draft.png")
        try TestImages.writePNG(image, to: exportURL)

        let start = fixture.clock.now
        let saved = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: exportURL, sourceAppName: nil
        ))
        fixture.clock.set(start.addingTimeInterval(3 * 86_400))
        let gifURL = fixture.scratch.appendingPathComponent("Demo Loop.gif")
        try TestImages.writeGIF(to: gifURL)
        let gif = try #require(await fixture.library.recordRecording(fileURL: gifURL, kind: .gif))

        #expect(await fixture.library.search(text: "invoice").map(\.id) == [saved])
        #expect(await fixture.library.search(text: "DRAFT").map(\.id) == [saved])
        #expect(await fixture.library.search(text: "loop").map(\.id) == [gif])
        #expect(await fixture.library.search(kind: .gif).map(\.id) == [gif])
        #expect(await fixture.library.search(kind: .screenshot).map(\.id) == [saved])
        #expect(await fixture.library.search(kind: .recording).isEmpty)

        let firstDay = start.addingTimeInterval(-60)..<start.addingTimeInterval(86_400)
        #expect(await fixture.library.search(dateRange: firstDay).map(\.id) == [saved])
        #expect(await fixture.library.search(sort: .newest).map(\.id) == [gif, saved])
        #expect(await fixture.library.search(sort: .oldest).map(\.id) == [saved, gif])
    }

    @Test func retentionDeletesItemsOlderThanTheWindow() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 40, height: 40)
        let now = fixture.clock.now

        fixture.clock.set(now.addingTimeInterval(-40 * 86_400))
        let old = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        ))
        fixture.clock.set(now.addingTimeInterval(-10 * 86_400))
        let recent = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        ))
        fixture.clock.set(now)

        // Forever keeps everything.
        #expect(await fixture.library.applyRetention() == 0)

        fixture.defaults.set(HistoryRetention.days30.rawValue, forKey: PreferenceKey.historyRetention)
        #expect(await fixture.library.retentionPreview(retention: .days30, storageCapGB: 0) == 1)
        #expect(await fixture.library.retentionPreview(retention: .days90, storageCapGB: 0) == 0)
        #expect(await fixture.library.applyRetention() == 1)

        #expect(await fixture.library.item(id: old) == nil)
        #expect(await fixture.library.item(id: recent) != nil)
        let oldDirectory = fixture.root.appendingPathComponent("Captures/\(old.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: oldDirectory.path))
    }

    @Test func storageCapDeletesOldestFirst() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let start = fixture.clock.now
        var ids: [UUID] = []
        for index in 0..<3 {
            fixture.clock.set(start.addingTimeInterval(Double(index) * 60))
            let id = try #require(await fixture.library.recordScreenshot(
                original: TestImages.solid(width: 300, height: 300, gray: 0.1 * Double(index + 1)), scale: 1,
                annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
            ))
            ids.append(id)
        }
        let newest = try #require(await fixture.library.item(id: ids[2]))
        let middle = try #require(await fixture.library.item(id: ids[1]))
        // Room for the newest two items only.
        let capBytes = newest.libraryByteSize + middle.libraryByteSize + 1
        fixture.defaults.set(Double(capBytes) / 1_000_000_000, forKey: PreferenceKey.historyStorageCapGB)

        #expect(await fixture.library.applyRetention() == 1)
        #expect(await fixture.library.item(id: ids[0]) == nil)
        #expect(await fixture.library.item(id: ids[1]) != nil)
        #expect(await fixture.library.item(id: ids[2]) != nil)
    }

    @Test func annotationsRoundTripThroughReEdit() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 400, height: 300)
        var document = AnnotationDocument()
        document.add(arrow())
        document.add(Annotation(shape: .text(origin: CGPoint(x: 5, y: 5), string: "Note", fontSize: 18)))
        let crop = CGRect(x: 10, y: 10, width: 100, height: 80)

        let id = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 2, annotations: document, exportedURL: nil, sourceAppName: nil, cropRect: crop
        ))
        let loaded = try #require(await fixture.library.screenshotForEditing(id: id))
        #expect(loaded.annotations.annotations == document.annotations)
        #expect(loaded.scale == 2)
        #expect(loaded.cropRect == crop)
        #expect(loaded.original.width == 400 && loaded.original.height == 300)

        // Re-edit and save to a file.
        var edited = loaded.annotations
        edited.add(Annotation(shape: .rectangle(CGRect(x: 20, y: 20, width: 40, height: 40))))
        let exportURL = fixture.scratch.appendingPathComponent("Edited.png")
        try TestImages.writePNG(image, to: exportURL)
        let before = try #require(await fixture.library.item(id: id))
        await fixture.library.updateAnnotations(for: id, annotations: edited, exportedURL: exportURL, cropRect: nil)

        let reloaded = try #require(await fixture.library.screenshotForEditing(id: id))
        #expect(reloaded.annotations.annotations == edited.annotations)
        #expect(reloaded.cropRect == nil)
        let item = try #require(await fixture.library.item(id: id))
        #expect(item.annotationCount == 3)
        #expect(item.exportURL == exportURL)
        #expect(item.title == "Edited.png")
        #expect(item.isExportCurrent)
        #expect(item.editedAt > before.editedAt)
        #expect(item.currentUserFileURL == exportURL)

        // Re-edit without saving: the export is stale; sharing falls back to a flattened copy.
        await fixture.library.updateAnnotations(for: id, annotations: AnnotationDocument(), exportedURL: nil)
        let stale = try #require(await fixture.library.item(id: id))
        #expect(!stale.isExportCurrent)
        #expect(stale.currentUserFileURL == nil)
        let temporary = try #require(await fixture.library.fileURL(for: stale))
        #expect(temporary != exportURL)
        #expect(TestImages.pixelSize(ofImageAt: temporary) == CGSize(width: 400, height: 300))
    }

    @Test func flattenedImageAppliesCrop() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let id = try #require(await fixture.library.recordScreenshot(
            original: TestImages.solid(width: 400, height: 300), scale: 2, annotations: AnnotationDocument(),
            exportedURL: nil, sourceAppName: nil, cropRect: CGRect(x: 10, y: 10, width: 50, height: 40)
        ))
        let item = try #require(await fixture.library.item(id: id))
        let flattened = try #require(await fixture.library.flattenedImage(for: item))
        #expect(flattened.width == 100 && flattened.height == 80)
    }

    @Test func gifRecordingIsIndexedAndMissingFilesAreDetected() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let gifURL = fixture.scratch.appendingPathComponent("Loop.gif")
        try TestImages.writeGIF(to: gifURL)

        let id = try #require(await fixture.library.recordRecording(fileURL: gifURL, kind: .gif))
        var item = try #require(await fixture.library.item(id: id))
        #expect(item.kind == .gif)
        #expect(item.pixelSize == CGSize(width: 80, height: 60))
        #expect(abs((item.duration ?? 0) - 0.3) < 0.01)
        #expect(item.exportURL == gifURL)
        #expect(item.originalURL == nil)
        #expect(item.ocrStatus == .notApplicable)
        #expect(item.thumbnailURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(!item.isUnavailable)

        // Moved: the bookmark follows it.
        let movedURL = fixture.scratch.appendingPathComponent("Renamed Loop.gif")
        try FileManager.default.moveItem(at: gifURL, to: movedURL)
        await fixture.library.refreshFileLinks()
        item = try #require(await fixture.library.item(id: id))
        #expect(item.exportURL?.standardizedFileURL.resolvingSymlinksInPath() == movedURL.standardizedFileURL.resolvingSymlinksInPath())
        #expect(item.title == "Renamed Loop.gif")
        #expect(!item.isExportMissing)

        // Deleted: flagged missing.
        try FileManager.default.removeItem(at: movedURL)
        await fixture.library.refreshFileLinks()
        item = try #require(await fixture.library.item(id: id))
        #expect(item.isExportMissing)
        #expect(item.isUnavailable)
        #expect(fixture.library.recentCaptures.first?.isUnavailable == true)
    }

    @Test func movieRecordingGetsDurationSizeAndPoster() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let movieURL = fixture.scratch.appendingPathComponent("Demo.mp4")
        try await TestImages.writeMovie(to: movieURL)

        let id = try #require(await fixture.library.recordRecording(fileURL: movieURL))
        let item = try #require(await fixture.library.item(id: id))
        #expect(item.kind == .recording)
        #expect(item.pixelSize == CGSize(width: 64, height: 48))
        #expect(abs((item.duration ?? 0) - 1) < 0.15)
        #expect(item.fileByteSize > 0)
        #expect(item.thumbnailURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(item.isReEditable)
    }

    @Test func deleteRemovesLibraryFilesButKeepsExports() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let image = TestImages.solid(width: 40, height: 40)
        let exportURL = fixture.scratch.appendingPathComponent("Keep Me.png")
        try TestImages.writePNG(image, to: exportURL)
        let id = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: exportURL, sourceAppName: nil
        ))
        let other = try #require(await fixture.library.recordScreenshot(
            original: image, scale: 1, annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        ))

        await fixture.library.delete(ids: [id])
        #expect(await fixture.library.item(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Captures/\(id.uuidString)").path))
        #expect(FileManager.default.fileExists(atPath: exportURL.path))
        #expect(fixture.library.recentCaptures.map(\.id) == [other])

        await fixture.library.deleteAll()
        #expect(await fixture.library.count() == 0)
        #expect(fixture.library.recentCaptures.isEmpty)
    }

    @Test func recentIsNewestFirstAndLimited() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let start = fixture.clock.now
        var ids: [UUID] = []
        for index in 0..<12 {
            fixture.clock.set(start.addingTimeInterval(Double(index)))
            let id = try #require(await fixture.library.recordScreenshot(
                original: TestImages.solid(width: 8, height: 8), scale: 1,
                annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
            ))
            ids.append(id)
        }
        let recent = await fixture.library.recent(limit: 5)
        #expect(recent.map(\.id) == Array(ids.reversed().prefix(5)))
        #expect(fixture.library.recentCaptures.count == CaptureLibrary.recentLimit)
        #expect(fixture.library.recentCaptures.first?.id == ids.last)
    }
}

@Suite("RetentionPlanner")
struct RetentionPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(daysAgo: Double, bytes: Int64 = 100) -> RetentionPlanner.Entry {
        RetentionPlanner.Entry(id: UUID(), createdAt: now.addingTimeInterval(-daysAgo * 86_400), byteSize: bytes)
    }

    @Test func foreverWithoutCapKeepsEverything() {
        let entries = [entry(daysAgo: 400), entry(daysAgo: 1)]
        #expect(RetentionPlanner.idsToDelete(entries, retention: .forever, storageCapBytes: nil, now: now).isEmpty)
    }

    @Test func windowAndCapCombine() {
        let ancient = entry(daysAgo: 100)
        let older = entry(daysAgo: 20, bytes: 500)
        let newer = entry(daysAgo: 5, bytes: 500)
        let newest = entry(daysAgo: 1, bytes: 500)
        let doomed = RetentionPlanner.idsToDelete(
            [newest, ancient, newer, older], retention: .days90, storageCapBytes: 1_000, now: now
        )
        #expect(doomed == [ancient.id, older.id])
    }

    @Test func maintenanceRunsShortlyAfterMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 0))!
        let seconds = CaptureLibrary.secondsUntilNextMaintenance(from: date, calendar: calendar)
        #expect(seconds == 3_600 + 300)
    }
}
