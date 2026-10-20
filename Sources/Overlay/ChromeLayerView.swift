import AppKit
import Capture
import DesignSystem
import QuartzCore

/// Selection chrome drawn with Core Animation layers so mouse moves only update
/// paths and positions (no full-screen redraws): dimming, selection border,
/// handles, dimension badge, crosshair guides, and the magnifier loupe.
///
/// Overlay chrome deliberately ignores light/dark appearance: it sits on top of
/// arbitrary screen content and must stay legible everywhere (DESIGN §2).
final class ChromeLayerView: NSView {
    private let dimLayer = CAShapeLayer()
    private let borderShadowLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let badgeLayer = CALayer()
    private let badgeTextLayer = CATextLayer()
    private let loupe = LoupeLayer()

    private(set) var badgeSize = CGSize(width: 80, height: 22)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(scale: CGFloat) {
        guard let root = layer else { return }

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(PK.Overlay.dimOpacity).cgColor

        borderShadowLayer.fillColor = nil
        borderShadowLayer.strokeColor = NSColor.black.withAlphaComponent(0.45).cgColor
        borderShadowLayer.lineWidth = 2

        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.cgColor
        borderLayer.lineWidth = 1

        handlesLayer.fillColor = NSColor.white.cgColor
        handlesLayer.strokeColor = NSColor.black.withAlphaComponent(0.5).cgColor
        handlesLayer.lineWidth = 0.5

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 1
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOpacity = 0.5
        crosshairLayer.shadowRadius = 0.5
        crosshairLayer.shadowOffset = .zero

        badgeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        badgeLayer.cornerRadius = 5
        badgeLayer.cornerCurve = .continuous
        badgeTextLayer.contentsScale = scale
        badgeTextLayer.alignmentMode = .center
        badgeLayer.addSublayer(badgeTextLayer)
        badgeLayer.isHidden = true

        loupe.configure(scale: scale)
        loupe.isHidden = true

        for sublayer in [dimLayer, crosshairLayer, borderShadowLayer, borderLayer, handlesLayer, badgeLayer, loupe] {
            sublayer.actions = Self.noAnimations
            root.addSublayer(sublayer)
        }
    }

