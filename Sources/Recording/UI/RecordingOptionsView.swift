import AppCore
import AppKit
import AVFoundation
import DesignSystem
import SwiftUI

/// Recording setup for a popover or panel (REC-1…REC-15): source, audio,
/// camera, video, and overlay options, plus the Record button. Choices persist
/// through `PreferenceKey.recording*`.
///
/// Host it anywhere; it calls `controller.optionsDidAppear/Disappear` itself.
/// `onDismiss` is called right after Record is pressed so the host can close
/// the popover (the recording flow continues without it).
public struct RecordingOptionsView: View {
    private let controller: RecordingController
    private let onDismiss: () -> Void

    public init(controller: RecordingController, onDismiss: @escaping () -> Void = {}) {
        self.controller = controller
        self.onDismiss = onDismiss
    }

    private var model: RecordingOptionsModel { controller.optionsModel }

    public var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            SourcePicker(selection: $model.selectedSource)
                .padding(.horizontal, PK.Spacing.l)
                .padding(.top, PK.Spacing.l)
                .padding(.bottom, PK.Spacing.s)

            Form {
                if model.selectedSource == .window {
                    WindowSection(model: model)
                }
                AudioSection(model: model)
                CameraSection(model: model)
                VideoSection(options: $model.options)
                OverlaySection(model: model)
                FocusHint()
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                if model.options.countdown > 0 {
                    Text("Starts after a \(model.options.countdown)-second countdown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if model.selectedSource == .window, let windowID = model.chosenWindowID {
                        controller.record(source: .window(windowID))
                    } else {
                        controller.record(model.selectedSource)
                    }
                    onDismiss()
                } label: {
                    Label("Record", systemImage: "record.circle")
                        .padding(.horizontal, PK.Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isBusy)
                .help("Start recording the selected \(model.selectedSource.title.lowercased())")
            }
            .padding(PK.Spacing.m)
        }
        .frame(width: 360)
        .frame(minHeight: 420, idealHeight: 620)
        .onAppear { controller.optionsDidAppear() }
        .onDisappear { controller.optionsDidDisappear() }
    }
}

// MARK: Source

private struct SourcePicker: View {
    @Binding var selection: RecordingOptions.SourceKind

    var body: some View {
        HStack(spacing: PK.Spacing.s) {
            ForEach(RecordingOptions.SourceKind.allCases) { kind in
                let isSelected = selection == kind
                Button {
                    selection = kind
                } label: {
                    VStack(spacing: PK.Spacing.xs) {
                        Image(systemName: kind.symbolName)
                            .font(.system(size: 20, weight: .medium))
                            .symbolRenderingMode(.hierarchical)
                            .frame(height: 24)
                        Text(kind.title)
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, PK.Spacing.s)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                    .background(
                        RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                            .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.quaternary.opacity(0.5)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator), lineWidth: isSelected ? 1.5 : PK.Metrics.hairline)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record \(kind.title.lowercased())")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .animation(PK.Motion.quick, value: isSelected)
            }
        }
    }
}

// MARK: Window

/// Choose the window from a list: reaches windows hidden behind a full-screen
/// app or in another Space, which clicking on screen can't.
private struct WindowSection: View {
    @Bindable var model: RecordingOptionsModel

    var body: some View {
        Section {
            Picker("Window", selection: $model.chosenWindowID) {
                Text("Click a window on screen").tag(CGWindowID?.none)
                ForEach(appNames, id: \.self) { appName in
                    Section(appName) {
                        ForEach(model.windows.filter { $0.appName == appName }) { window in
                            Text(window.title).tag(CGWindowID?.some(window.id))
                        }
                    }
                }
            }
        }
        .task { await model.refreshWindows() }
    }

    /// App names in list order, each once.
    private var appNames: [String] {
        var seen = Set<String>()
        return model.windows.map(\.appName).filter { seen.insert($0).inserted }
    }
}

// MARK: Audio

private struct AudioSection: View {
    @Bindable var model: RecordingOptionsModel

