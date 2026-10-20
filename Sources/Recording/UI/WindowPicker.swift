import AppKit
import Carbon.HIToolbox
import DesignSystem
import Observation
import SwiftUI

/// Picks a recording source by hovering and clicking (REC-1).
///
/// We use our own highlight-on-hover overlay rather than the system content
/// picker: it returns a plain `CGWindowID`/`CGDirectDisplayID` (what
/// `RecordingConfiguration.Source` needs), matches the screenshot flow's look,
/// and doesn't add a system sharing indicator.
@MainActor
public final class WindowPicker {
    public enum Mode: Sendable {
        case window
        case display
    }

    private var panels: [OverlayPanel] = []
    private var continuation: CheckedContinuation<Choice?, Never>?
    private var keyMonitor: Any?
    private let model = PickerModel()
    private var candidates: [WindowCandidate] = []
    private var mode: Mode = .window

    enum Choice {
        case window(CGWindowID)
        case display(CGDirectDisplayID)
    }

    public init() {}

    /// Lets the user click a window. `nil` if cancelled (Esc / right-click).
    public func pickWindow() async -> CGWindowID? {
        if case .window(let id) = await run(.window) { return id }
        return nil
    }

    /// Lets the user click a display. Returns immediately with one display.
    public func pickDisplay() async -> CGDirectDisplayID? {
        if NSScreen.screens.count == 1 { return NSScreen.screens.first?.displayID }
        if case .display(let id) = await run(.display) { return id }
        return nil
    }

    public func cancel() { finish(nil) }

    // MARK: Session

    private func run(_ mode: Mode) async -> Choice? {
        self.mode = mode
        candidates = mode == .window ? WindowCandidate.onScreen() : []
        model.instructions = mode == .window
            ? "Click a window to record · Esc to cancel"
            : "Click a display to record · Esc to cancel"
        showPanels()
        updateHighlight(at: NSEvent.mouseLocation)
        let choice = await withCheckedContinuation { self.continuation = $0 }
        closePanels()
        return choice
    }

    private func finish(_ choice: Choice?) {
        continuation?.resume(returning: choice)
        continuation = nil
    }

    private func showPanels() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(contentRect: screen.frame, level: .recordingPicker, clickThrough: false)
            panel.allowsKey = true
            panel.acceptsMouseMovedEvents = true
            let view = PickerTrackingView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onMove = { [weak self] in self?.updateHighlight(at: NSEvent.mouseLocation) }
            view.onClick = { [weak self] in self?.choose(at: NSEvent.mouseLocation) }
            view.onCancel = { [weak self] in self?.cancel() }
            let hosting = PassthroughHostingView(rootView: PickerHighlightView(model: model, screenFrame: screen.frame))
            hosting.frame = view.bounds
            hosting.autoresizingMask = [.width, .height]
            view.addSubview(hosting)
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        (panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? panels.first)?.makeKey()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { self?.cancel() }
            return nil
        }
        NSCursor.pointingHand.push()
    }

    private func closePanels() {
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for panel in panels { panel.orderOut(nil) }
        panels = []
        model.highlight = nil
    }

    // MARK: Hit testing (AppKit global in, Quartz for window bounds)

    private func updateHighlight(at appKitPoint: CGPoint) {
        switch mode {
        case .window:
            if let candidate = candidate(at: appKitPoint) {
                model.highlight = RecordingGeometry.appKitRect(
                    fromQuartz: candidate.quartzFrame, primaryDisplayHeight: ScreenGeometry.primaryDisplayHeight
                )
                model.label = candidate.label
            } else {
                model.highlight = nil
            }
        case .display:
            let screen = NSScreen.screens.first { NSMouseInRect(appKitPoint, $0.frame, false) }
            model.highlight = screen?.frame
            model.label = screen?.localizedName ?? ""
        }
    }

    private func choose(at appKitPoint: CGPoint) {
        switch mode {
        case .window:
            guard let candidate = candidate(at: appKitPoint) else { return }
            finish(.window(candidate.id))
        case .display:
            guard let id = NSScreen.screens.first(where: { NSMouseInRect(appKitPoint, $0.frame, false) })?.displayID
            else { return }
            finish(.display(id))
        }
    }

    private func candidate(at appKitPoint: CGPoint) -> WindowCandidate? {
        let quartzPoint = RecordingGeometry.quartzPoint(
            fromAppKit: appKitPoint, primaryDisplayHeight: ScreenGeometry.primaryDisplayHeight
        )
        return candidates.first { $0.quartzFrame.contains(quartzPoint) } // front-to-back order
    }
}

/// An on-screen, normal-level window of another app.
struct WindowCandidate {
    let id: CGWindowID
    let quartzFrame: CGRect
    let appName: String
    let title: String

    var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }

    /// Front-to-back list, excluding our own windows, menus, and tiny windows.
    static func onScreen() -> [WindowCandidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            return WindowCandidate(
                id: CGWindowID(number),
                quartzFrame: bounds,
                appName: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? ""
            )
        }
    }
}

@MainActor
@Observable
final class PickerModel {
    /// AppKit global.
    var highlight: CGRect?
    var label = ""
    var instructions = ""
}

/// Receives mouse/keyboard for the picker; SwiftUI content draws on top.
private final class PickerTrackingView: NSView {
    var onMove: () -> Void = {}
    var onClick: () -> Void = {}
    var onCancel: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseMoved(with event: NSEvent) { onMove() }
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func rightMouseDown(with event: NSEvent) { onCancel() }
}

/// SwiftUI layer that never takes mouse events, so the tracking view gets them.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PickerHighlightView: View {
    let model: PickerModel
    /// This panel's screen, AppKit global.
    let screenFrame: CGRect

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let highlight = model.highlight, highlight.intersects(screenFrame) {
                let local = CGRect(
                    x: highlight.minX - screenFrame.minX,
                    y: screenFrame.maxY - highlight.maxY, // SwiftUI is y-down
                    width: highlight.width,
                    height: highlight.height
                )
                ZStack {
                    RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                    RoundedRectangle(cornerRadius: PK.Radius.thumbnail, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                    if !model.label.isEmpty {
                        Text(model.label)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, PK.Spacing.m)
                            .padding(.vertical, PK.Spacing.s)
                            .pkSurface(cornerRadius: PK.Radius.control)
                            .padding(PK.Spacing.l)
                    }
                }
                .frame(width: local.width, height: local.height)
                .position(x: local.midX, y: local.midY)
                .allowsHitTesting(false)
            }
            Text(model.instructions)
                .font(.callout)
                .padding(.horizontal, PK.Spacing.m)
                .padding(.vertical, PK.Spacing.s)
                .pkSurface(cornerRadius: PK.Radius.toolbar)
                .padding(.top, PK.Spacing.xxl)
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
    }
}
