import AppCore
import AppKit
import Library
import QuickAccess
import SwiftUI

/// The menu shown from the menu bar icon.
struct MenuBarContent: View {
    @Environment(CaptureCoordinator.self) private var coordinator

    private let store = ShortcutStore()

    var body: some View {
        Section("Screenshot") {
            actionButton(.captureArea, symbol: "rectangle.dashed")
            actionButton(.capturePreviousArea, symbol: "rectangle.dashed.badge.record")
            actionButton(.captureWindow, symbol: "macwindow")
            actionButton(.captureFullscreen, symbol: "display")
            actionButton(.scrollingCapture, symbol: "arrow.up.and.down.text.horizontal")
            actionButton(.captureText, symbol: "text.viewfinder")
            Menu {
                ForEach([3, 5, 10], id: \.self) { seconds in
                    Button("Capture Area in \(seconds) Seconds") { coordinator.captureAreaAfterDelay(seconds) }
                }
            } label: {
                Label("Self-Timer", systemImage: "timer")
            }
        }

        Section("Recording") {
            if coordinator.recording.isRecording {
                let recorder = coordinator.recording.recorder
                Button("Stop Recording (\(recorder.formattedElapsed))", systemImage: "stop.circle") {
                    coordinator.recording.stop()
                }
                Button(recorder.state == .paused ? "Resume" : "Pause",
                       systemImage: recorder.state == .paused ? "play.circle" : "pause.circle") {
                    recorder.state == .paused ? recorder.resume() : recorder.pause()
                }
            } else {
                Button("Record Screen…", systemImage: "record.circle") {
                    coordinator.recording.showOptions()
                }
                .keyboardShortcut(store.combo(for: .recordScreen).flatMap(\.menuShortcut))
            }
        }

        Divider()

        actionButton(.openHistory, symbol: "clock.arrow.circlepath", enabled: coordinator.library != nil)
        if let library = coordinator.library, !library.recentCaptures.isEmpty {
            Menu {
                ForEach(library.recentCaptures) { recent in
                    Button {
                        coordinator.open(recent)
                    } label: {
                        Label(recent.title, systemImage: recent.kind == .screenshot ? "photo" : "film")
                    }
                    .disabled(recent.isUnavailable)
                }
            } label: {
                Label("Recent Captures", systemImage: "clock")
            }
        }

        if let url = coordinator.lastCaptureURL {
            Button("Show Last Capture in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        Menu {
            Button("Unlock Click-Through Pins") { PinController.shared.unlockAll() }
            Button("Close All Pins") { PinController.shared.closeAll() }
            Divider()
            Button("Dismiss Thumbnails") { QuickAccessController.shared.dismissAll() }
        } label: {
            Label("Floating Windows", systemImage: "pin")
        }

        Divider()

        Button("About Pankapture", systemImage: "info.circle") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(options: [
                .credits: NSAttributedString(
                    string: "Screenshots, annotation, and screen recording for macOS.\nEverything stays on your Mac.",
                    attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
                ),
            ])
        }

        Button("Settings…", systemImage: "gearshape") {
            SettingsWindow.show()
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
