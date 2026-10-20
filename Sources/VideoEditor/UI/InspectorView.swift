import DesignSystem
import SwiftUI

/// Trailing inspector: background (VE-6), zoom (VE-4/5), speed (VE-11),
/// audio (VE-7), and the list of cuts (VE-3).
struct InspectorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Form {
            BackgroundSection(model: model)
            ZoomSection(model: model)
            SpeedSection(model: model)
            AudioSection(model: model)
            if !model.project.cuts.isEmpty {
                CutsSection(model: model)
            }
        }
        .formStyle(.grouped)
        .disabled(model.media == nil)
    }
}

/// A slider whose whole drag is one undo step.
private struct EditSlider: View {
    let model: VideoEditorModel
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let set: (inout VideoEditProject, Double) -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: PK.Spacing.s) {
                Slider(
                    value: Binding(get: { value }, set: { newValue in model.edit { set(&$0, newValue) } }),
                    in: range,
                    onEditingChanged: { began in began ? model.beginContinuousEdit() : model.endContinuousEdit() }
                )
                .labelsHidden()
                Text(format(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
    }
}

// MARK: Background

private struct BackgroundSection: View {
    @Bindable var model: VideoEditorModel

    private enum Style: String, CaseIterable, Identifiable {
        case none, color, gradient
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .color: "Color"
            case .gradient: "Gradient"
            }
        }
    }

    private var background: VideoBackground { model.project.background }

    private var style: Binding<Style> {
        Binding {
            switch background.fill {
            case .none: .none
            case .solid: .color
            case .gradient: .gradient
            }
        } set: { style in
            model.edit { project in
                switch style {
                case .none: project.background.fill = .none
                case .color: project.background.fill = .solid(.white)
                case .gradient: project.background.fill = .gradient(.ocean)
                }
            }
        }
    }

    var body: some View {
        Section("Background") {
            Picker("Style", selection: style) {
                ForEach(Style.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            switch background.fill {
            case let .solid(current):
                HStack(spacing: PK.Spacing.s) {
                    ForEach(VideoBackground.solidPresets, id: \.self) { color in
                        Swatch(fill: AnyShapeStyle(color.swiftUIColor), isSelected: color == current) {
                            model.edit { $0.background.fill = .solid(color) }
                        }
                        .accessibilityLabel("Color swatch")
                    }
                    ColorPicker("Custom Color", selection: Binding(
                        get: { current.swiftUIColor },
                        set: { color in model.edit(coalescingKey: "backgroundColor") { $0.background.fill = .solid(RGBAColor(color)) } }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            case let .gradient(current):
                HStack(spacing: PK.Spacing.s) {
                    ForEach(GradientPreset.allCases) { preset in
                        Swatch(fill: AnyShapeStyle(preset.linearGradient), isSelected: preset == current) {
                            model.edit { $0.background.fill = .gradient(preset) }
                        }
                        .help(preset.title)
                        .accessibilityLabel(preset.title)
                    }
                }
            case .none:
                EmptyView()
            }

            Group {
                EditSlider(model: model, title: "Padding", value: background.padding, range: VideoBackground.paddingRange,
                           format: { Format.percent($0) }) { $0.background.padding = $1 }
                EditSlider(model: model, title: "Corners", value: background.cornerRadius, range: VideoBackground.cornerRadiusRange,
                           format: { Format.percent($0) }) { $0.background.cornerRadius = $1 }
                Toggle("Shadow", isOn: Binding(
                    get: { background.shadow },
                    set: { value in model.edit { $0.background.shadow = value } }
                ))
            }
            .disabled(!background.hasFill)

            Picker("Aspect Ratio", selection: Binding(
                get: { background.aspect },
                set: { aspect in model.edit { $0.background.aspect = aspect } }
            )) {
                ForEach(OutputAspect.allCases) { Text($0.title).tag($0) }
            }
        }
    }
}

private struct Swatch: View {
    let fill: AnyShapeStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(.separator, lineWidth: PK.Metrics.hairline))
                .frame(width: PK.Metrics.swatch, height: PK.Metrics.swatch)
                .padding(2)
                .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Zoom

private struct ZoomSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Zoom") {
            if let zoom = model.selectedZoom {
                EditSlider(model: model, title: "Scale", value: zoom.scale, range: ZoomSegment.scaleRange,
                           format: { String(format: "%.1f×", $0) }) { project, scale in
                    var updated = zoom
                    updated.rect = ZoomSegment.rect(center: zoom.center, scale: scale)
                    updated.isAutomatic = false
                    project.updateZoom(updated)
                }
                EditSlider(model: model, title: "Ease", value: zoom.easeDuration, range: ZoomSegment.easeRange,
                           format: { String(format: "%.1fs", $0) }) { project, ease in
                    var updated = zoom
                    updated.easeDuration = ease
                    project.updateZoom(updated)
                }
                Text("Drag the rectangle in the preview to choose the zoomed area. Drag the segment's edges in the timeline to change when it happens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove Zoom", systemImage: "trash", role: .destructive, action: model.removeSelectedZoom)
            }
            Button("Add Zoom at Playhead", systemImage: "plus.magnifyingglass", action: model.addZoomAtPlayhead)
                .help("Add Zoom — Z")
            Button("Auto Zoom from Clicks", systemImage: "wand.and.stars", action: model.applyAutoZoom)
                .disabled(model.clickCount == 0)
                .help("Adds zooms that follow the clicks recorded with this video")
            Text(model.clickCount == 0 ? "No click data was recorded with this video." : "\(model.clickCount) recorded clicks.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Speed

private struct SpeedSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Speed") {
            if model.selection != nil {
                HStack(spacing: PK.Spacing.xs) {
                    ForEach(SpeedSegment.presets, id: \.self) { rate in
                        Button(Format.rate(rate)) { model.setSpeedForSelection(rate) }
                            .accessibilityLabel("Play selection at \(Format.rate(rate))")
                    }
                }
                .controlSize(.small)
            } else {
                Text("Select a range on the timeline to speed it up or slow it down.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.project.speedSegments) { segment in
                HStack {
                    Text("\(Format.time(segment.range.start)) – \(Format.time(segment.range.end))")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(Format.rate(segment.rate)).foregroundStyle(.secondary)
                    Button("Remove", systemImage: "xmark.circle.fill") {
                        model.edit { $0.removeSpeedSegment(id: segment.id) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Audio

private struct AudioSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Audio") {
            if model.audioTracks.isEmpty {
                Text("This video has no audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.audioTracks) { track in
                let volume = model.project.trackVolumes[track.role]
                HStack(spacing: PK.Spacing.s) {
                    Button {
                        model.edit { $0.trackVolumes[track.role].isMuted.toggle() }
                    } label: {
                        Image(systemName: volume.isMuted ? "speaker.slash.fill" : (track.role == .microphone ? "mic.fill" : "speaker.wave.2.fill"))
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(volume.isMuted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .help(volume.isMuted ? "Unmute \(track.label)" : "Mute \(track.label)")
                    .accessibilityLabel(volume.isMuted ? "Unmute \(track.label)" : "Mute \(track.label)")

                    EditSlider(model: model, title: track.label, value: volume.volume, range: 0...1,
                               format: { Format.percent($0) }) { $0.trackVolumes[track.role].volume = $1 }
                        .disabled(volume.isMuted)
                }
            }
        }
    }
}

// MARK: Cuts

private struct CutsSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Cuts") {
            ForEach(model.project.cuts, id: \.self) { cut in
                HStack {
                    Image(systemName: "scissors").foregroundStyle(.red)
                    Text("\(Format.time(cut.start)) – \(Format.time(cut.end))")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Button("Restore", systemImage: "arrow.uturn.backward") { model.removeCut(cut) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Restore this part")
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.selectedCut = cut
                    model.seek(toSource: cut.start)
                }
            }
        }
    }
}
