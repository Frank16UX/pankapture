import AVFoundation
import DesignSystem
import ImageIO
import SwiftUI

/// The inspector's panes (PRD VE-17). One is on screen at a time, so each
/// edit is scanned and applied on its own; a rail on the trailing edge
/// switches them.
enum InspectorSection: String, CaseIterable, Identifiable {
    case autoEdit, transcript, captions, background, zoom, speed, camera, audio, cuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoEdit: "Auto-Edit"
        case .transcript: "Transcript"
        case .captions: "Captions"
        case .background: "Background"
        case .zoom: "Zoom"
        case .speed: "Speed"
        case .camera: "Camera"
        case .audio: "Audio"
        case .cuts: "Cuts"
        }
    }

    var systemImage: String {
        switch self {
        case .autoEdit: "wand.and.sparkles"
        case .transcript: "text.quote"
        case .captions: "captions.bubble"
        case .background: "square.on.square"
        case .zoom: "plus.magnifyingglass"
        case .speed: "gauge.with.dots.needle.67percent"
        case .camera: "web.camera"
        case .audio: "waveform"
        case .cuts: "scissors"
        }
    }
}

/// Auto-Edit's two steps: set up and run the analysis, then review it.
enum AutoEditPage: Hashable {
    case setup, review
}

extension VideoEditorModel {
    /// The panes this recording offers, in rail order.
    var inspectorSections: [InspectorSection] {
        InspectorSection.allCases.filter { section in
            switch section {
            case .autoEdit, .transcript, .captions: isAutoEditAvailable
            case .camera: media?.camera != nil
            default: true
            }
        }
    }

    /// Whether a pane holds edits that change the video (the rail's dot).
    func hasEdits(in section: InspectorSection) -> Bool {
        switch section {
        case .autoEdit: project.autoEdit != nil
        case .transcript: false
        case .camera: !project.cameraLayouts.isEmpty || project.camera?.background.isActive == true
        case .captions: project.captions?.isEnabled == true
        case .background: project.background.hasFill
        case .zoom: !project.zooms.isEmpty
        case .speed: !project.speedSegments.isEmpty
        case .audio: project.voice?.isActive == true
        case .cuts: !project.cuts.isEmpty
        }
    }

    /// ⌘1…⌘9: the pane at that place on the rail.
    func showInspectorSection(number: Int) {
        guard let section = inspectorSections[safe: number - 1] else { return }
        inspectorSection = section
    }
}

