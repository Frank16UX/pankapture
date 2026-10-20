import AppKit
import CoreGraphics

/// Live display/window lookups (impure counterparts of `RecordingGeometry`).
@MainActor
enum ScreenGeometry {
    /// Height of the primary display (menu bar display; AppKit origin).
    static var primaryDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// The screen under the mouse pointer.
    static var screenUnderMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// The screen showing most of a Quartz-global rect.
    static func screen(containingQuartzRect rect: CGRect) -> NSScreen? {
        let appKitRect = RecordingGeometry.appKitRect(fromQuartz: rect, primaryDisplayHeight: primaryDisplayHeight)
        return NSScreen.screens.max { a, b in
            area(a.frame.intersection(appKitRect)) < area(b.frame.intersection(appKitRect))
        } ?? NSScreen.main
    }

    /// Current bounds of a window in Quartz global points.
    nonisolated static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    /// The Quartz-global frame a recording shows right now, used to normalize clicks.
    static func capturedFrame(for source: RecordingConfiguration.Source, sourceRect: CGRect?) -> CGRect? {
        switch source {
        case .display(let id):
            return CGDisplayBounds(id)
        case .area(let id, let rect):
            return RecordingGeometry.quartzRect(fromDisplayLocal: sourceRect ?? rect, displayBounds: CGDisplayBounds(id))
        case .window(let id):
            return windowBounds(id)
        }
    }

    /// AppKit-global frame of a display-local area, for placing indicator windows.
    static func appKitRect(forArea rect: CGRect, on displayID: CGDirectDisplayID) -> CGRect {
        let quartz = RecordingGeometry.quartzRect(fromDisplayLocal: rect, displayBounds: CGDisplayBounds(displayID))
        return RecordingGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: primaryDisplayHeight)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}

extension NSScreen {
    /// The Quartz display ID backing this screen.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
