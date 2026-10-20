import AppKit
import QuartzCore

/// Draws an expanding ring wherever the user clicks (REC-11). One transparent,
/// click-through panel per covered display; the panels are Pankapture windows
/// that **are** recorded, so pass `windowIDs` in
/// `RecordingConfiguration.includedOverlayWindowIDs`.
///
/// Global mouse-down monitors need no permission. Click *metadata* for the
/// sidecar is logged separately by `ScreenRecorder`.
@MainActor
public final class ClickHighlighter {
    public struct Style: Equatable, Sendable {
        public var color: RecordingOptions.ClickColor
        /// Ring diameter in points at full size.
        public var diameter: Double

        public init(color: RecordingOptions.ClickColor = .yellow, diameter: Double = 44) {
            self.color = color
            self.diameter = diameter
        }
    }

    public var style: Style
    private var panels: [OverlayPanel] = []
    private var monitors: [Any] = []

    public init(style: Style = Style()) {
        self.style = style
    }

    public var windowIDs: [CGWindowID] { panels.map(\.windowID) }
    public var isActive: Bool { !panels.isEmpty }

    /// Covers `displayIDs` (all displays if `nil`) and starts listening for clicks.
    public func start(on displayIDs: [CGDirectDisplayID]? = nil) {
        stop()
        let screens = NSScreen.screens.filter { screen in
            displayIDs.map { ids in screen.displayID.map(ids.contains) ?? false } ?? true
        }
        for screen in screens {
            let panel = OverlayPanel(contentRect: screen.frame, level: .recordingOverlay, clickThrough: true)
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            panel.contentView = view
            // Ordered in (and kept in) while recording, even though it's empty,
            // so ScreenCaptureKit always knows the window.
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isRight = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.ring(at: NSEvent.mouseLocation, isRight: isRight) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let isRight = event.type == .rightMouseDown
            MainActor.assumeIsolated { self?.ring(at: NSEvent.mouseLocation, isRight: isRight) }
            return event
        }) { monitors.append(local) }
    }

    public func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        for panel in panels { panel.orderOut(nil) }
        panels = []
    }

    /// `appKitPoint` is AppKit global.
    func ring(at appKitPoint: CGPoint, isRight: Bool) {
        guard let panel = panels.first(where: { NSMouseInRect(appKitPoint, $0.frame, false) }),
              let layer = panel.contentView?.layer else { return }
        let local = CGPoint(x: appKitPoint.x - panel.frame.minX, y: appKitPoint.y - panel.frame.minY)
        let diameter = CGFloat(style.diameter)
        let rgb = style.color.rgb
        let color = CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)

        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = local
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.lineWidth = 3
        ring.strokeColor = color
        ring.fillColor = color.copy(alpha: 0.22)
        if isRight { ring.lineDashPattern = [5, 3] }
        // Thin dark edge keeps light colors visible on white backgrounds.
        ring.shadowColor = CGColor(gray: 0, alpha: 1)
        ring.shadowOpacity = 0.35
        ring.shadowRadius = 1.5
        ring.shadowOffset = .zero
        layer.addSublayer(ring)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration: CFTimeInterval = reduceMotion ? 0.35 : 0.5

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        ring.opacity = 0
        ring.add(fade, forKey: "fade")
        if !reduceMotion {
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.35
            grow.toValue = 1
            grow.duration = duration
            grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(grow, forKey: "grow")
        }
        CATransaction.commit()
    }
}
