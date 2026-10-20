import AppCore
import AppKit
import Carbon.HIToolbox
import DesignSystem
import SwiftUI

/// Shortcut recorder (GL-3): assign, clear, reset, with conflict warnings.
struct ShortcutsSettingsView: View {
    @Environment(CaptureCoordinator.self) private var coordinator
    @State private var combos: [ShortcutAction: KeyCombo] = [:]
    @State private var recording: ShortcutAction?

    private let store = ShortcutStore()

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: PK.Spacing.s) {
                            if let warning = warning(for: action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help(warning)
                                    .accessibilityLabel(warning)
                            }
                            ShortcutRecorderButton(
                                combo: combos[action],
                                isRecording: recording == action,
                                onStart: { startRecording(action) },
                                onRecord: { set($0, for: action) },
                                onCancel: { stopRecording() }
                            )
                            Button {
                                set(nil, for: action)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .opacity(combos[action] == nil ? 0 : 1)
                            .disabled(combos[action] == nil)
                            .help("Clear shortcut")
                            .accessibilityLabel("Clear \(action.title) shortcut")
                        }
                    }
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Click a shortcut, then press the new key combination. Esc cancels, ⌫ clears. Shortcuts work system-wide.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        store.resetToDefaults()
                        reload()
                        coordinator.registerShortcuts()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onDisappear { stopRecording() }
    }

    private func reload() {
        var result: [ShortcutAction: KeyCombo] = [:]
        for action in ShortcutAction.allCases {
            if let combo = store.combo(for: action) { result[action] = combo }
        }
        combos = result
    }

    private func startRecording(_ action: ShortcutAction) {
        // Release our own hot keys so pressing an existing combo records it
        // instead of triggering a capture.
        HotKeyCenter.shared.unregisterAll()
        recording = action
    }

    private func stopRecording() {
        guard recording != nil else { return }
        recording = nil
        coordinator.registerShortcuts()
    }

    private func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        // One combo, one action: take it away from any other action.
        if let combo {
            for (other, existing) in combos where other != action && existing == combo {
                store.setCombo(nil, for: other)
            }
        }
        store.setCombo(combo, for: action)
        recording = nil
        reload()
        coordinator.registerShortcuts()
    }

    private func warning(for action: ShortcutAction) -> String? {
        if coordinator.shortcutConflicts.contains(action) {
            return "Another app is already using this shortcut, so it won't work until you pick a different one."
        }
        if let combo = combos[action], KeyCombo.systemScreenshotCombos.contains(combo) {
            return "macOS uses this shortcut for its own screenshots. Turn it off in System Settings → Keyboard → Keyboard Shortcuts → Screenshots."
        }
        return nil
    }
}

private extension KeyCombo {
    /// ⇧⌘3, ⇧⌘4, ⇧⌘5 and their ⌃ clipboard variants.
    static let systemScreenshotCombos: Set<KeyCombo> = {
        var result: Set<KeyCombo> = []
        for key in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
            result.insert(KeyCombo(keyCode: UInt32(key), modifiers: [.command, .shift]))
            result.insert(KeyCombo(keyCode: UInt32(key), modifiers: [.command, .shift, .control]))
        }
        return result
    }()
}

/// A badge that turns into a key catcher when clicked.
private struct ShortcutRecorderButton: View {
    let combo: KeyCombo?
    let isRecording: Bool
    let onStart: () -> Void
    let onRecord: (KeyCombo?) -> Void
    let onCancel: () -> Void

    @State private var monitor: Any?
    @State private var liveModifiers: KeyCombo.Modifiers = []

    var body: some View {
        Button(action: isRecording ? onCancel : onStart) {
            Text(label)
                .font(.system(.body, design: .rounded).monospacedDigit())
                .foregroundStyle(isRecording ? AnyShapeStyle(Color.accentColor) : combo == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .frame(minWidth: 96)
                .padding(.horizontal, PK.Spacing.s)
                .padding(.vertical, PK.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .fill(.quaternary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: isRecording ? 1.5 : 0)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Recording shortcut. Press keys." : "Shortcut \(combo?.displayString ?? "not set"). Click to change.")
        .onChange(of: isRecording) { _, recording in
            recording ? installMonitor() : removeMonitor()
        }
        .onDisappear(perform: removeMonitor)
    }

    private var label: String {
        if isRecording {
            return liveModifiers.isEmpty ? "Type shortcut…" : liveModifiers.symbols + "…"
        }
        return combo?.displayString ?? "Record Shortcut"
    }

    private func installMonitor() {
        removeMonitor()
        liveModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                liveModifiers = KeyCombo.Modifiers(event.modifierFlags)
                return nil
            }
            let keyCode = Int(event.keyCode)
            let modifiers = KeyCombo.Modifiers(event.modifierFlags)
            if modifiers.isEmpty, keyCode == kVK_Escape {
                onCancel()
            } else if modifiers.isEmpty, keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
                onRecord(nil)
            } else if !modifiers.isEmpty || KeyCombo.isFunctionKey(keyCode) {
                // Plain letters would fire while typing in other apps; require a modifier (F-keys excepted).
                onRecord(KeyCombo(keyCode: UInt32(keyCode), modifiers: modifiers))
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        liveModifiers = []
    }
}
