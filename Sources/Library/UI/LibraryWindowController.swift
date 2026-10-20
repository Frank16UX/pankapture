import AppCore
import AppKit
import Quartz
import SwiftUI

/// Owns the Library window (HI-2): an `NSWindow` hosting SwiftUI, created on
/// first `show()` and reused afterwards. Its frame is remembered across launches.
///
/// The app wires two callbacks:
/// - `onReEditScreenshot`: open the annotation editor with the original image,
///   scale, and live annotations, then call `CaptureLibrary.updateAnnotations`.
/// - `onOpenRecording`: open a recording in the video editor.
@MainActor
public final class LibraryWindowController: NSWindowController, NSWindowDelegate {
    public let library: CaptureLibrary

    public var onReEditScreenshot: ((LibraryScreenshot) -> Void)? {
        didSet { model.onReEditScreenshot = onReEditScreenshot }
    }

    public var onOpenRecording: ((URL) -> Void)? {
        didSet { model.onOpenRecording = onOpenRecording }
    }

    /// Called with true when the window opens and false when it closes, e.g. to
    /// switch the app's activation policy so the window shows in ⌘-Tab.
    public var onVisibilityChange: ((Bool) -> Void)?

    private let model: LibraryBrowserModel
    private var quickLookURLs: [URL] = []

    private static let frameAutosaveName = "PankaptureLibraryWindow"

    public init(
        library: CaptureLibrary,
        onReEditScreenshot: ((LibraryScreenshot) -> Void)? = nil,
        onOpenRecording: ((URL) -> Void)? = nil
    ) {
        self.library = library
        self.model = LibraryBrowserModel(library: library)
        self.onReEditScreenshot = onReEditScreenshot
        self.onOpenRecording = onOpenRecording
        super.init(window: nil)
        model.onReEditScreenshot = onReEditScreenshot
        model.onOpenRecording = onOpenRecording
        model.onQuickLook = { [weak self] urls in self?.toggleQuickLook(urls) }
        model.onSelectionFilesChanged = { [weak self] urls in self?.selectionFilesChanged(urls) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows (creating if needed) and focuses the library window.
    public func show() {
        let window = window ?? makeWindow()
        let wasVisible = window.isVisible
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            onVisibilityChange?(true)
            Task { await library.refreshFileLinks() }
        }
    }

    /// Shows the window with one item selected (e.g. from the recent captures menu).
    public func show(selecting id: UUID) {
        model.filter = .all
        model.searchText = ""
        model.selection = [id]
        show()
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: LibraryView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "Library"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window
        model.window = window
        return window
    }

    public func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        onVisibilityChange?(false)
    }

    // MARK: Quick Look

    private func toggleQuickLook(_ urls: [URL]) {
        quickLookURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    private func selectionFilesChanged(_ urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
              !urls.isEmpty, urls != quickLookURLs
        else { return }
        quickLookURLs = urls
        panel.reloadData()
    }

    // Quick Look's responder-chain hooks and data source aren't concurrency-annotated,
    // but the panel only ever calls them on the main thread.

    override public nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override public nonisolated func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    override public nonisolated func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }
}

extension LibraryWindowController: @preconcurrency QLPreviewPanelDataSource {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURLs.count
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURLs.indices.contains(index) ? quickLookURLs[index] as NSURL : nil
    }
}
