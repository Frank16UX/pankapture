import Annotation
import AppCore
import AppKit
import Capture
import os

/// The finished capture handed to the app for output.
public struct CaptureResult: @unchecked Sendable {
    // @unchecked: immutable value wrapping CGImages (thread-safe, immutable CF types).

    /// Flattened image (annotations burned in), in pixels.
    public let image: CGImage
    /// The same region without annotations (for re-editing from history).
    public let original: CGImage
    /// Annotations in capture-local points (origin = top-left of `original`).
    public let annotations: AnnotationDocument
    /// Pixels per point.
    public let scale: CGFloat
    public let displayID: CGDirectDisplayID
    /// Selection in display-local points.
    public let rect: CGRect
    /// Selection in AppKit global coordinates (for pinning in place).
    public let screenRect: CGRect
}

/// An area chosen in `.pick` mode (recording, OCR, scrolling capture).
public struct PickedArea: Sendable {
    public let snapshot: DisplaySnapshot
    /// Display-local points, top-left origin.
    public let rect: CGRect

    public var displayID: CGDirectDisplayID { snapshot.displayID }
    /// The frozen pixels of the picked area.
    public var image: CGImage? { snapshot.crop(toLocalRect: rect) }
    /// The area in global Quartz coordinates.
    public var globalRect: CGRect { rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY) }
}

public enum OutputAction: Sendable, Equatable {
    case copy, save, saveAs, print, pin, done, shared, openEditor
}

public enum OverlayOutcome: Sendable {
    /// Closed without output. Carries the selection if there was one, so the
    /// app can keep it in history (OUT-8).
    case cancelled(CaptureResult?)
    case output(OutputAction, CaptureResult)
    case picked(PickedArea)
    case pickedWindow(WindowInfo)
}

/// Presents the frozen-frame selection overlay on every display and turns the
/// user's selection (and annotations) into a result (ARCHITECTURE §4.1).
@MainActor
public final class OverlayController: NSObject {
    /// Above the menu bar and Dock; below pop-up menus (so the share menu and
    /// tooltips still appear on top).
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private let state = EditorState()
    private let mode: OverlayMode
    private var completion: ((OverlayOutcome) -> Void)?
    private weak var activeView: OverlayView?
    private var previousApp: NSRunningApplication?
    private var sharingResult: CaptureResult?

    /// The currently presented overlay, if any (only one at a time).
    public private(set) static var current: OverlayController?

    private init(mode: OverlayMode) {
        self.mode = mode
        super.init()
    }

    /// Shows the overlay. `completion` is called exactly once.
    /// - Parameters:
    ///   - preselect: an initial selection (display + display-local rect), e.g. "previous area".
    @discardableResult
    public static func present(
        snapshots: [DisplaySnapshot],
        windows: [WindowInfo] = [],
        mode: OverlayMode = .annotate,
        preselect: (displayID: CGDirectDisplayID, rect: CGRect)? = nil,
        completion: @escaping (OverlayOutcome) -> Void
    ) -> OverlayController? {
        guard current == nil else { return nil }
        let controller = OverlayController(mode: mode)
        controller.completion = completion
        current = controller
        controller.show(snapshots: snapshots, windows: windows, preselect: preselect)
        return controller
    }

