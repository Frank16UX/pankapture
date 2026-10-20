import AppCore
import AppKit
import Carbon.HIToolbox
import DesignSystem

/// Things a pinned image can ask the app to do.
public enum PinAction: Sendable {
    case copy, save, edit
}

/// Pins captures as always-on-top floating images (PIN-1…PIN-4).
@MainActor
public final class PinController {
    public static let shared = PinController()

    private var windows: [PinnedImageWindow] = []
    /// Set by the app to handle copy/save/edit requests. The UUID is the
    /// history item passed to `pin`, if any.
    public var onAction: ((PinAction, CGImage, CGFloat, UUID?) -> Void)?

    public var hasPins: Bool { !windows.isEmpty }
    public var hasLockedPins: Bool { windows.contains { $0.isLocked } }

    private init() {}

    /// Pins `image` (pixels at `scale`). `screenFrame` is where it was captured,
    /// in AppKit global coordinates, so the pin appears exactly over the original.
    public func pin(_ image: CGImage, scale: CGFloat, at screenFrame: CGRect? = nil, libraryID: UUID? = nil) {
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let frame: CGRect
        if let screenFrame {
            frame = screenFrame
        } else {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            // Fit within 60% of the screen, centered.
            let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
            let fitted = CGSize(width: size.width * fit, height: size.height * fit)
            frame = CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2,
                           width: fitted.width, height: fitted.height)
        }
        let window = PinnedImageWindow(image: image, scale: scale, frame: frame, controller: self)
        window.libraryID = libraryID
        windows.append(window)
        window.orderFrontRegardless()
    }

    /// Makes every click-through pin interactive again.
    public func unlockAll() {
        windows.forEach { $0.isLocked = false }
    }

    public func closeAll() {
        windows.forEach { $0.close() }
        windows.removeAll()
    }

    fileprivate func closed(_ window: PinnedImageWindow) {
        windows.removeAll { $0 === window }
    }
}

/// Borderless, resizable, always-on-top image window.
final class PinnedImageWindow: NSPanel {
    let image: CGImage
    let scale: CGFloat
    var libraryID: UUID?
    private unowned let controller: PinController
    private let imageView: PinnedImageView

    var isLocked = false {
        didSet {
            ignoresMouseEvents = isLocked
            imageView.isLocked = isLocked
        }
    }

    init(image: CGImage, scale: CGFloat, frame: CGRect, controller: PinController) {
        self.image = image
        self.scale = scale
        self.controller = controller
        imageView = PinnedImageView(image: image)
        super.init(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentAspectRatio = CGSize(width: image.width, height: image.height)
        minSize = CGSize(width: 40, height: 40)
        contentView = imageView
        imageView.window_ = self
    }

    override var canBecomeKey: Bool { true }

    var naturalSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    /// Scales around `anchor` (screen coordinates), keeping the aspect ratio.
    func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let current = frame
        var width = current.width * factor
        width = min(max(width, 40), naturalSize.width * 4)
        let height = width * current.height / current.width
        let fx = (anchor.x - current.minX) / current.width
        let fy = (anchor.y - current.minY) / current.height
        let newFrame = CGRect(x: anchor.x - fx * width, y: anchor.y - fy * height, width: width, height: height)
        setFrame(newFrame, display: true)
    }

    func copyImage() { controller.onAction?(.copy, image, scale, libraryID) }
    func saveImage() { controller.onAction?(.save, image, scale, libraryID) }
    func editImage() { controller.onAction?(.edit, image, scale, libraryID) }

    override func close() {
        super.close()
        controller.closed(self)
    }

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape: close()
        case kVK_ANSI_C where command: copyImage()
        case kVK_ANSI_S where command: saveImage()
        case kVK_ANSI_W where command: close()
        case kVK_ANSI_0 where command: setFrame(CGRect(origin: frame.origin, size: naturalSize), display: true)
        default:
            // 1…9 set opacity 10%…90%, 0 = 100%.
            if let digit = Int(event.charactersIgnoringModifiers ?? ""), !command {
                alphaValue = digit == 0 ? 1 : CGFloat(digit) / 10
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

/// Draws the image, shows a close button on hover, and handles gestures.
final class PinnedImageView: NSView {
    weak var window_: PinnedImageWindow?
    private let closeButton: NSButton
    var isLocked = false

    init(image: CGImage) {
        closeButton = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
                               target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.cornerRadius = PK.Radius.control
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = PK.Metrics.hairline
        layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor

        closeButton.isBordered = false
        closeButton.symbolConfiguration = .init(pointSize: 18, weight: .semibold).applying(.init(paletteColors: [.white, .black.withAlphaComponent(0.55)]))
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.toolTip = "Close (Esc)"
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        closeButton.frame = CGRect(x: 6, y: bounds.height - 30, width: 24, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 {
            window_?.editImage()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let window = window_ else { return }
        if event.modifierFlags.contains(.option) {
            // ⌥ + scroll adjusts opacity.
            window.alphaValue = min(1, max(0.1, window.alphaValue + event.scrollingDeltaY * 0.01))
        } else {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.005 : event.scrollingDeltaY * 0.05
            window.zoom(by: 1 + delta, around: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        window_?.zoom(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Edit…", action: #selector(editImage), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for percent in [100, 80, 60, 40, 20] {
            let item = NSMenuItem(title: "\(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = percent
            item.state = Int(((window_?.alphaValue ?? 1) * 100).rounded()) == percent ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0").target = self
        let lock = menu.addItem(withTitle: "Click Through", action: #selector(lock), keyEquivalent: "")
        lock.target = self
        lock.toolTip = "Clicks pass through to the windows underneath. Unlock from the menu bar."
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeWindow), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() { window_?.copyImage() }
    @objc private func saveImage() { window_?.saveImage() }
    @objc private func editImage() { window_?.editImage() }
    @objc private func closeWindow() { window_?.close() }
    @objc private func lock() { window_?.isLocked = true }
    @objc private func actualSize() {
        guard let window = window_ else { return }
        window.setFrame(CGRect(origin: window.frame.origin, size: window.naturalSize), display: true)
    }
    @objc private func setOpacity(_ sender: NSMenuItem) { window_?.alphaValue = CGFloat(sender.tag) / 100 }
}
