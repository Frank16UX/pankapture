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
    /// An editor was built in this launch (or `warmUp()` ran), so building
    /// another is quick and the window can skip the skeleton.
    private static var isEditorWarm = false

    override public init() {
        super.init()
    }

    /// URLs of the files currently open in an editor.
    public var openURLs: [URL] { Array(entries.keys) }

    /// Opens `url` in an editor window, or brings its existing window forward.
    /// Activates the app, since Pankapture is normally an accessory (menu bar) app.
    public func open(url: URL) {
        // A recording with a webcam track is edited from its layered
        // original; the save folder has the composited copy (ADR-25).
        let key = AppPaths.editableRecording(for: url).standardizedFileURL
        if let entry = entries[key] {
            show(entry.window)
            return
        }
        let signpost = Log.signposter.beginInterval("openVideoEditor")
        defer { Log.signposter.endInterval("openVideoEditor", signpost) }

        let model = VideoEditorModel(url: key)
        model.onExportFinished = { [weak self] result in self?.onExportFinished?(result) }
        model.isEditorMounted = Self.isEditorWarm

        let hosting = NSHostingController(rootView: EditorWindowContent(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        // A toolbar from the start, so the title bar doesn't grow when the
        // editor's own toolbar arrives after the skeleton.
        if window.toolbar == nil { window.toolbar = NSToolbar(identifier: "videoEditor.placeholder") }
        window.title = key.deletingPathExtension().lastPathComponent
        window.representedURL = key
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 1000, height: 600)
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

        model.onUnsavedChangesChanged = { [weak window] edited in window?.isDocumentEdited = edited }
        entries[key] = Entry(window: window, model: model, keyMonitor: installKeyMonitor(window: window, model: model))
        show(window)
        if !model.isEditorMounted { mountEditor(model) }
        Log.editor.info("Editor opened for \(key.lastPathComponent, privacy: .public)")
    }

    /// Builds the editor once its skeleton is on screen (VE-18).
    private func mountEditor(_ model: VideoEditorModel) {
        Task { @MainActor in
            // A couple of frames for the window to draw the skeleton: building
            // the first editor of a launch holds the main thread for a moment.
            try? await Task.sleep(for: .milliseconds(50))
            model.isEditorMounted = true
            Self.isEditorWarm = true
        }
    }

    /// Builds an editor off screen, once, so the first one the user opens
    /// comes up at once. The first editor of a launch loads frameworks and
    /// sets up every view type for the first time, which takes a second or
    /// two; later ones take about a tenth of a second (ADR-42). Call it while
    /// the app is idle: it holds the main thread for that second or two.
    public func warmUp() {
        guard !Self.isEditorWarm, entries.isEmpty else { return }
        let signpost = Log.signposter.beginInterval("warmUpVideoEditor")
        defer { Log.signposter.endInterval("warmUpVideoEditor", signpost) }
        let start = ContinuousClock.now

        // Never loaded: it only lends the views something to show.
        let model = VideoEditorModel(url: URL(fileURLWithPath: "/dev/null"))
        model.isEditorMounted = true
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1200, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        window.close()
        model.close()
        Self.isEditorWarm = true
        let elapsed = ContinuousClock.now - start
        Log.editor.info("Video editor warmed up in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
    }

    /// The window and model editing `url` (internal: tests and diagnostics).
    func editor(for url: URL) -> (window: NSWindow, model: VideoEditorModel)? {
        entries[AppPaths.editableRecording(for: url).standardizedFileURL].map { ($0.window, $0.model) }
    }

    /// Closes every editor window. Unsaved edits stay in their drafts; call
    /// `reviewUnsavedChanges()` first to ask about them.
    public func closeAll() {
        for entry in entries.values { entry.window.close() }
    }

    /// Asks about each editor with unsaved edits (Save / Don't Save / Cancel),
    /// e.g. before quitting. Returns `false` if the user cancelled.
    public func reviewUnsavedChanges() -> Bool {
        for entry in entries.values where entry.model.hasUnsavedChanges {
            show(entry.window)
            switch Self.unsavedChangesAlert(for: entry.model).runModal() {
            case .alertFirstButtonReturn:
                guard entry.model.save() else { return false }
            case .alertSecondButtonReturn:
                entry.model.discardChanges()
            default:
                return false
            }
        }
        return true
    }

    private static func unsavedChangesAlert(for model: VideoEditorModel) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Save your edits to “\(model.sourceURL.deletingPathExtension().lastPathComponent)”?"
        alert.informativeText = "Saved edits come back the next time you open this recording. If you don't save, they're lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        return alert
    }

    private func show(_ window: NSWindow) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate

    /// Closing with unsaved edits asks first (VE-12).
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = entries.values.first(where: { $0.window === sender }),
              entry.model.hasUnsavedChanges else { return true }
        let model = entry.model
        Self.unsavedChangesAlert(for: model).beginSheetModal(for: sender) { response in
            switch response {
            case .alertFirstButtonReturn:
                if model.save() { sender.close() }
            case .alertSecondButtonReturn:
                model.discardChanges()
                sender.close()
            default:
                break
            }
        }
        return false
    }

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
            // Text being edited keeps its keys; the read-only transcript doesn't.
            let isEditingText = (window?.firstResponder as? NSTextView)?.isEditable ?? (window?.firstResponder is NSText)
            guard let window, let model, event.window === window, window.attachedSheet == nil,
                  !isEditingText else { return event }
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
            case "=", "+": model.zoomTimeline(by: 1.5)
            case "-": model.zoomTimeline(by: 1 / 1.5)
            case "0": model.fitTimeline()
            case "1", "2", "3", "4", "5", "6", "7", "8", "9": model.showInspectorSection(number: Int(key) ?? 0)
            case "z": model.undo()
            case "s": model.save()
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
        // ⌘+ arrives with Shift on most layouts.
        if flags == [.command, .shift], key == "+" || key == "=" {
            model.zoomTimeline(by: 1.5)
            return true
        }
        guard flags.subtracting(.shift).isEmpty else { return false }

        switch Int(event.keyCode) {
        case kVK_Space: model.togglePlayback()
        case kVK_LeftArrow: flags.contains(.shift) ? model.jump(by: -1) : model.stepFrames(-1)
        case kVK_RightArrow: flags.contains(.shift) ? model.jump(by: 1) : model.stepFrames(1)
        case kVK_Delete, kVK_ForwardDelete: model.deleteSelected()
        case kVK_Escape: model.clearSelection()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard model.inspectorSection == .transcript, let words = model.transcriptSelection, !flags.contains(.shift) else { return false }
            model.beginCorrecting(words)
        default:
            switch key {
            case "i": model.setTrimInAtPlayhead()
            case "o": model.setTrimOutAtPlayhead()
            case "j": model.pause(); model.jump(by: -2)
            case "k": model.pause()
            case "l": model.playFaster()
            case "z": model.addZoomAtPlayhead()
            case "s": model.splitAtPlayhead()
            case "[": model.setSelectedEdgeToPlayhead(start: true)
            case "]": model.setSelectedEdgeToPlayhead(start: false)
            default: return false
            }
        }
        return true
    }
}
