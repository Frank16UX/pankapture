import AppKit
import DesignSystem
import SwiftUI

/// Metadata for the selection (HI-2/HI-4): name (HI-7), folder and tags
/// (HI-8, HI-9), date, size, dimensions, duration, location, and recognized
/// text with a Copy button. Several selected items share one folder/tags editor.
struct CaptureInspector: View {
    let model: LibraryBrowserModel

    var body: some View {
        let selected = model.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                SingleItemInspector(item: item, model: model)
                    .id(item.id)
            } else if selected.count > 1 {
                MultiItemInspector(items: selected, model: model)
            } else {
                ContentUnavailableView("No Selection", systemImage: "info.circle", description: Text("Select a capture to see its details."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SingleItemInspector: View {
    let item: CaptureSnapshot
    let model: LibraryBrowserModel

    @State private var nameDraft: String
    @FocusState private var focus: InspectorField?

    init(item: CaptureSnapshot, model: LibraryBrowserModel) {
        self.item = item
        self.model = model
        _nameDraft = State(initialValue: item.displayName)
    }

    var body: some View {
        Form {
            Section {
                ThumbnailView(url: item.thumbnailURL, version: item.editedAt, kind: item.kind)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                    nameField
                    if !item.customName.isEmpty {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help("File name")
                    }
                }
            }

            Section("Organize") {
                FolderPicker(items: [item], model: model)
                TagEditor(items: [item], model: model, focus: $focus)
            }

            Section("Information") {
                LabeledContent("Kind", value: item.kind.title)
                LabeledContent("Created") {
                    Text(item.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
                if item.editedAt > item.createdAt {
                    LabeledContent("Edited") {
                        Text(item.editedAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
                if item.pixelSize != .zero {
                    LabeledContent("Dimensions") {
                        Text(dimensions).monospacedDigit()
                    }
                }
                if let duration = item.duration {
                    LabeledContent("Duration") {
                        Text(LibraryFormat.duration(duration)).monospacedDigit()
                    }
                }
                if item.fileByteSize > 0 {
                    LabeledContent("Size") {
                        Text(LibraryFormat.bytes(item.fileByteSize)).monospacedDigit()
                    }
                }
                if item.kind == .screenshot {
                    LabeledContent("Annotations") {
                        Text("\(item.annotationCount)").monospacedDigit()
                    }
                }
                if let app = item.sourceAppName {
                    LabeledContent("App", value: app)
                }
                LabeledContent("Location") {
                    location
                }
            }

            if item.kind == .screenshot {
                Section {
                    recognizedText
                } header: {
                    HStack {
                        Text("Text")
                        Spacer()
                        Button {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(item.ocrText, forType: .string)
                        } label: {
                            Label("Copy Text", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .help("Copy Recognized Text")
                        .disabled(item.ocrText.isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var nameField: some View {
        TextField("Name", text: $nameDraft, axis: .vertical)
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.headline)
            .lineLimit(1...3)
            .focused($focus, equals: .name)
            .onSubmit {
                commitName()
                focus = nil
            }
            .onExitCommand {
                nameDraft = item.displayName
                focus = nil
            }
            .onChange(of: focus) { old, _ in
                if old == .name { commitName() }
            }
            .onChange(of: item.displayName) { _, name in
                if focus != .name { nameDraft = name }
            }
            .onDisappear(perform: commitName)
            .help("Rename (the file keeps its name)")
            .accessibilityLabel("Name")
            .task(id: model.pendingInspectorFocus) {
                guard let field = model.pendingInspectorFocus else { return }
                model.pendingInspectorFocus = nil
                focus = field
            }
    }

    private func commitName() {
        model.rename(item, to: nameDraft)
    }

    private var dimensions: String {
        let pixels = LibraryFormat.dimensions(item.pixelSize)
        guard item.kind == .screenshot, item.scale > 1 else { return pixels }
        return "\(pixels) @\(Int(item.scale))x"
    }

    @ViewBuilder
    private var location: some View {
        if let url = item.exportURL {
            VStack(alignment: .trailing, spacing: PK.Spacing.xxs) {
                Button((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.link)
                .lineLimit(2)
                .truncationMode(.middle)
                .disabled(item.isExportMissing)
                .help("Reveal in Finder")
                if item.isExportMissing {
                    Label("Moved to Trash or deleted", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !item.isExportCurrent {
                    Text("Edited since it was saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Not saved").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recognizedText: some View {
        switch item.ocrStatus {
        case .pending:
            HStack(spacing: PK.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Recognizing text…").foregroundStyle(.secondary)
            }
        case .done where !item.ocrText.isEmpty:
            ScrollView {
                Text(item.ocrText)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        case .failed:
            Text("Text couldn't be recognized.").foregroundStyle(.secondary)
        default:
            Text("No text found.").foregroundStyle(.secondary)
        }
    }
}

/// Several captures: count and size, plus folder and tags for all of them.
private struct MultiItemInspector: View {
    let items: [CaptureSnapshot]
    let model: LibraryBrowserModel

    @FocusState private var focus: InspectorField?

    var body: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                        Text("\(items.count) Captures").font(.headline)
                        Text(LibraryFormat.bytes(items.reduce(0) { $0 + $1.fileByteSize }))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } icon: {
                    Image(systemName: "square.stack")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Organize") {
                FolderPicker(items: items, model: model)
                TagEditor(items: items, model: model, focus: $focus)
            }
        }
        .formStyle(.grouped)
        .task(id: model.pendingInspectorFocus) {
            guard model.pendingInspectorFocus == .tag else { return }
            model.pendingInspectorFocus = nil
            focus = .tag
        }
    }
}

/// The library folder of the selection; "Multiple" when they differ.
private struct FolderPicker: View {
    let items: [CaptureSnapshot]
    let model: LibraryBrowserModel

    private enum Choice: Hashable {
        case none
        case folder(UUID)
        case mixed
    }

    private var current: Choice {
        let ids = Set(items.map(\.folderID))
        guard ids.count == 1, let only = ids.first else { return .mixed }
        return only.map(Choice.folder) ?? .none
    }

    var body: some View {
        Picker("Folder", selection: Binding(
            get: { current },
            set: { choice in
                switch choice {
                case .none: model.move(items, toFolder: nil)
                case let .folder(id): model.move(items, toFolder: id)
                case .mixed: break
                }
            }
        )) {
            if current == .mixed {
                Text("Multiple").tag(Choice.mixed)
                Divider()
            }
            Text("None").tag(Choice.none)
            if !model.folders.isEmpty {
                Divider()
                ForEach(model.folders) { folder in
                    Text(folder.name).tag(Choice.folder(folder.id))
                }
            }
        }
        .help("Folders organize the Library only; files on disk don't move.")
    }
}

/// Tags shared by all of `items` as removable chips, and a field that adds a
/// tag to all of them, suggesting existing tags as you type.
private struct TagEditor: View {
    let items: [CaptureSnapshot]
    let model: LibraryBrowserModel
    var focus: FocusState<InspectorField?>.Binding

    @State private var draft = ""

    private static let suggestionLimit = 8

    var body: some View {
        let tags = LibraryBrowserModel.commonTags(items)
        VStack(alignment: .leading, spacing: PK.Spacing.s) {
            if !tags.isEmpty {
                FlowLayout {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(name: tag) { model.removeTag(tag, from: items) }
                    }
                }
            }
            TextField("Tags", text: $draft, prompt: Text(tags.isEmpty ? "Add Tags" : "Add Tag"))
                .labelsHidden()
                .focused(focus, equals: .tag)
                .onSubmit(commit)
                .textInputSuggestions(suggestions(excluding: tags), id: \.self) { name in
                    Label(name, systemImage: "tag").textInputCompletion(name)
                }
                .help("Type a tag and press Return")
        }
        .padding(.vertical, PK.Spacing.xxs)
    }

    private func suggestions(excluding applied: [String]) -> [String] {
        let query = draft.trimmingCharacters(in: .whitespaces)
        return model.tags.map(\.name)
            .filter { name in !applied.contains { LibraryTag.isSame($0, name) } }
            .filter { query.isEmpty || $0.localizedStandardContains(query) }
            .prefix(Self.suggestionLimit)
            .map { $0 }
    }

    private func commit() {
        model.addTag(draft, to: items)
        draft = ""
        // Keep the field focused so several tags can be typed in a row.
        focus.wrappedValue = .tag
    }
}

/// A tag as a capsule, with a remove button when `onRemove` is set.
struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: PK.Spacing.xxs) {
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove Tag")
                .accessibilityLabel("Remove \(name)")
            }
        }
        .font(.callout)
        .padding(.leading, PK.Spacing.s)
        .padding(.trailing, onRemove == nil ? PK.Spacing.s : PK.Spacing.xs + PK.Spacing.xxs)
        .padding(.vertical, PK.Spacing.xxs)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .contain)
    }
}
