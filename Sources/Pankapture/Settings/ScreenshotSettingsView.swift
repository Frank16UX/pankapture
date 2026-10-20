import AppCore
import SwiftUI

/// Screenshot options: after-capture extras (GL-9), quick-access thumbnail
/// (QA-1, QA-4), window and fullscreen capture (SC-6, SC-7, SC-10).
struct ScreenshotSettingsView: View {
    @AppStorage(PreferenceKey.showThumbnail) private var showThumbnail = true
    @AppStorage(PreferenceKey.thumbnailPosition) private var thumbnailPosition = "right"
    @AppStorage(PreferenceKey.thumbnailAutoDismissSeconds) private var autoDismiss = 10.0
    @AppStorage(PreferenceKey.openEditorAfterCapture) private var openEditor = false
    @AppStorage(PreferenceKey.windowCaptureShadow) private var windowShadow = true
    @AppStorage(PreferenceKey.fullscreenAllDisplays) private var allDisplays = false
    @AppStorage(PreferenceKey.captureShowsCursor) private var showsCursor = false
    @AppStorage(PreferenceKey.captureHidesDesktopIcons) private var hidesDesktopIcons = false

    var body: some View {
        Form {
            Section {
                Toggle("Show quick-access thumbnail", isOn: $showThumbnail)
                Picker("Position", selection: $thumbnailPosition) {
                    Text("Bottom left").tag("left")
                    Text("Bottom right").tag("right")
                }
                .disabled(!showThumbnail)
                Picker("Hide after", selection: $autoDismiss) {
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("Never").tag(0.0)
                }
                .disabled(!showThumbnail)
                Toggle("Open the editor", isOn: $openEditor)
            } header: {
                Text("After window and fullscreen captures")
            } footer: {
                Text("Area captures open the inline editor; press ↩ there to apply the copy and save settings from General.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                Toggle("Include window shadow", isOn: $windowShadow)
                Toggle("Fullscreen captures all displays", isOn: $allDisplays)
                Toggle("Show the mouse pointer", isOn: $showsCursor)
                Toggle("Hide desktop icons", isOn: $hidesDesktopIcons)
            }
        }
        .formStyle(.grouped)
    }
}
