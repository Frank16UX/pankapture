import AppKit

/// Pankapture's own windows that belong in screenshots and recordings.
///
/// Captures exclude the app so its capture UI (overlay, HUD, thumbnails,
/// pins, options panel: all panels) never leaks in. Standard titled windows
/// (the image and video editors, history, Settings, the welcome window) are
/// app content the user may want to show, so they're excepted.
@MainActor
public enum OwnWindows {
    /// Window numbers (= `CGWindowID`) of the visible standard windows.
    public static func capturableIDs() -> Set<CGWindowID> {
        Set(NSApp.windows.compactMap { window -> CGWindowID? in
            guard window.isVisible, !(window is NSPanel), window.styleMask.contains(.titled),
                  window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
    }
}
