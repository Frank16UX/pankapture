import AppKit
import DesignSystem
import SwiftUI

/// Blur, replace, or remove what's behind the person in the camera (PRD
/// CAM-1, CAM-2). Used by the inspector and by Settings ▸ Recording for the
/// default (CAM-3).
public struct CameraBackgroundControls: View {
    @Binding private var background: CameraBackground
    /// Slider drags begin (`true`) and end (`false`), so one drag is one undo step.
    private let onEditingChanged: (Bool) -> Void

    public init(background: Binding<CameraBackground>, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _background = background
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        FittingSegmentedPicker("Background", selection: $background.effect) {
            ForEach(CameraBackground.Effect.allCases) { Text($0.title).tag($0) }
        }
        switch background.effect {
        case .none:
            EmptyView()
        case .blur:
            slider("Blur", value: $background.blurAmount)
        case .replace:
            matteControls
            replacementControls
        case .remove:
            matteControls
            Toggle("Keep the Shape", isOn: $background.keepsShape)
                .help("Show the person inside the camera's shape, instead of on their own")
        }
        if background.isActive {
            Text(background.effectiveMatte == .person
                 ? "The person is found on this Mac. Works best with good light and a plain background."
                 : "Pick the screen's color from the video, then raise the tolerance until the screen is gone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var matteControls: some View {
        Picker("Separate by", selection: $background.matte) {
            ForEach(CameraBackground.Matte.allCases) { Text($0.title).tag($0) }
        }
        if background.matte == .greenScreen {
            ColorPicker("Screen Color", selection: Binding(
                get: { background.keyColor.swiftUIColor },
                set: { background.keyColor = RGBAColor($0) }
            ), supportsOpacity: false)
            if !background.keyColorIsUsable {
                Label("This color is too gray to tell apart from you. Pick the screen's color.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            slider("Tolerance", value: $background.tolerance)
            slider("Remove Spill", value: $background.spill)
        }
    }

    @ViewBuilder private var replacementControls: some View {
        if let url = background.imageURL {
            LabeledContent("Picture") {
                HStack(spacing: PK.Spacing.s) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: choosePicture)
                        .controlSize(.small)
                    Button("Use a Color", systemImage: "xmark.circle.fill") { background.imageURL = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Use a color instead of the picture")
                }
            }
        } else {
            ColorPicker("Color", selection: Binding(
                get: { background.color.swiftUIColor },
                set: { background.color = RGBAColor($0) }
            ), supportsOpacity: false)
            LabeledContent("Picture") {
                Button("Choose…", action: choosePicture)
                    .controlSize(.small)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent {
            HStack(spacing: PK.Spacing.s) {
                Slider(value: value, in: 0...1, onEditingChanged: onEditingChanged)
                    .labelsHidden()
                Text(Format.percent(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: PK.Metrics.sliderValueWidth, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
        .accessibilityLabel(title)
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture to show behind you"
        panel.prompt = "Use Picture"
        // Copied into the app's backgrounds, so moving the original doesn't lose it.
        guard panel.runModal() == .OK, let url = panel.url,
              case let .image(copy) = try? BackgroundLibrary.importFile(url) else { return }
        background.imageURL = copy
    }
}
