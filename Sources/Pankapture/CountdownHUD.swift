import AppKit
import DesignSystem
import SwiftUI

/// Big centered countdown for the self-timer (SC-9). Esc cancels.
@MainActor
enum CountdownHUD {
    private static var panel: NSPanel?
    private static var task: Task<Void, Never>?
    private static var monitor: Any?

    static func run(seconds: Int, then action: @escaping @MainActor () -> Void) {
        cancel()
        let model = CountdownModel(remaining: seconds)
        let host = NSHostingView(rootView: CountdownView(model: model))
        let size = CGSize(width: 140, height: 140)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let hud = NSPanel(contentRect: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                              width: size.width, height: size.height),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.level = .statusBar
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.ignoresMouseEvents = true
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hud.contentView = host
        hud.orderFrontRegardless()
        panel = hud

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { MainActor.assumeIsolated { cancel() } }
        }

        task = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                model.remaining = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            close()
            action()
        }
    }

    static func cancel() {
        task?.cancel()
        task = nil
        close()
    }

    private static func close() {
        panel?.orderOut(nil)
        panel = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

@MainActor
@Observable
private final class CountdownModel {
    var remaining: Int
    init(remaining: Int) { self.remaining = remaining }
}

private struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText(countsDown: true))
            .animation(PK.Motion.standard, value: model.remaining)
            .frame(width: 120, height: 120)
            .pkSurface(cornerRadius: 60)
            .accessibilityLabel("Capturing in \(model.remaining) seconds")
    }
}
