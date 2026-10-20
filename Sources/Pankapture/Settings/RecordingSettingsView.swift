import AppCore
import SwiftUI

/// Recording preferences that aren't per-take (the options panel holds those).
struct RecordingSettingsView: View {
    @Environment(CaptureCoordinator.self) private var coordinator
    @AppStorage(PreferenceKey.videoEditorOpenAfterRecording) private var openEditor = false
    @AppStorage(PreferenceKey.recordingCodec) private var codec = "h264"
    @AppStorage(PreferenceKey.recordingFrameRate) private var frameRate = 60
    @AppStorage(PreferenceKey.recordingQuality) private var quality = "medium"

    var body: some View {
        Form {
            Section {
                Toggle("Open the video editor after recording", isOn: $openEditor)
            } footer: {
                Text("Otherwise the recording waits as a thumbnail; choose Edit there to trim, cut, zoom, or export a GIF.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Video") {
                Picker("Format", selection: $codec) {
                    Text("H.264 (most compatible)").tag("h264")
                    Text("HEVC (smaller files)").tag("hevc")
                }
                Picker("Frame rate", selection: $frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Picker("Quality", selection: $quality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
            }

            Section {
                Button("Recording Options…") { coordinator.recording.showOptions() }
            } footer: {
                Text("Audio, microphone, camera, click highlights, and keystrokes are set per recording in the options panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
