import AppCore
import DesignSystem
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var statuses: [PermissionKind: PermissionStatus] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, status: statuses[kind] ?? .notDetermined) {
                        Task {
                            if statuses[kind] == .notDetermined || kind == .screenRecording {
                                await Permissions.request(kind)
                            }
                            if Permissions.status(kind) != .granted {
                                Permissions.openSystemSettings(for: kind)
                            }
                            refresh()
                        }
                    }
                }
            } footer: {
                Text("Pankapture works entirely offline. Captures never leave your Mac unless you share them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        // Re-check when returning from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        for kind in PermissionKind.allCases {
            statuses[kind] = Permissions.status(kind)
        }
    }
}

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PK.Spacing.m) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(status == .granted ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                .imageScale(.large)

            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                HStack(spacing: PK.Spacing.xs) {
                    Text(kind.title)
                    if kind.isRequired {
                        Text("Required")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, PK.Spacing.xs)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status != .granted {
                Button("Grant…", action: action)
            }
        }
        .padding(.vertical, PK.Spacing.xxs)
    }
}
