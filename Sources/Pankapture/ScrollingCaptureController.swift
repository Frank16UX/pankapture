import AppCore
import AppKit
import Capture
import DesignSystem
import Overlay
import SwiftUI

/// Scrolling capture (SC-11): pick an area, scroll (by hand or automatically),
/// and the frames are stitched into one tall image with a live preview.
@MainActor
final class ScrollingCaptureController {
    private static var current: ScrollingCaptureController?

    private let area: PickedArea
    private let grabber: AreaGrabber
    private let session = StitchingSession()
    private let model = ScrollingCaptureModel()
    private let onFinish: (CGImage, CGFloat) -> Void
    private var frameWindow: NSPanel?
    private var hudWindow: NSPanel?
    private var loop: Task<Void, Never>?
    private var escapeToken: HotKeyCenter.Token?
    private var isFinishing = false
    private var isTornDown = false

    /// Starts the flow; `onFinish` receives the stitched image and its scale.
    static func start(onFinish: @escaping (CGImage, CGFloat) -> Void) async {
        guard current == nil, OverlayController.current == nil else { return }
        let windows = WindowList.onScreenWindows()
        guard let snapshots = try? await ScreenshotService.snapshotDisplays() else { return }

        let area: PickedArea? = await withCheckedContinuation { continuation in
            let presented = OverlayController.present(
                snapshots: snapshots, windows: windows,
                mode: .pick(confirmTitle: "Start Scrolling Capture", confirmSymbol: "arrow.up.and.down")
            ) { outcome in
                if case let .picked(area) = outcome { continuation.resume(returning: area) } else { continuation.resume(returning: nil) }
            }
            if presented == nil { continuation.resume(returning: nil) }
        }
        guard let area else { return }

        do {
            let grabber = try await AreaGrabber.make(displayID: area.displayID, rect: area.rect)
            let controller = ScrollingCaptureController(area: area, grabber: grabber, onFinish: onFinish)
            current = controller
            controller.begin()
        } catch {
            Log.capture.error("Scrolling capture failed: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    private init(area: PickedArea, grabber: AreaGrabber, onFinish: @escaping (CGImage, CGFloat) -> Void) {
        self.area = area
        self.grabber = grabber
        self.onFinish = onFinish
    }

    private var screenRect: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = area.globalRect
        return CGRect(x: global.minX, y: primaryHeight - global.maxY, width: global.width, height: global.height)
    }

    // MARK: Lifecycle

    private func begin() {
        showFrame()
        showHUD()
        model.onDone = { [weak self] in self?.finish() }
        model.onCancel = { [weak self] in self?.tearDown() }
        model.onToggleAutoScroll = { [weak self] in self?.toggleAutoScroll() }
        escapeToken = HotKeyCenter.shared.registerEscape { [weak self] in self?.tearDown() }
        loop = Task { [weak self] in await self?.captureLoop() }
    }

    private func captureLoop() async {
        var unchangedStreak = 0
        var unmatchedStreak = 0
        while !Task.isCancelled, !isFinishing {
            if let frame = try? await grabber.capture() {
                let result = await session.add(frame)
                switch result {
                case .first, .appended:
                    unchangedStreak = 0
                    unmatchedStreak = 0
                    model.preview = await session.preview(maxWidth: 360)
                    model.height = await session.height
                    if await session.isFull { finish(); return }
                case .unchanged:
                    unchangedStreak += 1
                case .unmatched:
                    unmatchedStreak += 1
                }
            }

            if model.isAutoScrolling, unmatchedStreak >= 8 {
                // Animated or changing content: stop scrolling and let the user decide.
                model.isAutoScrolling = false
                model.message = "The content keeps changing, so automatic scrolling stopped. Scroll by hand or press Done."
            }
            if model.isAutoScrolling {
                if unchangedStreak >= 4 {
                    // Reached the end of the content.
                    finish()
                    return
                }
                scrollContent()
                try? await Task.sleep(for: .milliseconds(320))
            } else {
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func toggleAutoScroll() {
        if !model.isAutoScrolling, Permissions.status(.accessibility) != .granted {
            Task { await Permissions.request(.accessibility) }
            model.message = "Allow Accessibility in System Settings to scroll automatically."
            return
        }
        model.isAutoScrolling.toggle()
    }

    /// Posts a scroll-wheel event over the area (needs Accessibility).
    private func scrollContent() {
        let center = CGPoint(x: area.globalRect.midX, y: area.globalRect.midY)
        let distance = Int32(-(area.rect.height * 0.4).rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                  wheel1: distance, wheel2: 0, wheel3: 0) else { return }
        event.location = center
        event.post(tap: .cghidEventTap)
    }

    private func finish() {
        guard !isFinishing, !isTornDown else { return }
        isFinishing = true
        model.isFinishing = true
        loop?.cancel()
        Task {
            let image = await session.makeImage()
            let scale = grabber.scale
            // Cancelled (Esc / Cancel) while the final image was being assembled.
            guard !isTornDown else { return }
            tearDown()
            if let image {
                onFinish(image, scale)
            } else {
                OutputService.presentError("Couldn't assemble the scrolling capture",
                                           CocoaError(.fileWriteOutOfSpace))
            }
        }
    }

    private func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        loop?.cancel()
        frameWindow?.orderOut(nil)
        hudWindow?.orderOut(nil)
        if let escapeToken { HotKeyCenter.shared.unregister(escapeToken) }
        escapeToken = nil
        Self.current = nil
    }

    // MARK: Windows

    private func showFrame() {
        let rect = screenRect.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let border = CAShapeLayer()
        border.path = CGPath(rect: CGRect(origin: .zero, size: rect.size).insetBy(dx: 1.5, dy: 1.5), transform: nil)
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 2
        border.lineDashPattern = [8, 5]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(border)
        panel.contentView = view
        panel.orderFrontRegardless()
        frameWindow = panel
    }

    private func showHUD() {
        let host = NSHostingView(rootView: ScrollingCaptureHUD(model: model))
        let size = CGSize(width: 220, height: 420)
        let screen = NSScreen.screens.first { $0.frame.intersects(screenRect) }?.visibleFrame ?? screenRect
        var origin = CGPoint(x: screenRect.maxX + 16, y: screenRect.maxY - size.height)
        if origin.x + size.width > screen.maxX { origin.x = screenRect.minX - 16 - size.width }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)

        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.orderFrontRegardless()
        hudWindow = panel
    }
}

/// Owns the stitcher off the main actor (stitching a frame takes a few ms).
private actor StitchingSession {
    private let stitcher = ScrollStitcher()

    func add(_ frame: CGImage) -> ScrollStitcher.FrameResult { stitcher.add(frame) }
    func preview(maxWidth: Int) -> CGImage? { stitcher.makePreview(maxWidth: maxWidth) }
    func makeImage() -> CGImage? { stitcher.makeImage() }
    var height: Int { stitcher.height }
    var isFull: Bool { stitcher.isFull }
}

@MainActor
@Observable
private final class ScrollingCaptureModel {
    var preview: CGImage?
    var height = 0
    var isAutoScrolling = false
    var isFinishing = false
    var message: String?
    @ObservationIgnored var onDone: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored var onToggleAutoScroll: (() -> Void)?
}

private struct ScrollingCaptureHUD: View {
    let model: ScrollingCaptureModel

    var body: some View {
        VStack(spacing: PK.Spacing.m) {
            Text(model.preview == nil ? "Starting…" : "Scroll down slowly")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))
                            .id("preview")
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: model.height) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PK.Radius.control, style: .continuous))

            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Text("\(model.height) px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Toggle("Scroll automatically", isOn: Binding(get: { model.isAutoScrolling }, set: { _ in model.onToggleAutoScroll?() }))
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack {
                Button("Cancel") { model.onCancel?() }
                Spacer()
                Button(model.isFinishing ? "Saving…" : "Done") { model.onDone?() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.preview == nil || model.isFinishing)
            }
        }
        .padding(PK.Spacing.m)
        .frame(width: 220, height: 420)
        .pkSurface(cornerRadius: PK.Radius.panel)
    }
}
