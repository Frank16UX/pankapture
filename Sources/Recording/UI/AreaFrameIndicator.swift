import AppKit
import DesignSystem
import QuartzCore

/// Thin dashed outline drawn just **outside** an area recording so the user can
/// see what's being captured. Click-through, and a Pankapture window, so it's
/// never in the video (it's outside the captured rect anyway).
@MainActor
public final class AreaFrameIndicator {
    /// Gap between the recorded area and the dashed line.
    private static let gap: CGFloat = 3
    private static let lineWidth: CGFloat = 1.5

    private var panel: OverlayPanel?

    public init() {}

    /// `rect` is display-local points (top-left origin) on `displayID`.
    public func show(area rect: CGRect, on displayID: CGDirectDisplayID) {
        hide()
        let areaAppKit = ScreenGeometry.appKitRect(forArea: rect, on: displayID)
        let inset = Self.gap + Self.lineWidth + 1
        let frame = areaAppKit.insetBy(dx: -inset, dy: -inset)

        let panel = OverlayPanel(contentRect: frame, level: .recordingOverlay, clickThrough: true)
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true

        // Constant colors (white dash over a dark hairline) stay legible over
        // any content, like the selection overlay (DESIGN §2 overlay exception).
        let path = CGPath(
            rect: view.bounds.insetBy(dx: Self.lineWidth / 2 + 0.5, dy: Self.lineWidth / 2 + 0.5),
            transform: nil
        )
        let shadowLine = CAShapeLayer()
        shadowLine.path = path
        shadowLine.fillColor = nil
        shadowLine.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        shadowLine.lineWidth = Self.lineWidth + 1
        let dashLine = CAShapeLayer()
        dashLine.path = path
        dashLine.fillColor = nil
        dashLine.strokeColor = NSColor(PK.Overlay.selectionStroke).cgColor
        dashLine.lineWidth = Self.lineWidth
        dashLine.lineDashPattern = [6, 4]
        view.layer?.addSublayer(shadowLine)
        view.layer?.addSublayer(dashLine)

        panel.contentView = view
        panel.orderFrontRegardless()
        self.panel = panel
    }

    public func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}
