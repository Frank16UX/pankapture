import AppKit
import DesignSystem
import SwiftUI

/// Library window content (HI-2…HI-4): sidebar filters, thumbnail grid,
/// search, sort, inspector, and capture actions.
struct LibraryView: View {
    @Bindable var model: LibraryBrowserModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $model.filter)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
        } detail: {
            LibraryGrid(model: model)
                .inspector(isPresented: $model.isInspectorPresented) {
                    CaptureInspector(model: model)
                        .inspectorColumnWidth(min: 230, ideal: 280, max: 400)
                }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search text and file names")
        .navigationTitle("Library")
        .navigationSubtitle(model.subtitle)
        .toolbar { LibraryToolbar(model: model) }
        .task(id: model.reloadKey) { await model.reload() }
        .task(id: model.selection) { await model.prepareSelectionFiles() }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { model.deletionRequest != nil },
                set: { if !$0 { model.deletionRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.deletionRequest
        ) { request in
            Button("Delete from History", role: .destructive) {
                model.confirmDelete(request, trashFiles: false)
            }
            if request.hasUserFiles {
                Button("Delete and Move Saved Files to Trash", role: .destructive) {
                    model.confirmDelete(request, trashFiles: true)
                }
            }
            Button("Cancel", role: .cancel) { model.deletionRequest = nil }
        } message: { request in
            Text(request.hasUserFiles
                ? "Saved files stay where they are unless you also move them to the Trash."
                : "This can't be undone.")
        }
    }

    private var deletionTitle: String {
        let count = model.deletionRequest?.items.count ?? 0
        return count == 1 ? "Delete this capture from the history?" : "Delete \(count) captures from the history?"
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @Binding var selection: LibraryFilter

    var body: some View {
        List(selection: Binding<LibraryFilter?>(
            get: { selection },
            set: { if let value = $0 { selection = value } }
        )) {
            Section("Library") {
                ForEach(LibraryFilter.kindFilters) { filter in
                    Label(filter.title, systemImage: filter.symbolName).tag(filter)
                }
            }
            Section("Date") {
                ForEach(LibraryFilter.dateFilters) { filter in
                    Label(filter.title, systemImage: filter.symbolName).tag(filter)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Grid

private struct LibraryGrid: View {
    @Bindable var model: LibraryBrowserModel
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if !model.hasLoaded {
                Color.clear
            } else if model.items.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: LibraryBrowserModel.minCardWidth, maximum: LibraryBrowserModel.maxCardWidth),
                    spacing: LibraryBrowserModel.gridSpacing
                )],
                spacing: LibraryBrowserModel.gridSpacing
            ) {
                ForEach(model.items) { item in
                    CaptureCard(item: item, isSelected: model.selection.contains(item.id))
                        .onTapGesture {
                            isFocused = true
                            model.click(
                                item,
                                modifiers: NSEvent.modifierFlags,
                                clickCount: NSApp.currentEvent?.clickCount ?? 1
                            )
                        }
                        .onDrag { model.itemProvider(for: item) }
                        .contextMenu { ItemContextMenu(model: model, targets: model.targets(for: item)) }
                }
            }
            .padding(LibraryBrowserModel.gridSpacing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused = true
            model.clearSelection()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { model.gridWidth = $0 }
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onChange(of: isFocused) { _, focused in model.isGridFocused = focused }
        .onChange(of: model.isGridFocused) { _, focused in if focused != isFocused { isFocused = focused } }
        .onCopyCommand { model.copyProviders() }
        .onDeleteCommand { model.requestDelete(model.selectedItems) }
        .onKeyPress(.return) {
            guard !model.selection.isEmpty else { return .ignored }
            model.open(model.selectedItems)
            return .handled
        }
        .onKeyPress(.space) {
            model.quickLook()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let row = model.columnsPerRow
            let offset = switch press.key {
            case .leftArrow: -1
            case .rightArrow: 1
            case .upArrow: -row
            default: row
            }
            model.moveSelection(by: offset, extending: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.contains(.command), press.characters == "a" else { return .ignored }
            model.selectAll()
            return .handled
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if model.totalCount == 0 {
            ContentUnavailableView {
                Label("No Captures Yet", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text(model.library.settings.isEnabled
                    ? "Screenshots and recordings you take will appear here."
                    : "History is turned off. Turn it on in Settings to keep your captures here.")
            }
        } else {
            ContentUnavailableView(
                "No \(model.filter.title)",
                systemImage: model.filter.symbolName,
                description: Text("Nothing matches this filter.")
            )
        }
    }
}

// MARK: - Context menu

private struct ItemContextMenu: View {
    let model: LibraryBrowserModel
    let targets: [CaptureSnapshot]

    var body: some View {
        Button("Open") { model.open(targets) }
            .disabled(!model.canOpen(targets))
        if let item = targets.first, targets.count == 1 {
            Button(item.kind == .screenshot ? "Edit Annotations" : "Edit Recording") { model.reEdit(item) }
                .disabled(!model.canReEdit(targets))
        }
        Divider()
        Button("Copy") { model.copy(targets) }
            .disabled(!model.canOpen(targets))
        let shareURLs = targets.compactMap(model.preparedURL(for:))
        if !shareURLs.isEmpty {
            ShareLink(items: shareURLs) { Text("Share…") }
        }
        Button("Reveal in Finder") { model.reveal(targets) }
            .disabled(!model.canReveal(targets))
        if let item = targets.first, model.canSaveAs(targets) {
            Button("Save As…") { model.saveAs(item, in: model.window) }
        }
        Button("Quick Look") { model.quickLook() }
            .disabled(model.selectionFileURLs.isEmpty || targets.map(\.id) != model.selectedItems.map(\.id))
        Divider()
        Button("Delete…", role: .destructive) { model.requestDelete(targets) }
    }
}

// MARK: - Toolbar

private struct LibraryToolbar: ToolbarContent {
    @Bindable var model: LibraryBrowserModel

    var body: some ToolbarContent {
        let selected = model.selectedItems
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let item = selected.first { model.reEdit(item) }
            } label: {
                Label("Edit", systemImage: "pencil.tip.crop.circle")
            }
            .help("Edit Annotations (⌘E)")
            .keyboardShortcut("e", modifiers: .command)
            .disabled(!model.canReEdit(selected))

            Button {
                model.open(selected)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
            .help("Open (⌘O)")
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.canOpen(selected))

            Button {
                model.copy(selected)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy (⌘C)")
            .disabled(!model.canOpen(selected))

            ShareLink(items: model.selectionFileURLs) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share")
            .disabled(model.selectionFileURLs.isEmpty)

            Button {
                model.reveal(selected)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Reveal in Finder (⇧⌘R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!model.canReveal(selected))

            Button(role: .destructive) {
                model.requestDelete(selected)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete (⌫)")
            .disabled(selected.isEmpty)

            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(PK.Motion.standard) { model.isInspectorPresented.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or Hide Details (⌥⌘I)")
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}
