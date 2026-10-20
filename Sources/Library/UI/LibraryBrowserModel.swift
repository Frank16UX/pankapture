import AppCore
import AppKit
import DesignSystem
import Observation
import UniformTypeIdentifiers

/// Sidebar filters (HI-2).
enum LibraryFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case screenshots
    case recordings
    case gifs
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    static let kindFilters: [LibraryFilter] = [.all, .screenshots, .recordings, .gifs]
    static let dateFilters: [LibraryFilter] = [.today, .last7Days, .last30Days]

    var title: String {
        switch self {
        case .all: "All Captures"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        case .gifs: "GIFs"
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        case .last30Days: "Last 30 Days"
        }
    }

    var symbolName: String {
        switch self {
        case .all: "square.grid.2x2"
        case .screenshots: CaptureKind.screenshot.symbolName
        case .recordings: CaptureKind.recording.symbolName
        case .gifs: CaptureKind.gif.symbolName
        case .today: "calendar"
        case .last7Days: "calendar.badge.clock"
        case .last30Days: "clock.arrow.circlepath"
        }
    }

    var kind: CaptureKind? {
        switch self {
        case .screenshots: .screenshot
        case .recordings: .recording
        case .gifs: .gif
        default: nil
        }
    }

    func dateRange(now: Date, calendar: Calendar = .current) -> Range<Date>? {
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack: Int
        switch self {
        case .today: daysBack = 0
        case .last7Days: daysBack = 6
        case .last30Days: daysBack = 29
        default: return nil
        }
        guard let start = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) else { return nil }
        return start..<Date.distantFuture
    }
}

/// State and actions of the library window. Owns no data: it queries
/// `CaptureLibrary` and re-queries when the library's `revision` changes.
@MainActor
@Observable
final class LibraryBrowserModel {
    static let minCardWidth: CGFloat = 170
    static let maxCardWidth: CGFloat = 250
    static let gridSpacing: CGFloat = PK.Spacing.l

    let library: CaptureLibrary

    var filter: LibraryFilter = .all
    var searchText = ""
    var sort: LibrarySort = .newest
    var isInspectorPresented = true
    var selection: Set<UUID> = []
    var deletionRequest: DeletionRequest?
    var isGridFocused = false

    private(set) var items: [CaptureSnapshot] = []
    private(set) var totalCount = 0
    private(set) var hasLoaded = false
    /// Files ready for share / drag / Quick Look, per item and edit version.
    private(set) var preparedFiles: [UUID: PreparedFile] = [:]

    @ObservationIgnored var gridWidth: CGFloat = 0
    /// Host window, for sheets.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var selectionAnchor: UUID?
    @ObservationIgnored private var lastQueryText: String?
    @ObservationIgnored var onReEditScreenshot: ((LibraryScreenshot) -> Void)?
    @ObservationIgnored var onOpenRecording: ((URL) -> Void)?
    @ObservationIgnored var onQuickLook: (([URL]) -> Void)?
    @ObservationIgnored var onSelectionFilesChanged: (([URL]) -> Void)?

    struct PreparedFile: Equatable {
        var version: Date
        var url: URL
    }

    struct DeletionRequest: Identifiable {
        let id = UUID()
        let items: [CaptureSnapshot]
        var hasUserFiles: Bool { items.contains { $0.exportURL != nil && !$0.isExportMissing } }
    }

    /// Changes to any of these re-run the query.
    struct ReloadKey: Hashable {
        var filter: LibraryFilter
        var searchText: String
        var sort: LibrarySort
        var revision: Int
    }

    init(library: CaptureLibrary) {
        self.library = library
    }

    var reloadKey: ReloadKey {
        ReloadKey(filter: filter, searchText: searchText, sort: sort, revision: library.revision)
    }

    var selectedItems: [CaptureSnapshot] {
        items.filter { selection.contains($0.id) }
    }

    var subtitle: String {
        if !selection.isEmpty { return "\(selection.count) of \(items.count) selected" }
        return items.count == 1 ? "1 capture" : "\(items.count) captures"
    }

