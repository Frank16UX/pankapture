import AppKit
import Carbon.HIToolbox
import DesignSystem
import Observation
import SwiftUI

/// Large 3-2-1 centered on the target display before capture starts (REC-7).
/// It's a Pankapture window, so it's never in the recording (and capture
/// hasn't started yet anyway). Esc or the close button cancels.
@MainActor
final class CountdownOverlay {
    @Observable
    final class Model {
        var remaining = 0
    }

    private let model = Model()
    private var panel: OverlayPanel?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var ticker: Task<Void, Never>?
    private var keyMonitor: Any?

    /// Shows the countdown and returns `true` when it completes, `false` if cancelled.
    func run(seconds: Int, on screen: NSScreen?, onTick: @escaping (Int) -> Void) async -> Bool {
        guard seconds > 0 else { return true }
        show(on: screen ?? NSScreen.main)
        let completed = await withCheckedContinuation { continuation in
            self.continuation = continuation
            ticker = Task { [weak self] in
                for remaining in stride(from: seconds, to: 0, by: -1) {
                    guard let self, !Task.isCancelled else { return }
                    self.model.remaining = remaining
                    onTick(remaining)
                    try? await Task.sleep(for: .seconds(1))
                }
                self?.finish(true)
            }
        }
        close()
        return completed
    }

    func cancel() {
        ticker?.cancel()
        finish(false)
    }

    private func finish(_ completed: Bool) {
        continuation?.resume(returning: completed)
        continuation = nil
    }

    private func show(on screen: NSScreen?) {
        let size = NSSize(width: 220, height: 220)
        let frame = screen?.frame ?? .zero
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        let panel = OverlayPanel(contentRect: NSRect(origin: origin, size: size), level: .recordingPicker, clickThrough: false)
        panel.allowsKey = true
        panel.contentView = NSHostingView(rootView: CountdownView(model: model) { [weak self] in self?.cancel() })
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
    }

    private func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CountdownView: View {
    let model: CountdownOverlay.Model
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: PK.Spacing.s) {
            Text("\(model.remaining)")
                .font(.system(size: 96, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(reduceMotion ? .opacity : .numericText(countsDown: true))
                .animation(reduceMotion ? .linear(duration: 0.1) : PK.Motion.standard, value: model.remaining)
                .foregroundStyle(.primary)
            Text("Press Esc to cancel")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 180, height: 180)
        .pkSurface(cornerRadius: PK.Radius.panel)
        .overlay(alignment: .topTrailing) {
            Button(action: onCancel) {
                Image(systemName: "xmark")
            }
            .buttonStyle(PKToolButtonStyle())
            .help("Cancel recording")
            .accessibilityLabel("Cancel recording")
            .padding(PK.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recording starts in \(model.remaining)")
    }
}
