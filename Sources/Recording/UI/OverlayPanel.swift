import AppKit
import SwiftUI

/// Borderless, non-activating floating panel shared by every recording
/// surface (HUD, countdown, overlays, pickers). It never steals focus from the
/// app being recorded, follows the user across Spaces and full-screen apps,
/// and is transparent unless its content draws something.
final class OverlayPanel: NSPanel {
    /// Whether the panel may become key (to receive Esc). Off for click-through overlays.
    var allowsKey = false

    init(contentRect: NSRect, level: NSWindow.Level, clickThrough: Bool) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = clickThrough
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// The window-server ID, as ScreenCaptureKit and `CGWindowList` know it.
    var windowID: CGWindowID { CGWindowID(windowNumber) }
}

extension NSWindow.Level {
    /// Above other apps' floating windows and menus' status level, for HUD and overlays.
    static let recordingOverlay = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// Above everything, for transient full-screen pickers.
    static let recordingPicker = NSWindow.Level.screenSaver
}

/// Hosting view that sizes to its SwiftUI content.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
