import AppKit
import SwiftUI

/// Menu-bar-only while idle (GL-1), but a regular app with a Dock icon while a
/// standard window (Settings, editors, history, welcome) is open, so those
/// windows come to the front, show in Cmd-Tab, and reopen from the Dock.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // Deferred: during willClose the window is still visible.
                Task { @MainActor in DockPresence.shared.update() }
            }
        }
        update()
    }

    /// Shows the Dock icon ahead of a window that's about to open, so
    /// activation brings that window in front of other apps.
    func becomeRegular() {
        setPolicy(.regular)
    }

    func update() {
        setPolicy(NSApp.windows.contains(where: Self.isStandardWindow) ? .regular : .accessory)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// Titled, non-panel windows. Overlays, HUDs, thumbnails, pins, and the
    /// recording options are panels or borderless and keep the app menu-bar-only.
    private static func isStandardWindow(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && (window.isVisible || window.isMiniaturized)
    }
}

/// Opens the SwiftUI Settings scene from anywhere, including AppKit code.
/// The action is captured from the always-present menu bar label.
@MainActor
enum SettingsWindow {
    private static var openSettings: OpenSettingsAction?

    static func register(_ action: OpenSettingsAction) {
        openSettings = action
    }

    static func show() {
        DockPresence.shared.becomeRegular()
        NSApp.activate()
        openSettings?()
    }
}
