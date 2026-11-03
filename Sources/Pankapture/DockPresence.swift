import AppKit
import SwiftUI

/// Menu-bar-only while idle (GL-1), but a regular app with a Dock icon while a
/// standard window (Settings, editors, history, welcome) is open, so those
/// windows come to the front, show in Cmd-Tab, and reopen from the Dock.
@MainActor
final class DockPresence {
    static let shared = DockPresence()

    private var observers: [NSObjectProtocol] = []
    /// Set by `activateForWindow()` until the promised window opens, the opener
    /// gives up, or `pendingWindowLimit` passes.
    private var pendingWindow: Task<Void, Never>?

    /// How long a promised window may take before the hold lapses, so a window
    /// that never comes can't leave the Dock icon up for good.
    static let pendingWindowLimit: Duration = .seconds(10)

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

    /// Shows the Dock icon and activates the app ahead of a standard window
    /// that's about to open, so it comes up in front of other apps. Call it in
    /// the click that asked for the window, before any async work: macOS can
    /// decline an activation requested after that click has been handled (ADR-21).
    ///
    /// The app stays regular until the window opens. Without that hold, the
    /// menu or thumbnail closing in the meantime triggers `update()`, which
    /// finds no window yet, drops back to accessory and hands the front to the
    /// previous app; the window then opens behind it.
    func activateForWindow() {
        pendingWindow?.cancel()
        pendingWindow = Task { [weak self] in
            try? await Task.sleep(for: Self.pendingWindowLimit)
            guard !Task.isCancelled else { return }
            self?.windowWillNotOpen()
        }
        setPolicy(.regular)
        NSApp.activate()
    }

    /// Ends the hold from `activateForWindow()` when the window won't open
    /// after all (e.g. the capture it was for is gone).
    func windowWillNotOpen() {
        pendingWindow?.cancel()
        pendingWindow = nil
        update()
    }

    func update() {
        if NSApp.windows.contains(where: Self.isStandardWindow) {
            // The promised window (or another) is up; the hold has done its job.
            pendingWindow?.cancel()
            pendingWindow = nil
            setPolicy(.regular)
        } else {
            setPolicy(pendingWindow == nil ? .accessory : .regular)
        }
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
@Observable
final class SettingsWindow {
    enum Tab: Hashable {
        case general, screenshots, recording, shortcuts, history, permissions, updates
    }

    static let shared = SettingsWindow()

    /// The selected tab; `show(tab:)` switches it.
    var tab: Tab = .general
    @ObservationIgnored private var openSettings: OpenSettingsAction?

    private init() {}

    static func register(_ action: OpenSettingsAction) {
        shared.openSettings = action
    }

    static func show(tab: Tab? = nil) {
        if let tab { shared.tab = tab }
        DockPresence.shared.activateForWindow()
        shared.openSettings?()
    }
}
