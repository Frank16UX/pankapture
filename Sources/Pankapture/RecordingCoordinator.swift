import AppCore
import AppKit
import Capture
import Overlay
import Recording
import SwiftUI

/// App-side glue for screen recording (M3, M4): the options panel, area
/// picking through the overlay, crash recovery, and the menu bar timer.
@MainActor
@Observable
final class RecordingCoordinator {
    let controller = RecordingController()
    @ObservationIgnored private var optionsPanel: NSPanel?
    @ObservationIgnored private var optionsCloseObserver: (any NSObjectProtocol)?

    var recorder: ScreenRecorder { controller.recorder }
    var isRecording: Bool { controller.recorder.state.isActive }

    init() {
        controller.areaProvider = { await Self.pickArea() }
    }

    /// The recording options panel (sources, audio, camera, extras).
    func showOptions() {
        if let optionsPanel {
            optionsPanel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: RecordingOptionsView(controller: controller) { [weak self] in
            self?.closeOptions()
        })
        // The panel gets an explicit size below. Letting SwiftUI resize it later
        // grows it upward from the bottom-left origin, off the top of the screen.
        host.sizingOptions = .minSize
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView, .utilityWindow]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Under the menu bar, near the right edge, like a menu bar popover.
        // The pointer sits on the menu bar's top edge, which NSMouseInRect excludes.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: 0, dy: -1).contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setContentSize(CGSize(width: 360, height: min(620, visible.height - 16)))
            let size = panel.frame.size
            panel.setFrameOrigin(CGPoint(x: max(visible.minX + 8, visible.maxX - size.width - 16),
                                         y: max(visible.minY + 8, visible.maxY - size.height - 8)))
        }
        // Closing the panel (its close button, ⌘W) cancels the setup. SwiftUI's
        // onDisappear doesn't fire for a closed window that's kept around, so
        // tell the controller directly; it hides the camera preview.
        optionsCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.optionsClosed() }
        }
        optionsPanel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func closeOptions() {
        optionsPanel?.close()
    }

    private func optionsClosed() {
        if let optionsCloseObserver { NotificationCenter.default.removeObserver(optionsCloseObserver) }
        optionsCloseObserver = nil
        optionsPanel = nil
        controller.optionsDidDisappear()
    }

    /// ⌥⇧⌘X: stop if recording, otherwise open the options.
    func toggleFromShortcut() {
        if controller.isBusy {
            controller.toggle()
        } else {
            showOptions()
        }
    }

    func stop() {
        Task { await controller.stop() }
    }

    // MARK: Area picking

    private static func pickArea() async -> AreaSelection? {
        let windows = WindowList.onScreenWindows(keeping: OwnWindows.capturableIDs())
        let snapshots: [DisplaySnapshot]
        do {
            snapshots = try await ScreenshotService.snapshotDisplays(ownWindowIDs: OwnWindows.capturableIDs())
        } catch {
            Log.recording.error("Area picking: display snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return await withCheckedContinuation { continuation in
            let presented = OverlayController.present(
                snapshots: snapshots, windows: windows,
                mode: .pick(confirmTitle: "Record", confirmSymbol: "record.circle")
            ) { outcome in
                if case let .picked(area) = outcome {
                    continuation.resume(returning: AreaSelection(displayID: area.displayID, rect: area.rect))
                } else {
                    continuation.resume(returning: nil)
                }
            }
            if presented == nil {
                Log.recording.notice("Area picking: overlay couldn't be presented (another overlay is open?)")
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: Crash recovery (REC-9)

    /// Offers to recover recordings interrupted by a crash or power loss.
    func recoverInterruptedRecordings(onRecovered: @escaping (URL) -> Void) async {
        let recovery = RecordingRecovery()
        recovery.removeOrphanedManifests()
        let pending = recovery.pending()
        guard !pending.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = pending.count == 1
            ? "Recover an unfinished recording?"
            : "Recover \(pending.count) unfinished recordings?"
        alert.informativeText = "Pankapture quit while recording. Everything up to the last couple of seconds can be saved to your capture folder."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        NSApp.activate()
        let response = alert.runModal()

        for recording in pending {
            if response == .alertFirstButtonReturn {
                do {
                    onRecovered(try await recovery.recover(recording))
                } catch {
                    Log.recording.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                recovery.discard(recording)
            }
        }
    }
}

/// Menu bar icon: the viewfinder, or a red dot with the elapsed time while recording.
struct MenuBarLabel: View {
    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let recorder = coordinator.recording.recorder
        Group {
            if recorder.state.isActive {
                Label(recorder.formattedElapsed, systemImage: recorder.state == .paused ? "pause.circle.fill" : "record.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            } else if case .ready = UpdateController.shared.state {
                Image(nsImage: Self.badgedIcon)
            } else {
                Image(systemName: "viewfinder")
            }
        }
        // The label lives for the whole session, so it hands the Settings
        // action to AppKit code (menu, reopen, second-instance hand-off).
        .onAppear { SettingsWindow.register(openSettings) }
    }

    /// The menu bar icon with a dot in its top-right corner: an update is
    /// ready to install. A template image, so it follows the menu bar's color.
    private static let badgedIcon: NSImage = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let size = symbol.size
        let dot = NSRect(x: size.width - 6.5, y: size.height - 6.5, width: 6.5, height: 6.5)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            // Clear a ring around the dot so it reads apart from the symbol.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pankapture, update ready"
        return image
    }()
}
