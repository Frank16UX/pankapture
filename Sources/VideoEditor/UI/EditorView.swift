import DesignSystem
import SwiftUI

/// The editor window's content (VE-18): a skeleton of the editor at once,
/// then the editor. The recording starts loading right away, while the
/// editor is built; the first editor of a launch takes a moment to build.
struct EditorWindowContent: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Group {
            if model.isEditorMounted {
                EditorView(model: model)
            } else {
                EditorSkeleton(model: model)
            }
        }
        .task { await model.load() }
    }
}

/// Root of the editor window: preview + transport + timeline, inspector (with
/// its pane rail) on the trailing side, actions in the window toolbar.
struct EditorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: PK.Spacing.m) {
                PreviewArea(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { ExportStatusView(model: model) }
                TransportBar(model: model)
                TimelineView(model: model)
            }
            .padding(PK.Spacing.l)

            Divider()

            InspectorView(model: model)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .navigationTitle(model.sourceURL.deletingPathExtension().lastPathComponent)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportSheet(model: model)
        }
        .onAppear { model.editorDidAppear() }
        .alert("Couldn't Save the Edits", isPresented: Binding(
            get: { model.saveError != nil },
            set: { if !$0 { model.saveError = nil } }
        )) {
            Button("OK") { model.saveError = nil }
        } message: {
            Text(model.saveError ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                .disabled(!model.canUndo)
                .help("Undo — ⌘Z")
            Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                .disabled(!model.canRedo)
                .help("Redo — ⇧⌘Z")
        }
        ToolbarItemGroup {
            Button("Split", systemImage: "scissors", action: model.splitAtPlayhead)
                .disabled(model.media == nil)
                .help("Split at Playhead — S")
            Button("Delete", systemImage: "trash", action: model.deleteSelected)
                .disabled(model.selection == nil && model.selectedZoomID == nil && model.selectedCameraLayoutID == nil)
                .help("Delete the Selected Segment or Zoom — ⌫")
            Button("Add Zoom", systemImage: "plus.magnifyingglass", action: model.addZoomAtPlayhead)
                .disabled(model.media == nil)
                .help("Add Zoom at Playhead — Z")
            Button("Auto Zoom", systemImage: "wand.and.stars", action: model.applyAutoZoom)
                .disabled(model.clickCount == 0)
                .help("Auto Zoom from Recorded Clicks")
        }
        ToolbarItem {
            Button("Save", systemImage: "square.and.arrow.down") { model.save() }
                .disabled(!model.hasUnsavedChanges)
                .help("Save Edits — ⌘S")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Export…", systemImage: "square.and.arrow.up") { model.isShowingExportSheet = true }
                .disabled(model.media == nil || model.isExporting)
                .help("Export MP4 or GIF — ⌘E")
        }
    }
}

/// The editor's layout in placeholder shapes, while the editor is built.
private struct EditorSkeleton: View {
    let model: VideoEditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: PK.Spacing.m) {
                RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                    .fill(.black)
                    .overlay { LoadingStatus(model: model) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bar(height: 28)
                VStack(spacing: PK.Spacing.xs) {
                    bar(height: TimelineView.rulerHeight)
                    bar(height: TimelineView.filmstripHeight)
                    bar(height: TimelineView.zoomLaneHeight)
                    bar(height: TimelineView.audioLaneHeight)
                    bar(height: TimelineView.audioLaneHeight)
                }
            }
            .padding(PK.Spacing.l)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: PK.Spacing.m) {
                    bar(height: 20).frame(width: 120)
                    bar(height: 120)
                    bar(height: 80)
                    Spacer()
                }
                .padding(PK.Spacing.l)
                .frame(width: PK.Metrics.inspectorWidth)
                Divider()
                VStack(spacing: PK.Spacing.s) {
                    ForEach(0..<6, id: \.self) { _ in
                        bar(height: PK.Metrics.railItemHeight - PK.Spacing.s)
                    }
                    Spacer()
                }
                .padding(PK.Spacing.xs)
                .frame(width: PK.Metrics.railWidth)
            }
        }
        .frame(minWidth: 1000, minHeight: 600)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Opening the editor")
    }

    private func bar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
            .fill(.quaternary)
            .frame(height: height)
    }
}

/// A spinner and what opening is waiting on, in the preview. Shown only
/// once the wait is noticeable, so quick opens don't flash it.
struct LoadingStatus: View {
    let model: VideoEditorModel
    @State private var isShown = false

    var body: some View {
        VStack(spacing: PK.Spacing.m) {
            ProgressView().controlSize(.large)
            Text(model.loadingStage.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        // The preview is black in either appearance.
        .environment(\.colorScheme, .dark)
        .opacity(isShown ? 1 : 0)
        .animation(PK.Motion.standard, value: isShown)
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            isShown = true
        }
    }
}