    var body: some View {
        Section("Audio") {
            Toggle(isOn: $model.options.capturesSystemAudio) {
                Label("System audio", systemImage: "speaker.wave.2")
            }
            .disabled(model.options.outputKind == .gif)

            Toggle(isOn: micBinding) {
                Label("Microphone", systemImage: "mic")
            }
            .disabled(model.options.outputKind == .gif)

            if model.options.capturesMicrophone, model.options.outputKind == .video {
                if model.microphonePermission == .granted {
                    Picker("Input", selection: $model.options.microphoneDeviceID) {
                        Text("System Default").tag(String?.none)
                        ForEach(model.microphones) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    LevelMeter(level: model.levelMonitor.level)
                } else {
                    PermissionRow(kind: .microphone, status: model.microphonePermission) {
                        await model.requestMicrophoneAccess()
                    }
                }
            }
            if model.options.outputKind == .gif {
                Text("GIFs have no sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var micBinding: Binding<Bool> {
        Binding {
            model.options.capturesMicrophone
        } set: { isOn in
            model.options.capturesMicrophone = isOn
            if isOn, model.microphonePermission == .notDetermined {
                Task { await model.requestMicrophoneAccess() }
            }
        }
    }
}

/// Horizontal input meter (REC-3).
private struct LevelMeter: View {
    var level: Float

    var body: some View {
        LabeledContent("Level") {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(level > 0.9 ? AnyShapeStyle(.red) : AnyShapeStyle(Color.accentColor))
                        .frame(width: proxy.size.width * CGFloat(min(max(level, 0), 1)))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
            .frame(maxWidth: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: Camera

private struct CameraSection: View {
    @Bindable var model: RecordingOptionsModel

    var body: some View {
        Section("Camera") {
            Toggle(isOn: $model.options.showsCamera) {
                Label("Show camera", systemImage: "web.camera")
            }
            if model.options.showsCamera {
                if model.cameraPermission == .notGranted {
                    PermissionRow(kind: .camera, status: model.cameraPermission) {
                        await model.requestCameraAccess()
                    }
                } else {
                    Picker("Camera", selection: $model.options.cameraDeviceID) {
                        Text("System Default").tag(String?.none)
                        ForEach(model.cameras) { device in
                            Text(device.name).tag(String?.some(device.id))
                        }
                    }
                    FittingSegmentedPicker("Shape", selection: $model.options.cameraShape) {
                        ForEach(RecordingOptions.CameraShape.allCases) { shape in
                            Label(shape.title, systemImage: shape.symbolName).tag(shape)
                        }
                    }
                    LabeledContent("Size") {
                        Slider(value: $model.options.cameraSize, in: RecordingOptions.cameraSizeRange)
                            .frame(maxWidth: 160)
                            .accessibilityLabel("Camera size")
                    }
                    Toggle("Mirror", isOn: $model.options.cameraMirrored)
                    FittingSegmentedPicker("Save camera", selection: $model.options.cameraAsLayer) {
                        Text("As a layer").tag(true)
                        Text("In the video").tag(false)
                    }
                    Text(model.options.cameraAsLayer
                         ? "Move, resize, or hide the camera in the editor. The saved video takes a moment after you stop while the camera is added."
                         : "The camera is recorded as you see it, in one video file that's saved as soon as you stop. It can't be moved later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LabeledContent("Effects") {
                        Button("Video Effects…") { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
                    }
                    Text(model.options.cameraAsLayer
                         ? "macOS effects, like portrait blur, are recorded into the camera and can't be undone. A background set in the editor can."
                         : "macOS effects, like portrait blur or a replaced background, are the only way to change the camera's background when it's saved in the video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Drag the bubble to move it. Drag its corner or ⌘-scroll to resize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Video

private struct VideoSection: View {
    @Binding var options: RecordingOptions

    var body: some View {
        Section("Video") {
            Picker("Format", selection: $options.outputKind) {
                ForEach(RecordingOptions.OutputKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Frame rate", selection: $options.framesPerSecond) {
                ForEach(RecordingOptions.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            FittingSegmentedPicker("Quality", selection: $options.quality) {
                ForEach(RecordingConfiguration.Quality.allCases) { Text($0.title).tag($0) }
            }
            Picker("Codec", selection: $options.codec) {
                ForEach(RecordingConfiguration.Codec.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(options.outputKind == .gif)
            Picker("Countdown", selection: $options.countdown) {
                ForEach(RecordingOptions.countdowns, id: \.self) { seconds in
                    Text(seconds == 0 ? "Off" : "\(seconds) s").tag(seconds)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: Overlays

private struct OverlaySection: View {
    @Bindable var model: RecordingOptionsModel

    var body: some View {
        Section {
            Toggle(isOn: $model.options.showsCursor) {
                Label("Show cursor", systemImage: "cursorarrow")
            }
            Toggle(isOn: $model.options.highlightsClicks) {
                Label("Highlight clicks", systemImage: "cursorarrow.click")
            }
            if model.options.highlightsClicks {
                LabeledContent("Ring color") {
                    ClickColorSwatches(selection: $model.options.clickColor)
                }
                LabeledContent("Ring size") {
                    Slider(value: $model.options.clickSize, in: RecordingOptions.clickSizeRange)
                        .frame(maxWidth: 160)
                        .accessibilityLabel("Click ring size")
                }
            }
            Toggle(isOn: keystrokesBinding) {
                Label("Show keystrokes", systemImage: "keyboard")
            }
            if model.options.showsKeystrokes {
                if model.accessibilityPermission == .granted {
                    Toggle("Show all keys, not just shortcuts", isOn: $model.options.keystrokesShowAllKeys)
                } else {
                    PermissionRow(kind: .accessibility, status: model.accessibilityPermission) {
                        await model.requestAccessibilityAccess()
                    }
                }
            }
            Toggle(isOn: $model.options.hidesDesktopIcons) {
                Label("Hide desktop icons", systemImage: "menubar.dock.rectangle")
            }
        } header: {
            Text("While recording")
        } footer: {
            if model.selectedSource == .window,
               model.options.highlightsClicks || model.options.showsKeystrokes || model.options.showsCamera {
                Text("Window recordings capture only the window itself, so the camera, click rings, and keystrokes won't appear in them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var keystrokesBinding: Binding<Bool> {
        Binding {
            model.options.showsKeystrokes
        } set: { isOn in
            model.options.showsKeystrokes = isOn
            if isOn, model.accessibilityPermission != .granted {
                Task { await model.requestAccessibilityAccess() }
            }
        }
    }
}

/// Click-ring color choice as swatches. The swatch fills are the ring colors
/// themselves (content), the selection ring is the accent color (chrome).
private struct ClickColorSwatches: View {
    @Binding var selection: RecordingOptions.ClickColor

    var body: some View {
        HStack(spacing: PK.Spacing.s) {
            ForEach(RecordingOptions.ClickColor.allCases) { color in
                let isSelected = selection == color
                Button {
                    selection = color
                } label: {
                    Circle()
                        .fill(Color(.sRGB, red: color.rgb.red, green: color.rgb.green, blue: color.rgb.blue))
                        .overlay(Circle().strokeBorder(.separator, lineWidth: PK.Metrics.hairline))
                        .frame(width: PK.Metrics.swatch, height: PK.Metrics.swatch)
                        .padding(2)
                        .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.title)
                .accessibilityLabel(color.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

// MARK: Shared rows

private struct PermissionRow: View {
    let kind: PermissionKind
    let status: PermissionStatus
    let request: () async -> Void

    var body: some View {
        HStack(spacing: PK.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)
            Text("\(kind.title) access is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if status == .notDetermined {
                Button("Allow…") { Task { await request() } }
            } else {
                Button("Open Settings") { Permissions.openSystemSettings(for: kind) }
            }
        }
    }
}

/// REC-15: macOS doesn't let apps turn on Focus, so remind the user.
private struct FocusHint: View {
    var body: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: PK.Spacing.s) {
                Image(systemName: "moon.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Turn on a Focus (Do Not Disturb) to keep notifications out of your recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Focus Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
