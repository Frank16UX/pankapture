import AppCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A window offered in the Window source list.
public struct RecordableWindow: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let appName: String
    public let title: String
}

enum RecordableWindows {
    /// Titled, normal-level windows of other apps, sorted by app then title.
    /// Includes windows in other Spaces or behind a full-screen app, which
    /// click-to-pick can't reach; ScreenCaptureKit records them by ID.
    @MainActor
    static func list() async -> [RecordableWindow] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
            return []
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownWindows = OwnWindows.capturableIDs() // the editors can be recorded too
        return content.windows.compactMap { window -> RecordableWindow? in
            guard window.windowLayer == 0,
                  let app = window.owningApplication, app.processID != ownPID || ownWindows.contains(window.windowID),
                  let title = window.title, !title.isEmpty,
                  window.frame.width >= 100, window.frame.height >= 100 else { return nil }
            return RecordableWindow(id: window.windowID, appName: app.applicationName, title: title)
        }
        .sorted { ($0.appName.localizedLowercase, $0.title.localizedLowercase) < ($1.appName.localizedLowercase, $1.title.localizedLowercase) }
    }
}
