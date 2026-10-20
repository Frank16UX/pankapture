import AppCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Opens and manages video editor windows (one per file). Keep one instance
/// in the app (e.g. on the app delegate) and call `open(url:)`.
///
/// ```swift
/// let editor = VideoEditorWindowController()
/// editor.onExportFinished = { result in library.record(result) }
/// editor.open(url: recordingURL)
/// ```
@MainActor
public final class VideoEditorWindowController: NSObject, NSWindowDelegate {
    /// Called on the main actor whenever an export from any editor window
    /// completes (e.g. to record it in the capture history).
    public var onExportFinished: ((VideoExportResult) -> Void)?

    private struct Entry {
        let window: NSWindow
        let model: VideoEditorModel
        let keyMonitor: Any?
    }

    private var entries: [URL: Entry] = [:]

    override public init() {
        super.init()
    }

    /// URLs of the files currently open in an editor.
    public var openURLs: [URL] { Array(entries.keys) }

    /// Opens `url` in an editor window, or brings its existing window forward.
    /// Activates the app, since Pankapture is normally an accessory (menu bar) app.
    public func open(url: URL) {
        let key = url.standardizedFileURL
        if let entry = entries[key] {
            show(entry.window)
            return
        }

        let model = VideoEditorModel(url: key)
        model.onExportFinished = { [weak self] result in self?.onExportFinished?(result) }

        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.title = key.deletingPathExtension().lastPathComponent
        window.representedURL = key
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 900, height: 600)
        window.setContentSize(NSSize(width: 1200, height: 780))
        // The autosave name can be used by one window at a time; extra editor
        // windows cascade from the first instead.
        if entries.isEmpty, window.setFrameAutosaveName(PreferenceKey.videoEditorWindowFrame) {
            if !window.setFrameUsingName(PreferenceKey.videoEditorWindowFrame) { window.center() }
        } else if let last = entries.values.first?.window {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }

        entries[key] = Entry(window: window, model: model, keyMonitor: installKeyMonitor(window: window, model: model))
        show(window)
        Log.editor.info("Editor opened for \(key.lastPathComponent, privacy: .public)")
    }

    /// The window and model editing `url` (internal: tests and diagnostics).
    func editor(for url: URL) -> (window: NSWindow, model: VideoEditorModel)? {
        entries[url.standardizedFileURL].map { ($0.window, $0.model) }
    }

    /// Closes every editor window (saving edits).
    public func closeAll() {
        for entry in entries.values { entry.window.close() }
    }

    private func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (key, entry) = entries.first(where: { $0.value.window === window }) else { return }
        entry.model.close()
        if let monitor = entry.keyMonitor { NSEvent.removeMonitor(monitor) }
        entries.removeValue(forKey: key)
    }

    // MARK: Keyboard

    /// Editor shortcuts, active only while this editor window is key and no
    /// text field is being edited. A local monitor (rather than menu items)
    /// works even though the accessory app has no main menu.
    private func installKeyMonitor(window: NSWindow, model: VideoEditorModel) -> Any? {
        // Local monitors run on the main thread, inside the app's event loop.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak model] event in
            guard let window, let model, event.window === window, window.attachedSheet == nil,
                  !(window.firstResponder is NSText) else { return event }
            return Self.handle(event, model: model, window: window) ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, model: VideoEditorModel, window: NSWindow) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Keys never arrive mid-drag in practice; a "drag" still open here
        // lost its end event, so close it before editing.
        if NSEvent.pressedMouseButtons == 0 { model.cancelContinuousEdit() }

        if flags == .command {
            switch key {
            case "z": model.undo()
            case "x": model.cutSelection()
            case "e": if model.media != nil { model.isShowingExportSheet = true }
            case "w": window.performClose(nil)
            default: return false
            }
            return true
        }
        if flags == [.command, .shift], key == "z" {
            model.redo()
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }

        switch Int(event.keyCode) {
        case kVK_Space: model.togglePlayback()
        case kVK_LeftArrow: flags.contains(.shift) ? model.jump(by: -1) : model.stepFrames(-1)
        case kVK_RightArrow: flags.contains(.shift) ? model.jump(by: 1) : model.stepFrames(1)
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelected()
        case kVK_Escape: model.clearSelection()
        default:
            switch key {
            case "i": model.setTrimInAtPlayhead()
            case "o": model.setTrimOutAtPlayhead()
            case "j": model.pause(); model.jump(by: -2)
            case "k": model.pause()
            case "l": model.playFaster()
            case "z": model.addZoomAtPlayhead()
            default: return false
            }
        }
        return true
    }
}
