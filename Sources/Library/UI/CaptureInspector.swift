import AppKit
import DesignSystem
import SwiftUI

/// Metadata for the selection (HI-2/HI-4): date, size, dimensions, duration,
/// location, and recognized text with a Copy button.
struct CaptureInspector: View {
    let model: LibraryBrowserModel

    var body: some View {
        let selected = model.selectedItems
        Group {
            if selected.count == 1, let item = selected.first {
                SingleItemInspector(item: item, model: model)
            } else if selected.count > 1 {
                ContentUnavailableView {
                    Label("\(selected.count) Captures", systemImage: "square.stack")
                } description: {
                    Text(LibraryFormat.bytes(selected.reduce(0) { $0 + $1.fileByteSize }))
                        .monospacedDigit()
                }
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

    var body: some View {
        Form {
            Section {
                ThumbnailView(url: item.thumbnailURL, version: item.editedAt, kind: item.kind)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous))
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
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
