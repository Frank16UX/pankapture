import Annotation
import AppCore
import AppKit
import Capture
import Carbon.HIToolbox
import DesignSystem
import Observation
import SwiftUI

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

    private let model: ImageEditorModel
    private let onOutput: (EditorOutputAction, EditedImage) -> Void
    private var sharePicker: NSSharingServicePicker?
    private var sharingResult: EditedImage?

    /// Opens a new editor window.
    /// - Parameter annotations: in image-local points (top-left of `image`).
    public static func open(
        image: CGImage,
        scale: CGFloat,
        annotations: AnnotationDocument = AnnotationDocument(),
        beautify: BeautifyOptions? = nil,
        onOutput: @escaping (EditorOutputAction, EditedImage) -> Void
    ) {
        let controller = ImageEditorWindowController(
            model: ImageEditorModel(image: image, scale: scale, annotations: annotations, beautify: beautify),
            onOutput: onOutput
        )
        open.append(controller)
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate()
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(model: ImageEditorModel, onOutput: @escaping (EditorOutputAction, EditedImage) -> Void) {
        self.model = model
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

    @ObservationIgnored var perform: ((EditorOutputAction) -> Void)?
    @ObservationIgnored var layoutDidChange: (() -> Void)?
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
              let final = Beautifier.render(annotated, scale: scale, options: beautify) else { return nil }
        return EditedImage(image: final, original: image, annotations: document, beautify: beautify, scale: scale)
    }
}

// MARK: - SwiftUI shell

private struct ImageEditorRoot: View {
    @Bindable var model: ImageEditorModel
    @State private var showsInspector = true

    var body: some View {
        HStack(spacing: 0) {
            ToolsBar(state: model.editorState)
                .padding(PK.Spacing.m)
                .frame(maxHeight: .infinity, alignment: .top)

            EditorCanvasRepresentable(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background.secondary)
        }
        .inspector(isPresented: $showsInspector) {
            BeautifyInspector(options: $model.beautify)
                .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
        }
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
                Button { showsInspector.toggle() } label: { Label("Background", systemImage: "sidebar.trailing") }
                    .help("Show or hide background options")
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

private struct BeautifyInspector: View {
    @Binding var options: BeautifyOptions

    var body: some View {
        Form {
            Section {
                Toggle("Background", isOn: $options.isEnabled)
            } footer: {
                Text("Places the capture on a padded background with rounded corners and a shadow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Fill") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: PK.Spacing.s), count: 4), spacing: PK.Spacing.s) {
                    ForEach(BeautifyOptions.GradientPreset.allCases) { preset in
                        let (start, end) = preset.colors
                        Button {
                            options.background = .gradient(preset)
                            options.isEnabled = true
                        } label: {
                            RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                                .fill(LinearGradient(colors: [Color(cgColor: start.cgColor), Color(cgColor: end.cgColor)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 32)
                                .overlay(
                                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: options.background == .gradient(preset) ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(preset.title) gradient")
                    }
                    Button {
                        options.background = .transparent
                        options.isEnabled = true
                    } label: {
                        RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                            .fill(.quaternary)
                            .overlay(Image(systemName: "square.dashed").foregroundStyle(.secondary))
                            .frame(height: 32)
                            .overlay(
                                RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: options.background == .transparent ? 2 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Transparent")
                }
                ColorPicker("Solid color", selection: solidColor, supportsOpacity: false)
            }
            .disabled(!options.isEnabled)

            Section("Layout") {
                LabeledContent("Padding") {
                    Slider(value: $options.padding, in: 0...240, step: 4)
                }
                LabeledContent("Corners") {
                    Slider(value: $options.cornerRadius, in: 0...48, step: 1)
                }
                Toggle("Shadow", isOn: $options.shadow)
                Picker("Aspect", selection: $options.aspect) {
                    ForEach(BeautifyOptions.Aspect.allCases) { Text($0.title).tag($0) }
                }
            }
            .disabled(!options.isEnabled)
        }
        .formStyle(.grouped)
    }

    private var solidColor: Binding<Color> {
        Binding(
            get: {
                if case let .solid(color) = options.background { return Color(cgColor: color.cgColor) }
                return .white
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                options.background = .solid(RGBAColor(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent))
                options.isEnabled = true
            }
        )
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
        model.zoomHandler = { [weak scrollView] command in
            guard let scrollView else { return }
            switch command {
            case .zoomIn: scrollView.animator().magnification = min(scrollView.magnification * 1.25, 8)
            case .zoomOut: scrollView.animator().magnification = max(scrollView.magnification / 1.25, 0.1)
            case .actualSize: scrollView.animator().magnification = 1
            case .fit:
                let available = scrollView.contentView.bounds.size
                let content = document.frame.size
                let scale = min(available.width / max(content.width, 1), available.height / max(content.height, 1), 1) * 0.95
                scrollView.animator().magnification = max(scale, 0.1)
            }
        }
        DispatchQueue.main.async { model.zoomHandler?(.fit) }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
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
        setFrameSize(canvas)
        backgroundView.frame = bounds
        imageArea.frame = imageRect

        let options = model.beautify
        if options.isEnabled {
            // Background only (the image area draws the capture), rendered at screen scale.
            let scale = window?.backingScaleFactor ?? 2
            backgroundView.layer?.contents = Self.backgroundImage(size: canvas, options: options, scale: scale)
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

    private static func backgroundImage(size: CGSize, options: BeautifyOptions, scale: CGFloat) -> CGImage? {
        guard size.width > 0, size.height > 0,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        if case .transparent = options.background {
            drawCheckerboard(size: size, in: context)
        } else {
            Beautifier.drawBackground(options.background, size: size, in: context)
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
