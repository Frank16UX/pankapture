import AppKit
import CoreGraphics

/// An on-screen window, as seen at capture time. Used for window snapping in
/// area mode (SC-4) and for window capture (SC-6).
public struct WindowInfo: Sendable, Equatable, Identifiable {
    public let id: CGWindowID
    /// Frame in global Quartz coordinates (points, top-left origin).
    public let frame: CGRect
    public let title: String
    public let ownerName: String
    public let ownerPID: pid_t
    public let layer: Int
}

public enum WindowList {
    /// On-screen windows, **front to back**, excluding `excludingPID` (our own
    /// app), invisible windows, and tiny ones (status items, cursors).
    /// Normal app windows are layer 0; pass `includeAllLayers` to also return
    /// menus, the Dock, and other system UI.
    public static func onScreenWindows(excludingPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                                       includeAllLayers: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        return list.compactMap { entry -> WindowInfo? in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != excludingPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  includeAllLayers || layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 40, frame.height >= 40
            else { return nil }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { return nil }
            return WindowInfo(
                id: id,
                frame: frame,
                title: entry[kCGWindowName as String] as? String ?? "",
                ownerName: entry[kCGWindowOwnerName as String] as? String ?? "",
                ownerPID: pid,
                layer: layer
            )
        }
    }
}