/// Trailing inspector: the chosen pane, with the rail beside it.
struct InspectorView: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        let sections = model.inspectorSections
        let current = sections.contains(model.inspectorSection) ? model.inspectorSection : (sections.first ?? .background)
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(current)
                Divider()
                pane(current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: PK.Metrics.inspectorWidth)
            .disabled(model.media == nil)
            Divider()
            InspectorRail(model: model, sections: sections, current: current)
        }
    }

    private func header(_ section: InspectorSection) -> some View {
        HStack(spacing: PK.Spacing.s) {
            Text(section.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: PK.Spacing.s)
            if section == .autoEdit, let layer = model.project.autoEdit {
                Picker("Step", selection: $model.autoEditPage) {
                    Text("Setup").tag(AutoEditPage.setup)
                    Text("Review \(AutoEditReviewPane.itemCount(layer))").tag(AutoEditPage.review)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, PK.Spacing.l)
        .frame(height: 40)
    }

    @ViewBuilder private func pane(_ section: InspectorSection) -> some View {
        switch section {
        case .autoEdit:
            if let layer = model.project.autoEdit, model.autoEditPage == .review {
                AutoEditReviewPane(model: model, layer: layer)
            } else {
                form { AutoEditSection(model: model) }
            }
        case .transcript: TranscriptPanel(model: model)
        case .captions: form { CaptionsSection(model: model) }
        case .background: form { BackgroundSection(model: model) }
        case .zoom: form { ZoomSection(model: model) }
        case .speed: form { SpeedSection(model: model) }
        case .camera: form { CameraSection(model: model) }
        case .audio: form { AudioSection(model: model) }
        case .cuts: form { CutsSection(model: model) }
        }
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form(content: content).formStyle(.grouped)
    }
}

/// The pane switcher: an icon with a short label per pane, so the panes
/// read at a glance. A dot marks panes with edits in the video.
private struct InspectorRail: View {
    @Bindable var model: VideoEditorModel
    let sections: [InspectorSection]
    let current: InspectorSection

    @State private var hovered: InspectorSection?

    var body: some View {
        VStack(spacing: PK.Spacing.xxs) {
            ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                item(section, shortcut: index < 9 ? index + 1 : nil)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PK.Spacing.s)
        .frame(width: PK.Metrics.railWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector panes")
    }

    private func item(_ section: InspectorSection, shortcut: Int?) -> some View {
        let isCurrent = section == current
        return Button {
            model.inspectorSection = section
        } label: {
            VStack(spacing: PK.Spacing.xxs) {
                Image(systemName: section.systemImage)
                    .font(.system(size: PK.Metrics.toolIcon))
                    .frame(height: 20)
                Text(section.title)
                    .font(.system(size: 10, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .frame(width: PK.Metrics.railWidth - PK.Spacing.s, height: PK.Metrics.railItemHeight)
            .background {
                RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                    .fill(isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                          : hovered == section ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            }
            .overlay(alignment: .topTrailing) {
                if model.hasEdits(in: section) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .padding(PK.Spacing.xs + 2)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hovered = section } else if hovered == section { hovered = nil }
        }
        .help(shortcut.map { "\(section.title) — ⌘\($0)" } ?? section.title)
        .accessibilityLabel(section.title)
        .accessibilityValue(model.hasEdits(in: section) ? "Has edits" : "")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
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
        case none, color, gradient, media
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .color: "Color"
            case .gradient: "Gradient"
            case .media: "Media"
            }
        }
    }

    @State private var isDropTargeted = false

    private var background: VideoBackground { model.project.background }

    private var style: Binding<Style> {
        Binding {
            switch background.fill {
            case .none: .none
            case .solid: .color
            case .gradient, .customGradient: .gradient
            case .image, .video: .media
            }
        } set: { style in
            switch style {
            case .none: model.edit { $0.background.fill = .none }
            case .color: model.edit { $0.background.fill = .solid(.white) }
            case .gradient: model.edit { $0.background.fill = .gradient(.ocean) }
            case .media: chooseMedia()
            }
        }
    }

    var body: some View {
        Section("Fill") {
            FittingSegmentedPicker("Style", selection: style) {
                ForEach(Style.allCases) { Text($0.title).tag($0) }
            }

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
            case .gradient, .customGradient:
                gradientControls
            case let .image(url):
                mediaRow(url: url, isVideo: false)
            case let .video(url):
                mediaRow(url: url, isVideo: true)
            case .none:
                Text("The video fills the frame. Choose a fill to frame it with padding, corners and a shadow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { BackgroundLibrary.kind(of: $0) != nil }) else { return false }
            model.setBackgroundMedia(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert("Can't Use This File", isPresented: Binding(
            get: { model.mediaImportError != nil },
            set: { if !$0 { model.mediaImportError = nil } }
        )) {
            Button("OK") { model.mediaImportError = nil }
        } message: {
            Text(model.mediaImportError ?? "")
        }

        Section("Frame") {
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

    // MARK: Gradient

    @ViewBuilder private var gradientControls: some View {
        let current = background.fill
        HStack(spacing: PK.Spacing.s) {
            ForEach(GradientPreset.allCases) { preset in
                Swatch(fill: AnyShapeStyle(preset.linearGradient), isSelected: current == .gradient(preset)) {
                    model.edit { $0.background.fill = .gradient(preset) }
                }
                .help(preset.title)
                .accessibilityLabel(preset.title)
            }
        }
        if let gradient = current.gradient {
            LabeledContent("Colors") {
                HStack(spacing: PK.Spacing.s) {
                    ColorPicker("Start Color", selection: gradientColor(\.start, gradient), supportsOpacity: false)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ColorPicker("End Color", selection: gradientColor(\.end, gradient), supportsOpacity: false)
                }
                .labelsHidden()
            }
            EditSlider(model: model, title: "Angle", value: gradient.angle, range: CustomGradient.angleRange,
                       format: { "\(Int($0.rounded()))°" }) { project, angle in
                var updated = gradient
                updated.angle = angle
                project.background.fill = .customGradient(updated)
            }
        }
    }

    /// Editing a preset's colors turns it into a custom gradient.
    private func gradientColor(_ keyPath: WritableKeyPath<CustomGradient, RGBAColor>, _ gradient: CustomGradient) -> Binding<Color> {
        Binding {
            gradient[keyPath: keyPath].swiftUIColor
        } set: { color in
            var updated = gradient
            updated[keyPath: keyPath] = RGBAColor(color)
            model.edit(coalescingKey: "gradientColor") { $0.background.fill = .customGradient(updated) }
        }
    }

    // MARK: Media

    private func mediaRow(url: URL, isVideo: Bool) -> some View {
        HStack(spacing: PK.Spacing.s) {
            MediaThumbnail(url: url, isVideo: isVideo)
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isDropTargeted ? 2 : PK.Metrics.hairline)
                )
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                Text(isVideo ? "Video" : "Image")
                    .font(.callout)
                Text(isVideo ? "Muted and looped" : "Scaled to fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…", action: chooseMedia)
                .controlSize(.small)
        }
        .help("Drop a picture or movie here to replace it")
    }

    /// Picks a picture or movie for the background; cancelling keeps the current fill.
    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture or a movie for the background"
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setBackgroundMedia(url)
    }
}

/// A small preview of a background picture or the first frame of a movie.
private struct MediaThumbnail: View {
    let url: URL
    let isVideo: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .task(id: url) { image = await Self.thumbnail(url: url, isVideo: isVideo) }
        .accessibilityHidden(true)
    }

    private static func thumbnail(url: URL, isVideo: Bool) async -> CGImage? {
        if isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            return try? await generator.image(at: .zero).image
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
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
        if let zoom = model.selectedZoom {
            Section("Selected Zoom") {
                EditSlider(model: model, title: "Scale", value: zoom.scale, range: ZoomSegment.scaleRange,
                           format: { String(format: "%.1f×", $0) }) { project, scale in
                    var updated = zoom
                    updated.rect = ZoomSegment.rect(center: zoom.center, scale: scale)
                    updated.isAutomatic = false
                    project.updateZoom(updated)
                }
                EditSlider(model: model, title: "Duration", value: zoom.range.duration,
                           range: ZoomSegment.minimumDuration...max(ZoomSegment.minimumDuration + 0.1, model.duration - zoom.range.start),
                           format: { String(format: "%.1fs", $0) }) { project, duration in
                    var updated = zoom
                    updated.range.end = zoom.range.start + duration
                    updated.isAutomatic = false
                    project.updateZoom(updated)
                }
                EditSlider(model: model, title: "Ease", value: zoom.easeDuration, range: ZoomSegment.easeRange,
                           format: { String(format: "%.1fs", $0) }) { project, ease in
                    var updated = zoom
                    updated.easeDuration = ease
                    project.updateZoom(updated)
                }
                Text("Drag the rectangle in the preview to choose the zoomed area. Drag the zoom's ends in the timeline to change when it starts and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove Zoom", systemImage: "trash", role: .destructive, action: model.removeSelectedZoom)
                    .help("Remove Zoom — ⌫")
            }
        }
        Section("Add Zooms") {
            Button("Add Zoom at Playhead", systemImage: "plus.magnifyingglass", action: model.addZoomAtPlayhead)
                .help("Add Zoom — Z")
            Button("Auto Zoom from Clicks", systemImage: "wand.and.stars", action: model.applyAutoZoom)
                .disabled(model.clickCount == 0)
                .help("Adds zooms that follow the clicks recorded with this video")
            Text(model.clickCount == 0 ? "No click data was recorded with this video." : "\(model.clickCount) recorded clicks.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.selectedZoom == nil, !model.project.zooms.isEmpty {
                Text("Click a zoom on the timeline to edit it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Section {
            Toggle(isOn: Binding(
                get: { model.project.zoomFillsFrame },
                set: { value in model.edit { $0.zoomFillsFrame = value } }
            )) {
                Text("Zoom Fills the Frame")
                Text("Zoom past the padding and background until the zoomed area fills the whole video.")
            }
        }
    }
}

// MARK: Speed

private struct SpeedSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Selection") {
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
        }
        Section("Speed Changes") {
            if model.project.speedSegments.isEmpty {
                Text("None yet.")
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

// MARK: Camera

/// The webcam layer (ADR-25): only for recordings with a camera track.
private struct CameraSection: View {
    @Bindable var model: VideoEditorModel

    private var camera: CameraOverlay { model.project.camera ?? .standard }
    /// Shown somewhere: as usual, or where a layout fills the frame with it.
    private var showsCamera: Bool {
        CameraLayoutMath.showsCamera(segments: model.project.cameraLayouts, isVisible: camera.isVisible)
    }

    private func set(_ change: @escaping (inout CameraOverlay) -> Void) {
        model.edit { project in
            var camera = project.camera ?? .standard
            change(&camera)
            project.camera = camera
        }
    }

    var body: some View {
        Section {
            Toggle("Show Camera", isOn: Binding(get: { camera.isVisible }, set: { value in set { $0.isVisible = value } }))
        }
        CameraLayoutSection(model: model)
        Section("Look") {
            Group {
                FittingSegmentedPicker("Shape", selection: Binding(get: { camera.shape }, set: { shape in set { $0.shape = shape } })) {
                    ForEach(CameraOverlay.Shape.allCases) { Text($0.title).tag($0) }
                }
                if camera.shape.hasCorners {
                    EditSlider(model: model, title: "Roundness", value: camera.roundness, range: CameraOverlay.roundnessRange,
                               format: { Format.percent($0 / CameraOverlay.roundnessRange.upperBound) }) { project, roundness in
                        var camera = project.camera ?? .standard
                        camera.roundness = roundness
                        project.camera = camera
                    }
                }
                EditSlider(model: model, title: "Size", value: camera.size, range: CameraOverlay.sizeRange,
                           format: { Format.percent($0) }) { project, size in
                    var camera = project.camera ?? .standard
                    camera.size = size
                    project.camera = camera
                }
            }
            .disabled(!camera.isVisible)
            Toggle("Mirror", isOn: Binding(get: { camera.isMirrored }, set: { value in set { $0.isMirrored = value } }))
                .disabled(!showsCamera)
        }
        if model.isAutoEditAvailable {
            Section("Background") {
                CameraBackgroundControls(
                    background: Binding(get: { camera.background }, set: { value in
                        model.edit(coalescingKey: "cameraBackground") { project in
                            var camera = project.camera ?? .standard
                            camera.background = value
                            project.camera = camera
                        }
                    }),
                    onEditingChanged: { began in began ? model.beginContinuousEdit() : model.endContinuousEdit() }
                )
            }
            .disabled(!showsCamera)
        }
        Section("Position") {
            Group {
                Button("Reset Position", systemImage: "arrow.counterclockwise") {
                    let recorded = model.sidecar?.camera.map(CameraOverlay.init) ?? .standard
                    set { $0.center = recorded.center; $0.size = recorded.size }
                }
                Text("Drag the camera in the preview to move it, or its corner to resize it. Zooms leave it in place unless the zoom fills the frame.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!camera.isVisible)
        }
    }
}

/// Camera Only and Screen Only stretches (CAM-6): add at the playhead, or
/// change the one selected on the timeline.
private struct CameraLayoutSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section {
            if let segment = model.selectedCameraLayout {
                FittingSegmentedPicker("Layout", selection: Binding(get: { segment.layout }, set: { model.setSelectedCameraLayout($0) })) {
                    ForEach(CameraLayoutSegment.Layout.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Time") {
                    Text("\(Format.time(segment.range.start)) – \(Format.time(segment.range.end))").monospacedDigit()
                }
                Button("Remove Layout", systemImage: "trash", role: .destructive, action: model.removeSelectedCameraLayout)
                    .help("Remove this layout — ⌫")
            } else {
                HStack(spacing: PK.Spacing.s) {
                    ForEach(CameraLayoutSegment.Layout.allCases) { layout in
                        Button(layout.title, systemImage: layout.symbol) { model.addCameraLayoutAtPlayhead(layout) }
                            .help("\(layout.title) from the playhead")
                    }
                }
            }
        } header: {
            Text("Layout")
        } footer: {
            Text("Fill the frame with the camera, or show only the screen, from the playhead. The camera eases between layouts; drag a layout on the timeline to move it or change its length.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Audio

private struct AudioSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section("Tracks") {
            if model.audioTracks.isEmpty {
                Text("This video has no audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.visibleAudioTracks) { track in
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
            if !model.silentAudioTracks.isEmpty {
                Text("\(ListFormatter.localizedString(byJoining: model.silentAudioTracks.map(\.label))) recorded only silence and is hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if model.isAutoEditAvailable, model.microphoneTrack != nil {
            Section("Voice") {
                VoiceControls(model: model)
            }
        }
    }
}

/// Noise removal and loudness for the microphone (PRD AU-1–AU-3).
private struct VoiceControls: View {
    @Bindable var model: VideoEditorModel

    private var voice: VoiceProcessing { model.project.voice ?? VoiceProcessing() }

    var body: some View {
        FittingSegmentedPicker("Noise removal", selection: Binding(
            get: { voice.noiseReduction },
            set: { value in model.edit { $0.voice = VoiceProcessing(noiseReduction: value, normalizes: voice.normalizes) } }
        )) {
            ForEach(VoiceProcessing.NoiseReduction.allCases) { Text($0.title).tag($0) }
        }
        .help("Removes background noise from the microphone. System audio isn't touched.")
        Toggle("Even out loudness", isOn: Binding(
            get: { voice.normalizes },
            set: { value in model.edit { $0.voice = VoiceProcessing(noiseReduction: voice.noiseReduction, normalizes: value) } }
        ))
        .help("Brings the voice to a steady −16 LUFS, a common level for online video")
        switch model.voiceState {
        case .processing(let fraction):
            HStack(spacing: PK.Spacing.s) {
                ProgressView(value: fraction).frame(maxWidth: 120)
                Text("Cleaning up the voice…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        case .idle:
            EmptyView()
        }
    }
}

// MARK: Cuts

private struct CutsSection: View {
    @Bindable var model: VideoEditorModel

    var body: some View {
        Section {
            if model.project.cuts.isEmpty {
                Text("No cuts yet. Drag across the filmstrip and press ⌫, or split at the playhead (S) and delete a part.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                .listRowBackground(model.selectedCut == cut ? Color.accentColor.opacity(0.15) : nil)
                .onTapGesture {
                    model.selectedCut = cut
                    model.revealOnTimeline(cut)
                    model.seek(toSource: cut.start)
                }
            }
        }
    }
}