    private func show(snapshots: [DisplaySnapshot], windows: [WindowInfo], preselect: (displayID: CGDirectDisplayID, rect: CGRect)?) {
        state.documentDidChange = { [weak self] in self?.activeView?.documentChanged() }
        state.perform = { [weak self] command in
            guard let self, let view = self.activeView else { return }
            self.perform(command, from: view)
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }

        for snapshot in snapshots {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == snapshot.displayID }) else { continue }
            let panel = OverlayPanel(screen: screen)
            let view = OverlayView(snapshot: snapshot, windows: windows, state: state, mode: mode, controller: self)
            panel.contentView = view
            panels.append(panel)
            views.append(view)
        }

        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let keyIndex = panels.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        for (index, panel) in panels.enumerated() where index != keyIndex {
            panel.orderFrontRegardless()
        }
        if panels.indices.contains(keyIndex) {
            panels[keyIndex].makeKeyAndOrderFront(nil)
            panels[keyIndex].makeFirstResponder(views[keyIndex])
            activeView = views[keyIndex]
        }
        NSCursor.crosshair.set()

        // Displays changed between the snapshot and now: nothing to show.
        guard !panels.isEmpty else {
            Log.overlay.error("No screen matches the captured displays")
            finish(.cancelled(nil), reactivatePrevious: false)
            return
        }

        if let preselect, let view = views.first(where: { $0.snapshot.displayID == preselect.displayID }) {
            activate(view)
            view.select(preselect.rect)
        }
        Log.overlay.debug("Overlay presented on \(self.panels.count) display(s)")
    }

    public func cancel() {
        let discarded = mode == .annotate ? activeView.flatMap(render) : nil
        finish(.cancelled(discarded), reactivatePrevious: true)
    }

    // MARK: Called by OverlayView

    func mouseEntered(_ view: OverlayView) {
        guard let panel = view.window, !panel.isKeyWindow, activeView?.selection == nil else { return }
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    func activate(_ view: OverlayView) {
        guard activeView !== view else { return }
        activeView?.resetSelection()
        activeView = view
        state.resetDocument()
        view.window?.makeKey()
        view.window?.makeFirstResponder(view)
    }

    func pickWindow(_ window: WindowInfo) {
        finish(.pickedWindow(window), reactivatePrevious: true)
    }

    func selectionDidChange(_ view: OverlayView, rect: CGRect) {
        if mode == .annotate {
            UserDefaults.standard.set(
                try? JSONEncoder().encode(LastSelection(displayID: view.snapshot.displayID, rect: rect)),
                forKey: PreferenceKey.lastSelection
            )
        }
    }

    func perform(_ command: EditorCommand, from view: OverlayView) {
        switch command {
        case .undo: state.undo()
        case .redo: state.redo()
        case .close: cancel()
        case .confirmPick:
            guard let rect = view.selection else { return }
            finish(.picked(PickedArea(snapshot: view.snapshot, rect: rect)), reactivatePrevious: false)
        case .share:
            guard let result = render(view) else { return }
            share(result, from: view)
        case .copy: output(.copy, view)
        case .save: output(.save, view)
        case .saveAs: output(.saveAs, view)
        case .print: output(.print, view)
        case .pin: output(.pin, view)
        case .done: output(.done, view)
        case .openEditor: output(.openEditor, view)
        }
    }

    private func output(_ action: OutputAction, _ view: OverlayView) {
        guard let result = render(view) else { return }
        let keepsFocus = action == .saveAs || action == .print || action == .openEditor
        finish(.output(action, result), reactivatePrevious: !keepsFocus)
    }

    private func render(_ view: OverlayView) -> CaptureResult? {
        view.endEditing()
        guard let rect = view.selection, rect.width >= 1, rect.height >= 1 else { return nil }
        let signpost = Log.signposter.beginInterval("render capture")
        defer { Log.signposter.endInterval("render capture", signpost) }

        let snapshot = view.snapshot
        let document = state.document
        guard let original = snapshot.crop(toLocalRect: rect),
              let image = document.isEmpty
                ? original
                : AnnotationRenderer.render(document, source: snapshot.image, scale: snapshot.scale, crop: rect)
        else { return nil }

        return CaptureResult(
            image: image,
            original: original,
            annotations: document.translated(by: CGVector(dx: -rect.minX, dy: -rect.minY)),
            scale: snapshot.scale,
            displayID: snapshot.displayID,
            rect: rect,
            screenRect: Self.appKitRect(forLocal: rect, on: snapshot)
        )
    }

    /// Display-local (top-left) → AppKit global (bottom-left of the primary display).
    static func appKitRect(forLocal rect: CGRect, on snapshot: DisplaySnapshot) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? snapshot.frame.height
        let quartz = rect.offsetBy(dx: snapshot.frame.minX, dy: snapshot.frame.minY)
        return CGRect(x: quartz.minX, y: primaryHeight - quartz.maxY, width: quartz.width, height: quartz.height)
    }

    // MARK: Share (OUT-4)

    private func share(_ result: CaptureResult, from view: OverlayView) {
        do {
            let url = try ImageOutput.writeTemporary(result.image, scale: result.scale)
            sharingResult = result
            let picker = NSSharingServicePicker(items: [url])
            picker.delegate = self
            let anchor = view.actionsBarView ?? view
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            Log.output.error("Share failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Teardown

    private func finish(_ outcome: OverlayOutcome, reactivatePrevious: Bool) {
        guard let completion else { return }
        self.completion = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        if NSColorPanel.sharedColorPanelExists, NSColorPanel.shared.level.rawValue > Self.windowLevel.rawValue {
            NSColorPanel.shared.orderOut(nil)
            NSColorPanel.shared.level = .floating
        }
        if reactivatePrevious, let previousApp {
            previousApp.activate(from: .current, options: [])
        }
        Self.current = nil
        // Let the event or button action that triggered this unwind first: the
        // completion may run modal UI (Save As, Print) after the panels are gone.
        DispatchQueue.main.async { completion(outcome) }
    }
}

extension OverlayController: NSSharingServicePickerDelegate {
    public nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        let didChoose = service != nil
        MainActor.assumeIsolated {
            guard didChoose, let result = sharingResult else { return }
            sharingResult = nil
            finish(.output(.shared, result), reactivatePrevious: false)
        }
    }
}

/// Persisted "previous area" (SC-8).
public struct LastSelection: Codable, Sendable {
    public let displayID: CGDirectDisplayID
    public let rect: CGRect

    public static func load(from defaults: UserDefaults = .standard) -> LastSelection? {
        defaults.data(forKey: PreferenceKey.lastSelection).flatMap { try? JSONDecoder().decode(LastSelection.self, from: $0) }
    }
}

/// Borderless, full-display panel that can become key (for keyboard input)
/// and floats above everything, on every Space, including full-screen apps.
final class OverlayPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = OverlayController.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

public extension NSScreen {
    /// The Core Graphics display ID for this screen.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
