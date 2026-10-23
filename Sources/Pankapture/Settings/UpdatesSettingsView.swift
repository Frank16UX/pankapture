import AppCore
import DesignSystem
import SwiftUI

/// Version, automatic checks, and installing a newer release (UP-1).
struct UpdatesSettingsView: View {
    @AppStorage(PreferenceKey.updatesCheckAutomatically) private var checkAutomatically = true
    private let updates = UpdateController.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    Text("\(updates.currentVersion?.description ?? "?") (\(updates.buildNumber))")
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                Toggle("Check for updates automatically", isOn: $checkAutomatically)
            } footer: {
                Text("Checks GitHub once a day for a newer release. Nothing about you or your captures is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                status
            } footer: {
                if !updates.canInstall {
                    Text("This is a development build (make app). Release builds download updates in the background and install them on restart; here they open the release page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        switch updates.state {
        case .idle, .upToDate, .failed:
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                    statusTitle
                    if let lastCheck = updates.lastCheck {
                        Text("Last checked \(lastCheck, format: .relative(presentation: .named))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check Now") { updates.check() }
            }
        case .checking:
            HStack(spacing: PK.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
        case let .available(update):
            VStack(alignment: .leading, spacing: PK.Spacing.s) {
                Label("Pankapture \(update.version.description) is available", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                notes(update)
                HStack {
                    Button(updates.canInstall ? "Download Update" : "Open Release Page") { updates.install(update) }
                        .buttonStyle(.borderedProminent)
                    Button("Release Notes") { NSWorkspace.shared.open(update.pageURL) }
                    Spacer()
                    Button("Skip This Version") { updates.skip(update) }
                }
                Text("\(Format.bytes(update.byteCount)) download. Your settings, permissions, and history are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .downloading(update, progress):
            VStack(alignment: .leading, spacing: PK.Spacing.s) {
                Text("Downloading Pankapture \(update.version.description)…")
                ProgressView(value: progress)
                Text("You can keep working. Pankapture asks before restarting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .preparing(update):
            HStack(spacing: PK.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Preparing Pankapture \(update.version.description)…")
            }
        case let .ready(update):
            VStack(alignment: .leading, spacing: PK.Spacing.s) {
                Label("Pankapture \(update.version.description) is ready to install", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.accentColor)
                notes(update)
                HStack {
                    Button("Restart Now") { updates.restart() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updates.canRestartNow)
                    Button("Release Notes") { NSWorkspace.shared.open(update.pageURL) }
                }
                Text(updates.canRestartNow
                    ? "Or keep working: it installs the next time you quit Pankapture."
                    : "Stop the recording to restart. It also installs the next time you quit Pankapture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case let .restarting(update):
            Text("Pankapture \(update.version.description) installs when Pankapture quits.")
        }
    }

    @ViewBuilder private func notes(_ update: AvailableUpdate) -> some View {
        if !update.notes.isEmpty {
            ScrollView {
                Text(LocalizedStringKey(update.notes))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
        }
    }

    @ViewBuilder private var statusTitle: some View {
        switch updates.state {
        case .upToDate:
            Label("Pankapture is up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        default:
            Text("Software Update")
        }
    }
}

private enum Format {
    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