    /// Disables implicit animations so chrome tracks the mouse exactly.
    nonisolated static var noAnimations: [String: any CAAction] {
        [
            "position": NSNull(), "bounds": NSNull(), "path": NSNull(), "hidden": NSNull(),
            "contents": NSNull(), "frame": NSNull(), "string": NSNull(), "opacity": NSNull(),
        ]
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Selection

    func update(selection: CGRect?, isHover: Bool, in bounds: CGRect, showsHandles: Bool) {
        withoutAnimation {
            let dim = CGMutablePath()
            dim.addRect(bounds)
            if let selection, selection.width > 0, selection.height > 0 {
                dim.addRect(selection)
            }
            dimLayer.path = dim
            dimLayer.frame = bounds

            guard let selection, selection.width > 0, selection.height > 0 else {
                borderLayer.path = nil
                borderShadowLayer.path = nil
                handlesLayer.path = nil
                badgeLayer.isHidden = true
                return
            }

            let border = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            borderShadowLayer.path = border
            borderLayer.path = border
            borderLayer.lineDashPattern = isHover ? [6, 4] : nil

            if showsHandles {
                let handles = CGMutablePath()
                let size = PK.Overlay.handleSize
                for handle in SelectionHandle.allCases {
                    let p = handle.point(in: selection)
                    handles.addRect(CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                }
                handlesLayer.path = handles
            } else {
                handlesLayer.path = nil
            }

            if isHover {
                badgeLayer.isHidden = true
            } else {
                setBadgeText("\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))")
                badgeLayer.isHidden = false
                if badgeLayer.frame.origin == .zero {
                    placeBadge(at: CGPoint(x: selection.minX, y: max(bounds.minY, selection.minY - badgeSize.height - 4)))
                }
            }
        }
    }

    private func setBadgeText(_ text: String) {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let textSize = attributed.size()
        badgeSize = CGSize(width: ceil(textSize.width) + 14, height: ceil(textSize.height) + 6)
        badgeTextLayer.string = attributed
        badgeLayer.bounds = CGRect(origin: .zero, size: badgeSize)
        badgeTextLayer.frame = CGRect(x: 0, y: 3, width: badgeSize.width, height: ceil(textSize.height))
    }

    func placeBadge(at origin: CGPoint) {
        withoutAnimation {
            badgeLayer.frame = CGRect(origin: origin, size: badgeSize)
        }
    }

    // MARK: Crosshair & loupe

    func setCrosshair(_ point: CGPoint?, in bounds: CGRect) {
        withoutAnimation {
            guard let point else {
                crosshairLayer.path = nil
                return
            }
            let path = CGMutablePath()
            let x = point.x.rounded(.down) + 0.5, y = point.y.rounded(.down) + 0.5
            path.move(to: CGPoint(x: bounds.minX, y: y)); path.addLine(to: CGPoint(x: bounds.maxX, y: y))
            path.move(to: CGPoint(x: x, y: bounds.minY)); path.addLine(to: CGPoint(x: x, y: bounds.maxY))
            crosshairLayer.path = path
        }
    }

    func showLoupe(at point: CGPoint, snapshot: DisplaySnapshot, in bounds: CGRect) {
        withoutAnimation {
            loupe.isHidden = false
            loupe.update(at: point, snapshot: snapshot)
            // Bottom-right of the cursor; flip near the display edges.
            let size = loupe.bounds.size
            var origin = CGPoint(x: point.x + 24, y: point.y + 24)
            if origin.x + size.width > bounds.maxX { origin.x = point.x - 24 - size.width }
            if origin.y + size.height > bounds.maxY { origin.y = point.y - 24 - size.height }
            loupe.frame = CGRect(origin: origin, size: size)
        }
    }

    func hideLoupe() {
        withoutAnimation { loupe.isHidden = true }
    }
}

/// Magnifier with a pixel grid, the center pixel outlined, and its color and
/// coordinates below (SC-2).
final class LoupeLayer: CALayer {
    private static let diameter: CGFloat = 120
    /// Pixels shown across the loupe (odd, so one pixel sits in the center).
    private static let samplePixels = 15

    private let circle = CALayer()
    private let magnified = CALayer()
    private let grid = CAShapeLayer()
    private let centerMarker = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let labelBackground = CALayer()
    private let label = CATextLayer()

    func configure(scale: CGFloat) {
        let d = Self.diameter
        let cell = d / CGFloat(Self.samplePixels)
        bounds = CGRect(x: 0, y: 0, width: d, height: d + 30)
        actions = ChromeLayerView.noAnimations

        circle.frame = CGRect(x: 0, y: 0, width: d, height: d)
        circle.cornerRadius = d / 2
        circle.masksToBounds = true
        circle.backgroundColor = NSColor.black.cgColor

        magnified.frame = circle.bounds
        magnified.magnificationFilter = .nearest
        magnified.contentsGravity = .resize
        magnified.actions = ChromeLayerView.noAnimations

        let gridPath = CGMutablePath()
        for i in 1..<Self.samplePixels {
            let offset = CGFloat(i) * cell
            gridPath.move(to: CGPoint(x: offset, y: 0)); gridPath.addLine(to: CGPoint(x: offset, y: d))
            gridPath.move(to: CGPoint(x: 0, y: offset)); gridPath.addLine(to: CGPoint(x: d, y: offset))
        }
        grid.path = gridPath
        grid.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        grid.lineWidth = 0.5
        grid.frame = circle.bounds

        let center = CGRect(x: (d - cell) / 2, y: (d - cell) / 2, width: cell, height: cell)
        centerMarker.path = CGPath(rect: center, transform: nil)
        centerMarker.fillColor = nil
        centerMarker.strokeColor = NSColor.white.cgColor
        centerMarker.lineWidth = 1.5
        centerMarker.shadowColor = NSColor.black.cgColor
        centerMarker.shadowOpacity = 0.8
        centerMarker.shadowRadius = 1
        centerMarker.shadowOffset = .zero
        centerMarker.frame = circle.bounds

        ring.path = CGPath(ellipseIn: circle.frame.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = 1.5
        ring.shadowColor = NSColor.black.cgColor
        ring.shadowOpacity = 0.4
        ring.shadowRadius = 3
        ring.shadowOffset = .zero

        labelBackground.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        labelBackground.cornerRadius = 5
        labelBackground.cornerCurve = .continuous
        labelBackground.actions = ChromeLayerView.noAnimations
        label.contentsScale = scale
        label.alignmentMode = .center
        label.actions = ChromeLayerView.noAnimations
        labelBackground.addSublayer(label)

        circle.addSublayer(magnified)
        circle.addSublayer(grid)
        circle.addSublayer(centerMarker)
        addSublayer(circle)
        addSublayer(ring)
        addSublayer(labelBackground)
    }

    func update(at point: CGPoint, snapshot: DisplaySnapshot) {
        let image = snapshot.image
        let half = Self.samplePixels / 2
        let px = Int((point.x * snapshot.scale).rounded(.down))
        let py = Int((point.y * snapshot.scale).rounded(.down))
        // Keep the sample inside the image so the grid never stretches at edges.
        let originX = min(max(px - half, 0), image.width - Self.samplePixels)
        let originY = min(max(py - half, 0), image.height - Self.samplePixels)
        let sample = CGRect(x: originX, y: originY, width: Self.samplePixels, height: Self.samplePixels)
        magnified.contents = image.cropping(to: sample)

        let hex = Self.hexColor(in: image, x: px, y: py) ?? "—"
        let text = "\(hex)   \(Int(point.x)), \(Int(point.y))"
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = attributed.size()
        let width = ceil(size.width) + 12
        labelBackground.frame = CGRect(x: (Self.diameter - width) / 2, y: Self.diameter + 6,
                                       width: width, height: ceil(size.height) + 6)
        label.frame = CGRect(x: 0, y: 3, width: width, height: ceil(size.height))
        label.string = attributed
    }

    /// Reads one pixel by drawing it into a 1×1 sRGB bitmap.
    static func hexColor(in image: CGImage, x: Int, y: Int) -> String? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return String(format: "#%02X%02X%02X", data[0], data[1], data[2])
    }
}
