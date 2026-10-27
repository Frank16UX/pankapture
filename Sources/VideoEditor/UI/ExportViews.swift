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
                    FittingSegmentedPicker("Size", selection: settings.sizeMode) {
                        ForEach(ExportSizeMode.allCases) { Text($0.title).tag($0) }
                    }
                    switch model.exportSettings.sizeMode {
                    case .resolution:
                        Picker("Resolution", selection: settings.resolution) {
                            ForEach(ExportResolution.allCases) { option in
                                Text(sizeLabel(option.title) { $0.sizeMode = .resolution; $0.resolution = option }).tag(option)
                            }
                        }
                    case .percentage:
                        Picker("Percentage", selection: settings.scale) {
                            ForEach(ExportScale.allCases) { option in
                                Text(sizeLabel(option.title) { $0.sizeMode = .percentage; $0.scale = option }).tag(option)
                            }
                        }
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

                if model.exportSettings.format == .mp4 {
                    Section {
                        Toggle(isOn: settings.optimizeForSharing) {
                            Text("Optimize for Sharing")
                            Text("A smaller file that uploads quickly and plays inline in chat apps and email: up to 1080p and 30 fps, at a bitrate tuned for screen recordings.")
                        }
                        if !model.exportSettings.optimizeForSharing {
                            Picker("Quality", selection: settings.quality) {
                                ForEach(ExportQuality.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Frame Rate", selection: settings.frameRate) {
                                ForEach(ExportFrameRate.allCases) { Text($0.title).tag($0) }
                            }
                        }
                    }
                }

                Section {
                    let size = model.exportRenderSize
                    LabeledContent("Output", value: "\(Int(size.width)) × \(Int(size.height)) · \(model.exportFrameRate) fps · \(Format.time(model.outputDuration))")
                        .monospacedDigit()
                    LabeledContent("Estimated Size", value: "≈ \(Format.bytes(model.estimatedExportBytes))")
                        .monospacedDigit()
                        .help(model.exportSettings.format == .mp4
                              ? "Based on the recording's data rate, capped by the encoder's target bitrate."
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

    /// "1080p (1820 × 1080)": a size option with the output it makes, before
    /// the sharing cap (the Output row shows the final size).
    private func sizeLabel(_ title: String, _ option: (inout ExportSettings) -> Void) -> String {
        var settings = model.exportSettings
        settings.optimizeForSharing = false
        option(&settings)
        let size = model.mp4RenderSize(for: settings)
        guard size.width > 0 else { return title }
        return "\(title) (\(Int(size.width)) × \(Int(size.height)))"
    }
}

/// Bottom sheet over the preview: progress with Cancel while exporting, then
/// the result as a draggable file chip with Copy and Show in Finder (VE-10).
/// The editor stays usable underneath, so the sheet says so.
struct ExportStatusView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.exportState != .idle {
                content
                    .padding(PK.Spacing.l)
                    .frame(maxWidth: 620)
                    .pkSheetSurface()
                    .padding(PK.Spacing.m)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(PK.Motion.emphasized, value: model.exportState == .idle)
    }

    @ViewBuilder private var content: some View {
        switch model.exportState {
        case let .running(progress):
            RunningExport(model: model, progress: progress)
        case let .finished(result):
            FinishedExport(model: model, result: result)
        case let .failed(message):
            SheetHeader(symbol: "exclamationmark.triangle.fill", tint: .red, title: "Export Failed", subtitle: message) {
                Button("Dismiss") { model.resetExport() }
            }
        case .idle:
            EmptyView()
        }
    }
}

/// Icon, title + subtitle, and trailing buttons: the top row of every state.
private struct SheetHeader<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: PK.Spacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: PK.Spacing.m)
            HStack(spacing: PK.Spacing.s) { actions }
        }
    }
}

private struct RunningExport: View {
    let model: VideoEditorModel
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            SheetHeader(symbol: "square.and.arrow.up.circle.fill", tint: .accentColor, title: "Exporting…", subtitle: model.exportDescription) {
                Button("Cancel", role: .cancel, action: model.cancelExport)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .accessibilityLabel("Export progress")
            HStack {
                Text("You can keep editing; this export uses the edits from when it started.")
                Spacer(minLength: PK.Spacing.m)
                Text(status)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let percent = Format.percent(progress)
        guard let start = model.exportStartDate, progress > 0.03, progress < 1 else { return percent }
        let elapsed = Date.now.timeIntervalSince(start)
        let remaining = elapsed * (1 - progress) / progress
        return "\(percent) · \(Self.timeLeft(remaining))"
    }

    static func timeLeft(_ seconds: Double) -> String {
        switch seconds {
        case ..<5: "a few seconds left"
        case ..<60: "about \(Int((seconds / 5).rounded()) * 5) s left"
        default: "about \(Int((seconds / 60).rounded())) min left"
        }
    }
}

private struct FinishedExport: View {
    let model: VideoEditorModel
    let result: VideoExportResult

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            SheetHeader(symbol: "checkmark.circle.fill", tint: .green, title: "Export Complete", subtitle: "Drag the file anywhere, or copy it.") {
                Button("Done") { model.resetExport() }
            }
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
                    Spacer(minLength: 0)
                }
                .padding(PK.Spacing.s)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
                .onDrag { NSItemProvider(contentsOf: result.url) ?? NSItemProvider() }
                .help("Drag the exported file anywhere")
                .accessibilityLabel("Exported file \(result.url.lastPathComponent), draggable")

                Button("Copy", systemImage: "doc.on.doc") { model.copyToPasteboard(result.url) }
                    .help("Copy the file to the clipboard")
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder(result.url) }
            }
        }
    }
}
