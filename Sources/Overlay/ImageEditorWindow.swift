import Annotation
import AppCore
import AppKit
import Capture
import Carbon.HIToolbox
import DesignSystem
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What the editor window hands back to the app.
public struct EditedImage: @unchecked Sendable {
    // @unchecked: immutable value wrapping CGImages (immutable CF types).

    /// Final output: annotations burned in, background applied.
    public let image: CGImage
    /// The capture without annotations or background.
    public let original: CGImage
    public let annotations: AnnotationDocument
    public let beautify: BeautifyOptions
    public let scale: CGFloat
}

public enum EditorOutputAction: Sendable {
    case copy, save, saveAs, print, pin, shared
}

/// Full annotation editor window (ED-1, ED-2): every inline tool on a
/// zoomable canvas, plus background/beautify options.
@MainActor
public final class ImageEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [ImageEditorWindowController] = []
    /// An editor was built in this launch (or `warmUp()` ran), so the next
    /// one builds quickly and needs no placeholder.
    private static var isEditorWarm = false

    /// The capture-history item being edited, if any; opening it again
    /// brings this window forward instead of a second editor.
    private let documentID: UUID?
    private let model: ImageEditorModel
    private let onOutput: (EditorOutputAction, EditedImage) -> Void
    private var sharePicker: NSSharingServicePicker?
    private var sharingResult: EditedImage?

    /// Opens a new editor window, or brings forward the one already editing
    /// `documentID`.
    /// - Parameter annotations: in image-local points (top-left of `image`).
    public static func open(
        image: CGImage,
        scale: CGFloat,
        annotations: AnnotationDocument = AnnotationDocument(),
        beautify: BeautifyOptions? = nil,
        documentID: UUID? = nil,
        onOutput: @escaping (EditorOutputAction, EditedImage) -> Void
    ) {
        if let documentID, let existing = open.first(where: { $0.documentID == documentID }) {
            NSApp.activate()
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let signpost = Log.signposter.beginInterval("openImageEditor")
        defer { Log.signposter.endInterval("openImageEditor", signpost) }
        let start = ContinuousClock.now
        let model = ImageEditorModel(image: image, scale: scale, annotations: annotations, beautify: beautify)
        model.isEditorMounted = isEditorWarm
        let controller = ImageEditorWindowController(model: model, documentID: documentID, onOutput: onOutput)
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
        if model.isEditorMounted {
            logReady(since: start)
        } else {
            // The capture shows at once; the tools follow a couple of frames
            // later (the first editor of a launch takes a moment to build).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                model.isEditorMounted = true
                isEditorWarm = true
                logReady(since: start)
            }
        }
    }

    /// Logs how long opening took, after the next layout and drawing.
    private static func logReady(since start: ContinuousClock.Instant) {
        DispatchQueue.main.async {
            let elapsed = ContinuousClock.now - start
            Log.overlay.info("Image editor ready in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        }
    }

    /// Builds an editor off screen, once, so the first one the user opens
    /// comes up at once (ADR-42). Holds the main thread for most of a second:
    /// call it while the app is idle.
    public static func warmUp() {
        guard !isEditorWarm, open.isEmpty,
              let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return }
        let signpost = Log.signposter.beginInterval("warmUpImageEditor")
        defer { Log.signposter.endInterval("warmUpImageEditor", signpost) }
        let start = ContinuousClock.now
        let model = ImageEditorModel(image: image, scale: 1, annotations: AnnotationDocument(), beautify: nil)
        model.isEditorMounted = true
        let controller = ImageEditorWindowController(model: model, documentID: nil) { _, _ in }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.window?.close()
        isEditorWarm = true
        let elapsed = ContinuousClock.now - start
        Log.overlay.info("Image editor warmed up in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    private init(model: ImageEditorModel, documentID: UUID?, onOutput: @escaping (EditorOutputAction, EditedImage) -> Void) {
        self.model = model
        self.documentID = documentID
        self.onOutput = onOutput

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "Edit Capture"
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        let hosting = NSHostingController(rootView: ImageEditorRoot(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // A toolbar from the start, so the title bar doesn't grow when the
        // editor's own toolbar arrives after the placeholder.
        window.toolbar = NSToolbar(identifier: "imageEditor.placeholder")
        window.contentViewController = hosting
        window.setContentSize(CGSize(width: 1100, height: 760))

        model.perform = { [weak self] action in self?.run(action) }
        model.editorState.perform = { [weak self] command in
            switch command {
            case .undo: self?.model.editorState.undo()
            case .redo: self?.model.editorState.redo()
            case .copy: self?.run(.copy)
            case .save: self?.run(.save)
            case .saveAs: self?.run(.saveAs)
            case .print: self?.run(.print)
            case .pin: self?.run(.pin)
            case .close: self?.close()
            default: break
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func run(_ action: EditorOutputAction) {
        model.commitEditing()
        guard let result = model.render() else { return }
        if action == .shared { return }
        onOutput(action, result)
    }

    public func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }

    /// Share sheet anchored to the toolbar button (called from SwiftUI).
    fileprivate func share(from view: NSView) {
        model.commitEditing()
        guard let result = model.render(), let url = try? ImageOutput.writeTemporary(result.image, scale: result.scale) else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        sharePicker = picker
        sharingResult = result
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

extension ImageEditorWindowController: NSSharingServicePickerDelegate {
    public nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let didChoose = service != nil
        MainActor.assumeIsolated {
            if didChoose, let result = sharingResult { onOutput(.shared, result) }
            sharingResult = nil
            sharePicker = nil
        }
    }
}

// MARK: - Model

@MainActor
@Observable
final class ImageEditorModel {
    let image: CGImage
    let scale: CGFloat
    let editorState = EditorState()
    var beautify: BeautifyOptions {
        didSet {
            if let data = try? JSONEncoder().encode(beautify) {
                UserDefaults.standard.set(data, forKey: PreferenceKey.editorBeautify)
            }
            layoutDidChange?()
        }
    }
    var zoom: CGFloat = 1
    /// The tools are built; until then the window shows the capture alone.
    var isEditorMounted = false
    /// Why the last picture couldn't be used as the background.
    var mediaImportError: String?
    /// The canvas follows the window: it refits when the background or the
    /// window changes size, until the user zooms by hand.
    @ObservationIgnored var fitsCanvas = true
    /// The decoded background picture, for the URL it was read from.
    @ObservationIgnored private var loadedPicture: (url: URL, image: CGImage?)?

    @ObservationIgnored var perform: ((EditorOutputAction) -> Void)?
    @ObservationIgnored var layoutDidChange: (() -> Void)?
    /// The canvas changed size (background on/off, padding, aspect).
    @ObservationIgnored var canvasDidResize: (() -> Void)?
    @ObservationIgnored var commitEditingHandler: (() -> Void)?
    @ObservationIgnored var zoomHandler: ((ZoomCommand) -> Void)?

    enum ZoomCommand { case zoomIn, zoomOut, actualSize, fit }

    init(image: CGImage, scale: CGFloat, annotations: AnnotationDocument, beautify: BeautifyOptions?) {
        self.image = image
        self.scale = scale
        self.beautify = beautify
            ?? UserDefaults.standard.data(forKey: PreferenceKey.editorBeautify)
                .flatMap { try? JSONDecoder().decode(BeautifyOptions.self, from: $0) }
                .map { var stored = $0; stored.isEnabled = false; return stored }
            ?? BeautifyOptions()
        for annotation in annotations.annotations {
            editorState.add(annotation)
        }
        // Loading isn't an edit the user should be able to undo.
        editorState.clearHistory()
    }

    var imageSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    func commitEditing() { commitEditingHandler?() }

    func render() -> EditedImage? {
        let document = editorState.document
        guard let annotated = document.isEmpty ? image : AnnotationRenderer.render(document, onto: image, scale: scale),
              let final = Beautifier.render(annotated, scale: scale, options: beautify,
                                            backgroundImage: backgroundPicture()) else { return nil }
        return EditedImage(image: final, original: image, annotations: document, beautify: beautify, scale: scale)
    }

    /// The picture for an image background, decoded once per file.
    func backgroundPicture() -> CGImage? {
        guard let url = beautify.background.imageURL else { return nil }
        if let loadedPicture, loadedPicture.url == url { return loadedPicture.image }
        // Capped so a huge photo doesn't cost hundreds of MB; still sharp on
        // a padded 5K canvas.
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 6144,
                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
        let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
        if image == nil { Log.overlay.error("Background picture unreadable: \(url.lastPathComponent, privacy: .public)") }
        loadedPicture = (url, image)
        return image
    }

    /// Uses a private copy of the picture at `url` as the background.
    func setBackgroundPicture(_ url: URL) {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else {
            mediaImportError = "Choose a picture file for the background."
            return
        }
        do {
            beautify.background = .image(try BackgroundFiles.copyIn(url))
            beautify.isEnabled = true
        } catch {
            mediaImportError = error.localizedDescription
            Log.overlay.error("Background import failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - SwiftUI shell

private struct ImageEditorRoot: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        if model.isEditorMounted {
            ImageEditorContent(model: model)
        } else {
            ImageEditorPlaceholder(model: model)
        }
    }
}

/// The capture where the canvas will be, with room for the tools and the
/// background options, while the editor is built.
private struct ImageEditorPlaceholder: View {
    let model: ImageEditorModel

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: PK.Metrics.toolButton + 2 * PK.Spacing.m)
            Image(decorative: model.image, scale: model.scale)
                .resizable()
                .scaledToFit()
                .padding(PK.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear
                .frame(width: PK.Metrics.floatingPanelWidth + 2 * PK.Spacing.m)
        }
        .background(.background.secondary)
    }
}

private struct ImageEditorContent: View {
    @Bindable var model: ImageEditorModel

    var body: some View {
        // Both bars float on the canvas background, so the window reads as
        // one surface under a full-width toolbar.
        HStack(spacing: 0) {
            ToolsBar(state: model.editorState)
                .padding(PK.Spacing.m)
                .frame(maxHeight: .infinity, alignment: .top)

            EditorCanvasRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            BeautifyPanel(model: model)
                .padding(PK.Spacing.m)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(.background.secondary)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.zoomHandler?(.zoomOut) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                    .help("Zoom Out — ⌘−")
                Button { model.zoomHandler?(.fit) } label: { Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                    .help("Zoom to Fit — ⌘9")
                Button { model.zoomHandler?(.zoomIn) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                    .help("Zoom In — ⌘+")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.perform?(.pin) } label: { Label("Pin to Screen", systemImage: "pin") }
                    .help("Pin to Screen")
                ShareButton(model: model)
                Button { model.perform?(.copy) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .help("Copy — ⌘C")
                Button { model.perform?(.save) } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .help("Save — ⌘S")
            }
        }
    }
}

/// Share needs an NSView anchor for the picker.
private struct ShareButton: NSViewRepresentable {
    let model: ImageEditorModel

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                              target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = "Share"
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        @objc func share(_ sender: NSButton) {
            (sender.window?.windowController as? ImageEditorWindowController)?.share(from: sender)
        }
    }
}

/// Background options floating beside the canvas, like the tools bar on the
/// other side: just the switch while the background is off, every option
/// once it's on.
private struct BeautifyPanel: View {
    @Bindable var model: ImageEditorModel
    /// The last fill of each style, so switching back restores it.
    @State private var recentFills: [FillStyle: BeautifyOptions.Background] = [:]
    @State private var isDropTargeted = false

    private enum FillStyle: String, CaseIterable, Identifiable {
        case color, gradient, media
        var id: String { rawValue }
        var title: String {
            switch self {
            case .color: "Color"
            case .gradient: "Gradient"
            case .media: "Media"
            }
        }

        init(_ background: BeautifyOptions.Background) {
            switch background {
            case .transparent, .solid: self = .color
            case .gradient, .customGradient: self = .gradient
            case .image: self = .media
            }
        }
    }

    private var options: BeautifyOptions { model.beautify }

    var body: some View {
        VStack(alignment: .leading, spacing: PK.Spacing.m) {
            HStack {
                Text("Background").font(.headline)
                Spacer(minLength: PK.Spacing.s)
                Toggle("Background", isOn: $model.beautify.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .help("Places the capture on a padded background with rounded corners and a shadow")

            if options.isEnabled {
                Divider()
                controls
                    .transition(.opacity)
            }
        }
        .padding(PK.Spacing.m)
        .frame(width: PK.Metrics.floatingPanelWidth)
        .pkSurface()
        .animation(PK.Motion.standard, value: options.isEnabled)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else {
                return false
            }
            model.setBackgroundPicture(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: options.background, initial: true) { _, background in
            recentFills[FillStyle(background)] = background
        }
        .alert("Can't Use This File", isPresented: Binding(
            get: { model.mediaImportError != nil },
            set: { if !$0 { model.mediaImportError = nil } }
        )) {
            Button("OK") { model.mediaImportError = nil }
        } message: {
            Text(model.mediaImportError ?? "")
        }
    }

    /// One grid for every section, so labels line up in a single column.
    /// Views outside a `GridRow` span the panel.
    private var controls: some View {
        Grid(alignment: .leading, horizontalSpacing: PK.Spacing.m, verticalSpacing: PK.Spacing.s) {
            sectionTitle("Fill")
            FittingSegmentedPicker("Fill", selection: fillStyle) {
                ForEach(FillStyle.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()

            switch FillStyle(options.background) {
            case .color: colorControls
            case .gradient: gradientControls
            case .media: mediaControls
            }

            Divider().padding(.vertical, PK.Spacing.xs)

            sectionTitle("Layout")
            GridRow {
                Text("Padding")
                Slider(value: $model.beautify.padding, in: 0...240, step: 4)
                    .controlSize(.small)
                    .accessibilityLabel("Padding")
            }
            GridRow {
                Text("Corners")
                Slider(value: $model.beautify.cornerRadius, in: 0...48, step: 1)
                    .controlSize(.small)
                    .accessibilityLabel("Corners")
            }
            GridRow {
                Text("Shadow")
                Toggle("Shadow", isOn: $model.beautify.shadow)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text("Aspect")
                Picker("Aspect", selection: $model.beautify.aspect) {
                    ForEach(BeautifyOptions.Aspect.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Picking a style restores its last fill; Media asks for a picture first.
    private var fillStyle: Binding<FillStyle> {
        Binding {
            FillStyle(options.background)
        } set: { style in
            if let recent = recentFills[style] {
                model.beautify.background = recent
                return
            }
            switch style {
            case .color: model.beautify.background = .solid(.white)
            case .gradient: model.beautify.background = .gradient(.ocean)
            case .media: chooseMedia()
            }
        }
    }

    // MARK: Color

    @ViewBuilder private var colorControls: some View {
        LazyVGrid(columns: swatchColumns(4), spacing: PK.Spacing.s) {
            swatch(isSelected: options.background == .transparent) {
                model.beautify.background = .transparent
            } fill: {
                RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "square.dashed").foregroundStyle(.secondary))
            }
            .help("Transparent")
            .accessibilityLabel("Transparent")
            ForEach(BeautifyOptions.solidPresets, id: \.self) { color in
                swatch(isSelected: options.background == .solid(color)) {
                    model.beautify.background = .solid(color)
                } fill: {
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .fill(Color(cgColor: color.cgColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                                .strokeBorder(.separator, lineWidth: PK.Metrics.hairline)
                        )
                }
                .accessibilityLabel("Color swatch")
            }
        }
        GridRow {
            Text("Custom")
            ColorPicker("Custom Color", selection: solidColor, supportsOpacity: false)
                .labelsHidden()
                .gridColumnAlignment(.trailing)
        }
    }

    private var solidColor: Binding<Color> {
        Binding {
            if case let .solid(color) = options.background { return Color(cgColor: color.cgColor) }
            return .white
        } set: { color in
            model.beautify.background = .solid(RGBAColor(color))
        }
    }

    // MARK: Gradient

    @ViewBuilder private var gradientControls: some View {
        LazyVGrid(columns: swatchColumns(3), spacing: PK.Spacing.s) {
            ForEach(BeautifyOptions.GradientPreset.allCases) { preset in
                swatch(isSelected: options.background == .gradient(preset)) {
                    model.beautify.background = .gradient(preset)
                } fill: {
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .fill(BeautifyOptions.Gradient(preset).linearGradient)
                }
                .help(preset.title)
                .accessibilityLabel("\(preset.title) gradient")
            }
        }
        if let gradient = options.background.gradient {
            GridRow {
                Text("Colors")
                HStack(spacing: PK.Spacing.s) {
                    ColorPicker("Start Color", selection: gradientColor(\.start, gradient), supportsOpacity: false)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    ColorPicker("End Color", selection: gradientColor(\.end, gradient), supportsOpacity: false)
                }
                .labelsHidden()
                .gridColumnAlignment(.trailing)
            }
            GridRow {
                Text("Angle")
                HStack(spacing: PK.Spacing.s) {
                    Slider(value: gradientAngle(gradient), in: BeautifyOptions.Gradient.angleRange)
                        .controlSize(.small)
                        .accessibilityLabel("Angle")
                    Text("\(Int(gradient.angle.rounded()))°")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: PK.Spacing.xxl, alignment: .trailing)
                }
            }
        }
    }

    /// Editing a preset's colors or angle turns it into a custom gradient.
    private func gradientColor(_ keyPath: WritableKeyPath<BeautifyOptions.Gradient, RGBAColor>,
                               _ gradient: BeautifyOptions.Gradient) -> Binding<Color> {
        Binding {
            Color(cgColor: gradient[keyPath: keyPath].cgColor)
        } set: { color in
            var updated = gradient
            updated[keyPath: keyPath] = RGBAColor(color)
            model.beautify.background = .customGradient(updated)
        }
    }

    private func gradientAngle(_ gradient: BeautifyOptions.Gradient) -> Binding<Double> {
        Binding {
            gradient.angle
        } set: { angle in
            var updated = gradient
            updated.angle = angle.rounded()
            model.beautify.background = .customGradient(updated)
        }
    }

    // MARK: Media

    @ViewBuilder private var mediaControls: some View {
        HStack(spacing: PK.Spacing.s) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let picture = model.backgroundPicture() {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                    .strokeBorder(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isDropTargeted ? 2 : PK.Metrics.hairline)
            )
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                Text("Image").font(.callout)
                Text("Scaled to fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Choose…", action: chooseMedia)
                .controlSize(.small)
        }
        .help("Drop a picture here to replace it")
    }

    /// Picks a picture for the background; cancelling keeps the current fill.
    private func chooseMedia() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the background"
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setBackgroundPicture(url)
    }

    // MARK: Swatches

    private func swatchColumns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: PK.Spacing.s), count: count)
    }

    private func swatch(isSelected: Bool, action: @escaping () -> Void, @ViewBuilder fill: () -> some View) -> some View {
        Button(action: action) {
            fill()
                .frame(height: PK.Metrics.toolButton)
                .overlay(
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension RGBAColor {
    /// The sRGB components of a color from a picker.
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}

private extension BeautifyOptions.Gradient {
    /// The gradient as drawn on the canvas, for swatches.
    var linearGradient: LinearGradient {
        let radians = angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        return LinearGradient(colors: [Color(cgColor: start.cgColor), Color(cgColor: end.cgColor)],
                              startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                              endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy))
    }
}

// MARK: - AppKit canvas

private struct EditorCanvasRepresentable: NSViewRepresentable {
    let model: ImageEditorModel

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = false

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip

        let document = EditorDocumentView(model: model)
        scrollView.documentView = document

        /// Whole canvas in view, never above actual size.
        let fit = { [weak scrollView, weak document] (animated: Bool) in
            guard let scrollView, let document else { return }
            // The scroll view's own size: the clip view's bounds shrink and
            // grow with the magnification.
            let available = scrollView.contentSize
            let content = document.frame.size
            guard available.width > 0, available.height > 0 else { return }
            let scale = max(min(available.width / max(content.width, 1), available.height / max(content.height, 1), 1) * 0.95, 0.1)
            if animated {
                scrollView.animator().magnification = scale
            } else {
                scrollView.magnification = scale
            }
        }

        model.zoomHandler = { [weak scrollView, weak model] command in
            guard let scrollView else { return }
            model?.fitsCanvas = command == .fit
            switch command {
            case .zoomIn: scrollView.animator().magnification = min(scrollView.magnification * 1.25, 8)
            case .zoomOut: scrollView.animator().magnification = max(scrollView.magnification / 1.25, 0.1)
            case .actualSize: scrollView.animator().magnification = 1
            case .fit: fit(true)
            }
        }
        model.canvasDidResize = { [weak model] in
            if model?.fitsCanvas == true { fit(false) }
        }

        // A pinch is a hand zoom; a window resize refits a fitted canvas.
        let center = NotificationCenter.default
        center.addObserver(context.coordinator, selector: #selector(Coordinator.willMagnify(_:)),
                           name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        center.addObserver(context.coordinator, selector: #selector(Coordinator.didResize(_:)),
                           name: NSView.frameDidChangeNotification, object: scrollView)
        scrollView.postsFrameChangedNotifications = true
        DispatchQueue.main.async { model.zoomHandler?(.fit) }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    /// Selector observers, removed by the system when this goes away.
    @MainActor final class Coordinator: NSObject {
        private weak var model: ImageEditorModel?

        init(model: ImageEditorModel) {
            self.model = model
        }

        @objc func willMagnify(_ notification: Notification) {
            model?.fitsCanvas = false
        }

        @objc func didResize(_ notification: Notification) {
            model?.canvasDidResize?()
        }
    }
}

/// Keeps the document centered when it's smaller than the viewport.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

/// The beautified canvas: background preview with the image area on top.
private final class EditorDocumentView: NSView {
    private let model: ImageEditorModel
    private let backgroundView = NSView()
    /// Casts the drop shadow; the image area itself is masked to its corners.
    private let shadowView = NSView()
    private let imageArea: EditorImageAreaView

    init(model: ImageEditorModel) {
        self.model = model
        imageArea = EditorImageAreaView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        backgroundView.wantsLayer = true
        shadowView.wantsLayer = true
        addSubview(backgroundView)
        addSubview(shadowView)
        addSubview(imageArea)
        model.layoutDidChange = { [weak self] in self?.relayout() }
        model.commitEditingHandler = { [weak self] in self?.imageArea.commitEditing() }
        relayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func relayout() {
        let (canvas, imageRect) = Beautifier.layout(imageSize: model.imageSize, options: model.beautify)
        let didResize = canvas != frame.size
        setFrameSize(canvas)
        defer { if didResize { model.canvasDidResize?() } }
        backgroundView.frame = bounds
        imageArea.frame = imageRect

        let options = model.beautify
        if options.isEnabled {
            // Background only (the image area draws the capture), rendered at screen scale.
            let scale = window?.backingScaleFactor ?? 2
            backgroundView.layer?.contents = Self.backgroundImage(size: canvas, options: options,
                                                                  picture: model.backgroundPicture(), scale: scale)
            imageArea.layer?.cornerRadius = min(options.cornerRadius, min(imageRect.width, imageRect.height) / 2)
            imageArea.layer?.cornerCurve = .continuous
            imageArea.layer?.masksToBounds = true
            setShadow(options.shadow ? imageRect : nil, radius: imageArea.layer?.cornerRadius ?? 0)
        } else {
            backgroundView.layer?.contents = nil
            imageArea.layer?.cornerRadius = 0
            setShadow(nil, radius: 0)
        }
    }

    /// Matches `Beautifier.render`'s shadow (offset 12 pt down, blur 40, 35% black).
    private func setShadow(_ rect: CGRect?, radius: CGFloat) {
        guard let layer = shadowView.layer else { return }
        guard let rect else {
            layer.shadowOpacity = 0
            return
        }
        shadowView.frame = rect
        layer.shadowPath = CGPath(roundedRect: shadowView.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 20
        // The document view is flipped; AppKit flips layer geometry to match.
        layer.shadowOffset = CGSize(width: 0, height: 12)
    }

    private static func backgroundImage(size: CGSize, options: BeautifyOptions, picture: CGImage?, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        // Top-left origin, point units, as `Beautifier.render` draws, so the
        // preview matches the export (gradient direction, picture upright).
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        if case .transparent = options.background {
            drawCheckerboard(size: size, in: context)
        } else {
            Beautifier.drawBackground(options.background, size: size, image: picture, in: context)
        }
        return context.makeImage()
    }

    private static func drawCheckerboard(size: CGSize, in context: CGContext) {
        context.setFillColor(CGColor(gray: 0.92, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 0.82, alpha: 1))
        let cell: CGFloat = 10
        for row in 0..<Int(size.height / cell) + 1 {
            for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
    }
}

/// The capture itself: image layer + annotation canvas + tool interaction.
/// Its own coordinates are image-local points, the annotation space.
private final class EditorImageAreaView: NSView {
    private let model: ImageEditorModel
    private let canvas: AnnotationCanvasView
    private lazy var interaction = AnnotationInteraction(state: model.editorState, host: self) { [weak self] in
        self?.canvas.needsDisplay = true
    }

    init(model: ImageEditorModel) {
        self.model = model
        canvas = AnnotationCanvasView(state: model.editorState, snapshotImage: model.image, scale: model.scale,
                                      displaySize: model.imageSize)
        super.init(frame: CGRect(origin: .zero, size: model.imageSize))
        wantsLayer = true
        layer?.contents = model.image
        layer?.contentsGravity = .resize
        addSubview(canvas)
        canvas.setSelection(CGRect(origin: .zero, size: model.imageSize))
        model.editorState.documentDidChange = { [weak self] in self?.canvas.needsDisplay = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        canvas.setSelection(CGRect(origin: .zero, size: model.imageSize))
    }

    func commitEditing() {
        interaction.commitText()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseMoved(with event: NSEvent) {
        interaction.cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if interaction.isEditingText {
            interaction.commitText()
            return
        }
        window?.makeFirstResponder(self)
        _ = interaction.mouseDown(at: point, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        interaction.mouseDragged(to: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseUp(with event: NSEvent) {
        interaction.mouseUp()
    }

    override func flagsChanged(with event: NSEvent) {
        if interaction.isActive { interaction.flagsChanged(event.modifierFlags) }
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_LeftArrow: if interaction.nudgeSelection(by: CGVector(dx: -step, dy: 0)) { return }
        case kVK_RightArrow: if interaction.nudgeSelection(by: CGVector(dx: step, dy: 0)) { return }
        case kVK_UpArrow: if interaction.nudgeSelection(by: CGVector(dx: 0, dy: -step)) { return }
        case kVK_DownArrow: if interaction.nudgeSelection(by: CGVector(dx: 0, dy: step)) { return }
        case kVK_Escape:
            model.editorState.selectedAnnotationID = nil
            canvas.needsDisplay = true
            return
        default:
            if interaction.handleKey(event) { return }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !interaction.isEditingText, event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": shift ? model.editorState.redo() : model.editorState.undo()
        case "c": model.perform?(.copy)
        case "s": model.perform?(shift ? .saveAs : .save)
        case "p": model.perform?(.print)
        case "=", "+": model.zoomHandler?(.zoomIn)
        case "-": model.zoomHandler?(.zoomOut)
        case "0": model.zoomHandler?(.actualSize)
        case "9": model.zoomHandler?(.fit)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
