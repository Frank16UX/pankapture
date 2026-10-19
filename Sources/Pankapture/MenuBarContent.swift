import AppCore
import AppKit
import SwiftUI

/// The menu shown from the menu bar icon.
struct MenuBarContent: View {
    @Environment(CaptureCoordinator.self) private var coordinator

    private let store = ShortcutStore()

    var body: some View {
        Section("Screenshot") {
            actionButton(.captureArea, symbol: "rectangle.dashed")
            actionButton(.captureWindow, symbol: "macwindow", enabled: false)
            actionButton(.captureFullscreen, symbol: "display")
            actionButton(.scrollingCapture, symbol: "arrow.up.and.down.text.horizontal", enabled: false)
            actionButton(.captureText, symbol: "text.viewfinder", enabled: false)
        }

        Section("Recording") {
            actionButton(.recordScreen, symbol: "record.circle", enabled: false)
        }

        Divider()

        actionButton(.openHistory, symbol: "clock.arrow.circlepath", enabled: false)

        if let url = coordinator.lastCaptureURL {
            Button("Show Last Capture in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")

        Button("Quit Pankapture", systemImage: "power") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func actionButton(_ action: ShortcutAction, symbol: String, enabled: Bool = true) -> some View {
        Button(action.title, systemImage: symbol) {
            coordinator.perform(action)
        }
        .disabled(!enabled)
        .keyboardShortcut(store.combo(for: action).flatMap(\.menuShortcut))
    }
}

private extension KeyCombo {
    /// Mirrors the global shortcut in the menu so it's discoverable.
    /// Only letter/digit keys map cleanly to SwiftUI key equivalents.
    var menuShortcut: KeyboardShortcut? {
        let name = displayString.dropFirst(modifiers.symbols.count)
        guard name.count == 1, let character = name.lowercased().first else { return nil }
        var swiftUIModifiers: EventModifiers = []
        if modifiers.contains(.command) { swiftUIModifiers.insert(.command) }
        if modifiers.contains(.shift) { swiftUIModifiers.insert(.shift) }
        if modifiers.contains(.option) { swiftUIModifiers.insert(.option) }
        if modifiers.contains(.control) { swiftUIModifiers.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: swiftUIModifiers)
    }
}
