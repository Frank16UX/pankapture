import AppCore
import AppKit
import DesignSystem
import ServiceManagement
import SwiftUI

/// First-run welcome (GL-7): shortcuts, the one required permission, and
/// launch at login. Optional permissions are asked for when first needed.
@MainActor
enum OnboardingWindow {
    private static var window: NSWindow?

    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: PreferenceKey.onboardingCompleted) else { return }
        show()
    }

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: OnboardingView { close() })
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func close() {
        UserDefaults.standard.set(true, forKey: PreferenceKey.onboardingCompleted)
        window?.close()
        window = nil
    }
}

private struct OnboardingView: View {
    let onDone: () -> Void

    @State private var screenRecording = Permissions.status(.screenRecording)
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let store = ShortcutStore()

    var body: some View {
        VStack(spacing: PK.Spacing.xl) {
            VStack(spacing: PK.Spacing.s) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Welcome to Pankapture")
                    .font(.largeTitle.weight(.semibold))
                Text("Screenshots, annotations, and screen recordings with sound. It lives in your menu bar.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: PK.Spacing.m) {
                row("rectangle.dashed", "Capture an area", store.combo(for: .captureArea)?.displayString ?? "—",
                    "Drag to select, annotate right there, then copy or save.")
                row("record.circle", "Record the screen", store.combo(for: .recordScreen)?.displayString ?? "—",
                    "With system audio, your microphone, and an optional webcam.")
                row("clock.arrow.circlepath", "Find it later", "Menu bar",
                    "Every capture is kept in a searchable history, including text inside images.")
            }
            .padding(PK.Spacing.l)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PK.Radius.panel, style: .continuous))

            VStack(alignment: .leading, spacing: PK.Spacing.m) {
                HStack {
                    Image(systemName: screenRecording == .granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(screenRecording == .granted ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                        .imageScale(.large)
                    VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                        Text("Screen & System Audio Recording").font(.headline)
                        Text(screenRecording == .granted
                             ? "Granted. You're all set."
                             : "Required to capture anything. macOS may ask you to reopen Pankapture after granting it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if screenRecording != .granted {
                        Button("Grant…") {
                            Task {
                                await Permissions.request(.screenRecording)
                                if Permissions.status(.screenRecording) != .granted {
                                    Permissions.openSystemSettings(for: .screenRecording)
                                }
                            }
                        }
                    }
                }
                Toggle("Open Pankapture when you log in", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    }
                Text("Microphone, camera, and accessibility access are requested only when you first use a feature that needs them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Get Started", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(PK.Spacing.xxl)
        .frame(width: 520)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenRecording = Permissions.status(.screenRecording)
        }
    }

    private func row(_ symbol: String, _ title: String, _ shortcut: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: PK.Spacing.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: PK.Spacing.xxs) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(shortcut)
                        .font(.system(.callout, design: .rounded).monospacedDigit())
                        .padding(.horizontal, PK.Spacing.s)
                        .padding(.vertical, PK.Spacing.xxs)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