    // MARK: Loading

    func reload() async {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Debounce typing; filter/sort/revision changes apply immediately.
        if let lastQueryText, lastQueryText != text {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        }
        let query = LibraryQuery(text: text, kind: filter.kind, dateRange: filter.dateRange(now: Date()), sort: sort)
        let results = await library.search(query)
        let count = await library.count()
        guard !Task.isCancelled else { return }
        lastQueryText = text
        items = results
        totalCount = count
        hasLoaded = true
        let visible = Set(results.map(\.id))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }

    /// Resolves (or renders) files for the selection so share, drag, copy, and
    /// Quick Look are instant.
    func prepareSelectionFiles() async {
        for item in selectedItems.prefix(50) {
            if preparedFiles[item.id]?.version == item.editedAt { continue }
            guard let url = await library.fileURL(for: item) else { continue }
            guard !Task.isCancelled else { return }
            preparedFiles[item.id] = PreparedFile(version: item.editedAt, url: url)
        }
        onSelectionFilesChanged?(selectionFileURLs)
    }

    func preparedURL(for item: CaptureSnapshot) -> URL? {
        if let url = item.currentUserFileURL { return url }
        guard let prepared = preparedFiles[item.id], prepared.version == item.editedAt else { return nil }
        return prepared.url
    }

    var selectionFileURLs: [URL] {
        selectedItems.compactMap(preparedURL(for:))
    }

    // MARK: Selection

