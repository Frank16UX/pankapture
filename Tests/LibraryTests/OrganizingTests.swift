import Annotation
import Foundation
import SwiftData
import Testing
@testable import Library

/// Names, tags, and folders (HI-7…HI-9), and the V1 → V2 store migration.
@MainActor
@Suite("Library organizing")
struct OrganizingTests {
    private func screenshot(_ fixture: LibraryFixture) async throws -> UUID {
        try #require(await fixture.library.recordScreenshot(
            original: TestImages.solid(width: 40, height: 40), scale: 1,
            annotations: AnnotationDocument(), exportedURL: nil, sourceAppName: nil
        ))
    }

    @Test func renameShowsAndSearchesTheNewName() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let id = try await screenshot(fixture)
        let fileName = try #require(await fixture.library.item(id: id)).title

        await fixture.library.rename(id, to: "  Onboarding\nbug  ")
        let renamed = try #require(await fixture.library.item(id: id))
        #expect(renamed.customName == "Onboarding bug")
        #expect(renamed.displayName == "Onboarding bug")
        #expect(renamed.title == fileName)
        #expect(await fixture.library.search(text: "onboarding").map(\.id) == [id])
        #expect(fixture.library.recentCaptures.first?.title == "Onboarding bug")

        await fixture.library.rename(id, to: "")
        #expect(try #require(await fixture.library.item(id: id)).displayName == fileName)
        await fixture.library.rename(id, to: fileName)
        #expect(try #require(await fixture.library.item(id: id)).customName.isEmpty)
    }

    @Test func tagsAreUniqueSortedAndFilterable() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let first = try await screenshot(fixture)
        let second = try await screenshot(fixture)

        await fixture.library.addTag("Design", to: [first])
        await fixture.library.addTag("design", to: [first, second])
        await fixture.library.addTag("bug", to: [first])
        await fixture.library.addTag("   ", to: [first])

        #expect(try #require(await fixture.library.item(id: first)).tags == ["bug", "Design"])
        #expect(try #require(await fixture.library.item(id: second)).tags == ["Design"])
        #expect(await fixture.library.tags() == [
            LibraryTag(name: "bug", itemCount: 1),
            LibraryTag(name: "Design", itemCount: 2),
        ])
        #expect(await fixture.library.search(LibraryQuery(tag: "bug")).map(\.id) == [first])
        #expect(Set(await fixture.library.search(LibraryQuery(tag: "DESIGN")).map(\.id)) == [first, second])
        // A tag filter matches whole tags only.
        #expect(await fixture.library.search(LibraryQuery(tag: "Des")).isEmpty)
        #expect(await fixture.library.search(text: "bug").map(\.id) == [first])

        await fixture.library.removeTag("DESIGN", from: [first])
        #expect(try #require(await fixture.library.item(id: first)).tags == ["bug"])
    }

    @Test func renamingATagOntoAnotherMergesThem() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let first = try await screenshot(fixture)
        let second = try await screenshot(fixture)
        await fixture.library.addTag("bugs", to: [first, second])
        await fixture.library.addTag("Bug", to: [first])

        await fixture.library.renameTag("bugs", to: "bug")
        #expect(try #require(await fixture.library.item(id: first)).tags == ["Bug"])
        #expect(try #require(await fixture.library.item(id: second)).tags == ["Bug"])
        #expect(await fixture.library.tags() == [LibraryTag(name: "Bug", itemCount: 2)])

        await fixture.library.deleteTag("bug")
        #expect(await fixture.library.tags().isEmpty)
        #expect(await fixture.library.count() == 2)
    }

    @Test func foldersGroupItemsAndDeletingKeepsThem() async throws {
        let fixture = try LibraryFixture()
        defer { fixture.cleanUp() }
        let first = try await screenshot(fixture)
        let second = try await screenshot(fixture)

        let folder = try #require(await fixture.library.createFolder(containing: [first]))
        let other = try #require(await fixture.library.createFolder())
        #expect(await fixture.library.folders().map(\.name) == ["New Folder", "New Folder 2"])
        #expect(await fixture.library.folders().map(\.itemCount) == [1, 0])
        #expect(await fixture.library.search(LibraryQuery(folderID: folder)).map(\.id) == [first])

        await fixture.library.move([first, second], toFolder: other)
        await fixture.library.renameFolder(other, to: "Bugs")
        await fixture.library.renameFolder(other, to: "  ")
        #expect(await fixture.library.folders().map(\.name) == ["Bugs", "New Folder"])
        #expect(await fixture.library.search(LibraryQuery(folderID: folder)).isEmpty)
        #expect(Set(await fixture.library.search(LibraryQuery(folderID: other)).map(\.id)) == [first, second])

        // Moving into a folder that doesn't exist changes nothing.
        await fixture.library.move([UUID(), first], toFolder: UUID())
        #expect(try #require(await fixture.library.item(id: first)).folderID == other)

        await fixture.library.deleteFolder(other)
        #expect(await fixture.library.folders().map(\.name) == ["New Folder"])
        #expect(await fixture.library.count() == 2)
        #expect(try #require(await fixture.library.item(id: first)).folderID == nil)
    }

    @Test func untitledFolderNamesSkipTakenOnes() {
        #expect(LibraryFolder.untitledName(existing: []) == "New Folder")
        #expect(LibraryFolder.untitledName(existing: ["new folder", "New Folder 2"]) == "New Folder 3")
    }

    @Test func suggestedFileNameUsesTheLibraryName() {
        var item = Self.snapshot(title: "Pankapture 2026-10-27 at 10.00.00.png")
        #expect(item.suggestedFileName == "Pankapture 2026-10-27 at 10.00.00")
        item.customName = "Login: before/after"
        #expect(item.suggestedFileName == "Login- before-after")
    }

    private static func snapshot(title: String) -> CaptureSnapshot {
        CaptureSnapshot(
            id: UUID(), kind: .screenshot, createdAt: Date(), editedAt: Date(), title: title,
            customName: "", tags: [], folderID: nil, pixelSize: .zero, scale: 1, duration: nil,
            exportURL: nil, isExportCurrent: true, isExportMissing: false, originalURL: nil,
            thumbnailURL: nil, annotationCount: 0, cropRect: nil, ocrText: "", ocrStatus: .done,
            sourceAppName: nil, libraryByteSize: 0, fileByteSize: 0
        )
    }

    /// A store written by the shipped (V1) schema opens with its items intact.
    @Test func migratesAVersionOneStore() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("PankaptureLibraryMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()

        do {
            let schema = Schema(versionedSchema: LibrarySchemaV1.self)
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: LibraryFiles(root: root).storeURL, cloudKitDatabase: .none)]
            )
            let context = ModelContext(container)
            let item = LibrarySchemaV1.CaptureItem(id: id, kindRaw: "screenshot", createdAt: Date(), title: "Old capture")
            item.ocrText = "invoice total"
            context.insert(item)
            try context.save()
        }

        let suite = "PankaptureLibraryMigration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = try CaptureLibrary(
            configuration: LibraryConfiguration(rootDirectory: root, recognizesText: false), defaults: defaults
        )
        let migrated = try #require(await library.item(id: id))
        #expect(migrated.title == "Old capture")
        #expect(migrated.customName.isEmpty)
        #expect(migrated.tags.isEmpty)
        #expect(migrated.folderID == nil)
        #expect(await library.search(text: "invoice").map(\.id) == [id])

        await library.addTag("receipts", to: [id])
        #expect(await library.search(LibraryQuery(tag: "receipts")).map(\.id) == [id])
    }
}
