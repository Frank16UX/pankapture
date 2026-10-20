import AppKit
import DesignSystem
import SwiftUI

/// Export options with a size estimate (VE-8). Starting the export closes the
/// sheet; progress and the result appear in `ExportStatusView` so the editor
/// stays usable while it runs (VE-9).
struct ExportSheet: View {
    @Bindable var model: VideoEditorModel
    @Environment(\.dismiss) private var dismiss

    private var settings: Binding<ExportSettings> { $model.exportSettings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Format", selection: settings.format) {
                    ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch model.exportSettings.format {
                case .mp4:
                    Picker("Resolution", selection: settings.resolution) {
                        ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Quality", selection: settings.quality) {
                        ForEach(ExportQuality.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Frame Rate", selection: settings.frameRate) {
                        ForEach(ExportFrameRate.allCases) { Text($0.title).tag($0) }
                    }
                case .gif:
                    Picker("Width", selection: settings.gif.width) {
                        ForEach(GIFOptions.widthPresets, id: \.self) { width in
                            Text(width.map { "\($0) px" } ?? "Original").tag(width)
                        }
                    }
                    Picker("Frame Rate", selection: settings.gif.fps) {
                        ForEach(GIFOptions.fpsPresets, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    LabeledContent("Loop", value: "Forever")
                }

                Section {
                    let size = model.exportRenderSize
                    LabeledContent("Output", value: "\(Int(size.width)) × \(Int(size.height)) · \(model.exportFrameRate) fps · \(Format.time(model.outputDuration))")
                        .monospacedDigit()
                    LabeledContent("Estimated Size", value: "≈ \(Format.bytes(model.estimatedExportBytes))")
                        .monospacedDigit()
                        .help(model.exportSettings.format == .mp4
                              ? "Based on the recording's data rate, capped by the quality's target bitrate."
                              : "A rough guess: GIF size depends heavily on the content.")
                }
                if case let .failed(message) = model.exportState {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") {
                    model.startExport()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.media == nil || model.isExporting)
            }
            .padding([.horizontal, .bottom], PK.Spacing.l)
        }
        .frame(width: 420)
        .onAppear { model.resetExport() }
    }
}

/// Floating card over the preview: progress with Cancel while exporting, then
/// the result as a draggable file chip with Copy and Show in Finder (VE-10).
struct ExportStatusView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Group {
            switch model.exportState {
            case let .running(progress):
                HStack(spacing: PK.Spacing.m) {
                    ProgressView(value: progress)
                        .frame(width: 180)
                        .accessibilityLabel("Export progress")
                    Text(Format.percent(progress))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Button("Cancel", action: model.cancelExport)
                        .controlSize(.small)
                }
            case let .finished(result):
                FinishedExport(model: model, result: result)
            case let .failed(message):
                HStack(spacing: PK.Spacing.s) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(message).font(.callout).lineLimit(2)
                    Button("Dismiss") { model.resetExport() }
                        .controlSize(.small)
                }
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, PK.Spacing.m)
        .padding(.vertical, PK.Spacing.s)
        .pkSurface()
        .padding(PK.Spacing.m)
        .opacity(model.exportState == .idle ? 0 : 1)
        .animation(PK.Motion.standard, value: model.exportState == .idle)
    }
}

private struct FinishedExport: View {
    let model: VideoEditorModel
    let result: VideoExportResult

    var body: some View {
        HStack(spacing: PK.Spacing.m) {
            HStack(spacing: PK.Spacing.s) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                    Text(result.url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(Format.bytes(result.byteCount)) · \(Int(result.pixelSize.width)) × \(Int(result.pixelSize.height))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(PK.Spacing.xs)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
            .frame(maxWidth: 260)
            .onDrag { NSItemProvider(contentsOf: result.url) ?? NSItemProvider() }
            .help("Drag the exported file anywhere")
            .accessibilityLabel("Exported file \(result.url.lastPathComponent), draggable")

            Button("Copy", systemImage: "doc.on.doc") { model.copyToPasteboard(result.url) }
                .help("Copy the file to the clipboard")
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder(result.url) }
            Button("Close", systemImage: "xmark") { model.resetExport() }
                .labelStyle(.iconOnly)
                .buttonStyle(PKToolButtonStyle())
                .help("Dismiss")
        }
        .controlSize(.small)
    }
}