    func click(_ item: CaptureSnapshot, modifiers: NSEvent.ModifierFlags, clickCount: Int) {
        isGridFocused = true
        if clickCount >= 2 {
            selection = [item.id]
            selectionAnchor = item.id
            open([item])
            return
        }
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let from = items.firstIndex(where: { $0.id == anchor }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            let range = items[min(from, to)...max(from, to)].map(\.id)
            if modifiers.contains(.command) {
                selection.formUnion(range)
            } else {
                selection = Set(range)
            }
        } else if modifiers.contains(.command) {
            if selection.contains(item.id) {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
            selectionAnchor = item.id
        } else {
            selection = [item.id]
            selectionAnchor = item.id
        }
    }

    func selectAll() {
        selection = Set(items.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
        selectionAnchor = nil
    }

    /// Arrow-key navigation. `rowStep` moves by a full row of the adaptive grid.
    func moveSelection(by offset: Int, extending: Bool) {
        guard !items.isEmpty else { return }
        let current = selectionAnchor.flatMap { id in items.firstIndex { $0.id == id } }
        let target = current.map { min(max($0 + offset, 0), items.count - 1) } ?? (offset >= 0 ? 0 : items.count - 1)
        let id = items[target].id
        if extending {
            selection.insert(id)
        } else {
            selection = [id]
        }
        selectionAnchor = id
    }

    var columnsPerRow: Int {
        let spacing = Self.gridSpacing
        return max(1, Int((gridWidth - 2 * spacing + spacing) / (Self.minCardWidth + spacing)))
    }

    /// Context-menu targets: the selection if the clicked item is part of it.
    func targets(for item: CaptureSnapshot) -> [CaptureSnapshot] {
        selection.contains(item.id) ? selectedItems : [item]
    }

    // MARK: Actions (HI-4)

    func open(_ items: [CaptureSnapshot]) {
        for item in items {
            if let url = item.currentUserFileURL {
                NSWorkspace.shared.open(url)
                continue
            }
            Task {
                guard let url = await library.fileURL(for: item) else {
                    NSSound.beep()
                    return
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    func canReEdit(_ items: [CaptureSnapshot]) -> Bool {
        guard items.count == 1, let item = items.first else { return false }
        switch item.kind {
        case .screenshot: return item.isReEditable && onReEditScreenshot != nil
        case .recording: return item.isReEditable && onOpenRecording != nil
        case .gif: return false
        }
    }

    func reEdit(_ item: CaptureSnapshot) {
        switch item.kind {
        case .screenshot:
            Task {
                guard let screenshot = await library.screenshotForEditing(id: item.id) else {
                    NSSound.beep()
                    return
                }
                onReEditScreenshot?(screenshot)
            }
        case .recording:
            if let url = item.exportURL, !item.isExportMissing { onOpenRecording?(url) }
        case .gif:
            break
        }
    }

    func canOpen(_ items: [CaptureSnapshot]) -> Bool {
        !items.isEmpty && items.contains { !$0.isUnavailable }
    }

    func canReveal(_ items: [CaptureSnapshot]) -> Bool {
        items.contains { $0.exportURL != nil && !$0.isExportMissing }
    }

    func reveal(_ items: [CaptureSnapshot]) {
        let urls = items.compactMap { $0.isExportMissing ? nil : $0.exportURL }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Copies a single screenshot as image data (plus its file when saved);
    /// anything else as file references.
    func copy(_ items: [CaptureSnapshot]) {
        guard !items.isEmpty else { return }
        Task {
            let pasteboard = NSPasteboard.general
            if items.count == 1, let item = items.first, item.kind == .screenshot,
               let image = await library.flattenedImage(for: item),
               let png = try? await Self.encodePNG(image) {
                let pasteboardItem = NSPasteboardItem()
                pasteboardItem.setData(png, forType: .png)
                if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
                    pasteboardItem.setData(tiff, forType: .tiff)
                }
                if let url = item.currentUserFileURL {
                    pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                }
                pasteboard.clearContents()
                pasteboard.writeObjects([pasteboardItem])
                return
            }
            var urls: [URL] = []
            for item in items {
                if let url = await library.fileURL(for: item) { urls.append(url) }
            }
            guard !urls.isEmpty else {
                NSSound.beep()
                return
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
    }

    @concurrent
    private static func encodePNG(_ image: CGImage) async throws -> Data {
        try MediaProcessing.encode(image, as: .png)
    }

    /// File providers for ⌘C (`onCopyCommand`).
    func copyProviders() -> [NSItemProvider] {
        selectedItems.map(itemProvider(for:))
    }

    /// Drag-out provider (OUT-7 for history). Uses the ready file when there is
    /// one, otherwise renders lazily when the drop target asks for the data.
    func itemProvider(for item: CaptureSnapshot) -> NSItemProvider {
        if let url = preparedURL(for: item), let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        let provider = NSItemProvider()
        provider.suggestedName = (item.title as NSString).deletingPathExtension
        guard item.kind == .screenshot else { return provider }
        let library = library
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                let url = await library.fileURL(for: item)
                completion(url, false, url == nil ? CocoaError(.fileNoSuchFile) : nil)
            }
            return nil
        }
        return provider
    }

    func canSaveAs(_ items: [CaptureSnapshot]) -> Bool {
        items.count == 1 && items.first?.kind == .screenshot
    }

    /// Saves a flattened copy of a screenshot (recovers unsaved captures, OUT-8).
    func saveAs(_ item: CaptureSnapshot, in window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (item.title as NSString).deletingPathExtension + ".png"
        panel.directoryURL = Preferences.saveDirectory()
        let library = library
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let image = await library.flattenedImage(for: item) else {
                    NSSound.beep()
                    return
                }
                do {
                    try await LibraryIO.writePNG(image, to: url)
                    await library.setExportURL(url, for: item.id)
                } catch {
                    Log.library.error("Save As failed: \(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    func quickLook() {
        let urls = selectionFileURLs
        guard !urls.isEmpty else { return }
        onQuickLook?(urls)
    }

    // MARK: Deleting

    func requestDelete(_ items: [CaptureSnapshot]) {
        guard !items.isEmpty else { return }
        deletionRequest = DeletionRequest(items: items)
    }

    func confirmDelete(_ request: DeletionRequest, trashFiles: Bool) {
        let ids = request.items.map(\.id)
        selection.subtract(ids)
        deletionRequest = nil
        Task { await library.delete(ids: ids, alsoTrashExportedFiles: trashFiles) }
    }
}
