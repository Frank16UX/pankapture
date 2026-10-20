import AppKit
import DesignSystem
import SwiftUI

/// Floating recording HUD (REC-6): timer, pause/resume, restart, mic mute,
/// discard, stop. A Pankapture window, so it's automatically excluded from
/// the recording. Appears bottom-center of the recorded display; drag it by
/// the timer.
@MainActor
public final class RecordingControlBar {
    public struct Actions {
        public var stop: () -> Void
        public var discard: () -> Void
        public var restart: () -> Void

        public init(stop: @escaping () -> Void, discard: @escaping () -> Void, restart: @escaping () -> Void) {
            self.stop = stop
            self.discard = discard
            self.restart = restart
        }
    }

    private let recorder: ScreenRecorder
    private let actions: Actions
    private var panel: OverlayPanel?

    public init(recorder: ScreenRecorder, actions: Actions) {
        self.recorder = recorder
        self.actions = actions
    }

    public var isVisible: Bool { panel != nil }

    /// Shows the bar near the bottom of `screen` (default: the main screen).
    public func show(on screen: NSScreen?) {
        hide()
        let hosting = FittingHostingView(rootView: RecordingHUD(recorder: recorder, actions: actions))
        let size = hosting.fittingSize
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY + PK.Spacing.xl)
        let panel = OverlayPanel(contentRect: NSRect(origin: origin, size: size), level: .recordingOverlay, clickThrough: false)
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct RecordingHUD: View {
    let recorder: ScreenRecorder
    let actions: RecordingControlBar.Actions

    @State private var confirmingDiscard = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isPaused: Bool { recorder.state == .paused }
    private var hasMicrophone: Bool { recorder.configuration?.capturesMicrophone == true }

    var body: some View {
        HStack(spacing: PK.Spacing.xs) {
            status
                .padding(.horizontal, PK.Spacing.s)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .help("Drag to move")

            Divider().frame(height: PK.Metrics.toolButton - PK.Spacing.s)

            Button(action: recorder.togglePause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(PKToolButtonStyle())
            .help(isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

            Button(action: actions.restart) {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(PKToolButtonStyle())
            .help("Restart recording")
            .accessibilityLabel("Restart recording")
            .accessibilityHint("Discards this take and starts again")

            if hasMicrophone {
                Button(action: recorder.toggleMicrophoneMute) {
                    Image(systemName: recorder.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill")
                        .overlay(alignment: .bottom) { micLevel }
                }
                .buttonStyle(PKToolButtonStyle(isSelected: recorder.isMicrophoneMuted))
                .help(recorder.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
                .accessibilityLabel(recorder.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
            }

            Divider().frame(height: PK.Metrics.toolButton - PK.Spacing.s)

            Button(action: discardTapped) {
                Image(systemName: confirmingDiscard ? "trash.fill" : "trash")
                    .foregroundStyle(confirmingDiscard ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
            .buttonStyle(PKToolButtonStyle())
            .help(confirmingDiscard ? "Click again to discard this recording" : "Discard recording")
            .accessibilityLabel(confirmingDiscard ? "Confirm discard" : "Discard recording")

            Button(action: actions.stop) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(PKToolButtonStyle())
            .help("Stop and save")
            .accessibilityLabel("Stop recording")
            .accessibilityHint("Stops and saves the recording")
        }
        .padding(PK.Spacing.xs)
        .pkSurface(cornerRadius: PK.Radius.toolbar)
        .padding(PK.Spacing.l) // room for the macOS 15 surface shadow
        .fixedSize()
    }

    private var status: some View {
        HStack(spacing: PK.Spacing.s) {
            Circle()
                .fill(isPaused ? AnyShapeStyle(.yellow) : AnyShapeStyle(.red))
                .frame(width: 8, height: 8)
                .phaseAnimator([false, true]) { dot, dimmed in
                    dot.opacity(isPaused || reduceMotion ? 1 : (dimmed ? 0.35 : 1))
                } animation: { _ in .easeInOut(duration: 0.8) }
                .accessibilityHidden(true)
            Text(Self.format(recorder.elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(isPaused ? .secondary : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPaused ? "Paused at \(Self.format(recorder.elapsed))" : "Recording, \(Self.format(recorder.elapsed))")
    }

    private var micLevel: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * CGFloat(recorder.microphoneLevel), height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .offset(y: 4)
        .opacity(recorder.isMicrophoneMuted ? 0 : 1)
        .accessibilityHidden(true)
    }

    private func discardTapped() {
        if confirmingDiscard {
            confirmingDiscard = false
            actions.discard()
            return
        }
        withAnimation(PK.Motion.quick) { confirmingDiscard = true }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(PK.Motion.quick) { confirmingDiscard = false }
        }
    }

    /// `m:ss`, or `h:mm:ss` past an hour.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
