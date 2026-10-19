import AppCore
import DesignSystem
import SwiftUI

/// Read-only shortcut list for M0. The shortcut recorder lands in M1
/// (see docs/ROADMAP.md).
struct ShortcutsSettingsView: View {
    @Environment(CaptureCoordinator.self) private var coordinator
    private let store = ShortcutStore()

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: PK.Spacing.s) {
                            if coordinator.shortcutConflicts.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Another app is already using this shortcut.")
                            }
                            ShortcutBadge(text: store.combo(for: action)?.displayString)
                        }
                    }
                }
            } footer: {
                Text("Shortcuts work system-wide, even when Pankapture is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutBadge: View {
    let text: String?

    var body: some View {
        Text(text ?? "Not set")
            .font(.system(.body, design: .rounded).monospacedDigit())
            .foregroundStyle(text == nil ? .tertiary : .primary)
            .padding(.horizontal, PK.Spacing.s)
            .padding(.vertical, PK.Spacing.xxs)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
    }
}
