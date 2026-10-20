import DesignSystem
import SwiftUI

/// Root of the editor window: preview + transport + timeline, inspector on the
/// trailing side, actions in the window toolbar.
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
                .frame(width: 300)
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle(model.sourceURL.deletingPathExtension().lastPathComponent)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportSheet(model: model)
        }
        .task { await model.load() }
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
            Button("Cut", systemImage: "scissors", action: model.cutSelection)
                .disabled(model.selection == nil)
                .help("Cut Selection — ⌘X")
            Button("Add Zoom", systemImage: "plus.magnifyingglass", action: model.addZoomAtPlayhead)
                .disabled(model.media == nil)
                .help("Add Zoom at Playhead — Z")
            Button("Auto Zoom", systemImage: "wand.and.stars", action: model.applyAutoZoom)
                .disabled(model.clickCount == 0)
                .help("Auto Zoom from Recorded Clicks")
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Export…", systemImage: "square.and.arrow.up") { model.isShowingExportSheet = true }
                .disabled(model.media == nil || model.isExporting)
                .help("Export MP4 or GIF — ⌘E")
        }
    }
}
