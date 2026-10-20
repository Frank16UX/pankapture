import AppCore
import AppKit
import AVFoundation
import QuartzCore

/// Floating webcam bubble (REC-10). On screen it's a live preview; the
/// recording gets the camera as its own track (ADR-25) through
/// `RecordingCameraSource`, so the editor can move, resize, or hide it.
///
/// Drag to move; drag the bottom-right corner or ⌘-scroll to resize;
/// right-click for shape, mirror, and camera.
@MainActor
public final class WebcamBubble {
    public struct Appearance: Equatable, Sendable {
        public var shape: RecordingOptions.CameraShape
        public var isMirrored: Bool
        /// Width in points (height follows the shape's aspect ratio).
        public var size: Double
        public var deviceID: String?

        public init(shape: RecordingOptions.CameraShape = .circle, isMirrored: Bool = true, size: Double = 200, deviceID: String? = nil) {
            self.shape = shape
            self.isMirrored = isMirrored
            self.size = size
            self.deviceID = deviceID
        }

        init(_ options: RecordingOptions) {
            self.init(shape: options.cameraShape, isMirrored: options.cameraMirrored, size: options.cameraSize, deviceID: options.cameraDeviceID)
        }
    }

    /// Called when the user changes the bubble directly (resize, context menu),
    /// so the options/preferences can follow.
    public var onAppearanceChange: ((Appearance) -> Void)?
    /// "Turn Off Camera" in the bubble's menu; offered when set and
    /// `canTurnOff` agrees (not while recording).
    public var onTurnOff: (() -> Void)?
    public var canTurnOff: () -> Bool = { true }

    public private(set) var appearance: Appearance
    private var panel: OverlayPanel?
    private var bubbleView: BubbleView?
    private var session: AVCaptureSession?
    private var sessionHandle: CaptureSessionHandle?
    private var currentDeviceID: String?
    private var currentDevice: AVCaptureDevice?
    private var frameOutput: AVCaptureVideoDataOutput?
    private var frameDelegate: CameraFrameDelegate?
    private var deliveryQueue: DispatchSerialQueue?

    public init(appearance: Appearance = Appearance()) {
        self.appearance = appearance
    }

    public var isVisible: Bool { panel != nil }
    public var windowID: CGWindowID? { panel?.windowID }

    /// Shows the bubble (bottom-left of `screen` the first time). Requests
    /// camera permission if needed; returns `false` if it isn't granted.
    @discardableResult
    public func show(on screen: NSScreen? = nil) async -> Bool {
        var status = Permissions.status(.camera)
        if status == .notDetermined { status = await Permissions.request(.camera) }
        guard status == .granted else {
            Log.recording.notice("Camera permission not granted; webcam bubble hidden")
            return false
        }
        if panel == nil { makePanel(on: screen ?? ScreenGeometry.screenUnderMouse) }
        startSession()
        panel?.orderFrontRegardless()
        return true
    }

    /// Moves the bubble to the bottom-left of `frame` (AppKit global) unless
    /// it's already fully inside, so it lands in the recorded region.
    public func keepInside(_ frame: CGRect) {
        guard let panel, !frame.contains(panel.frame) else { return }
        let inset: CGFloat = 24
        let size = panel.frame.size
        let origin = CGPoint(
            x: min(frame.minX + inset, frame.maxX - size.width),
            y: min(frame.minY + inset, frame.maxY - size.height)
        )
        panel.setFrameOrigin(origin)
    }

    public func hide() {
        stopDeliveringFrames()
        sessionHandle?.stopRunning()
        sessionHandle = nil
        session = nil
        frameOutput = nil
        currentDeviceID = nil
        panel?.orderOut(nil)
        panel = nil
        bubbleView = nil
    }

    public func update(_ appearance: Appearance) {
        let old = self.appearance
        self.appearance = appearance
        guard panel != nil else { return }
        if old.size != appearance.size || old.shape != appearance.shape { applySize(keepingCenter: true) }
        bubbleView?.apply(appearance)
        if old.deviceID != appearance.deviceID { startSession() }
    }

    // MARK: Panel

    private func makePanel(on screen: NSScreen?) {
        let size = Self.bubbleSize(for: appearance)
        let visible = screen?.visibleFrame ?? .zero
        let origin = NSPoint(x: visible.minX + 40, y: visible.minY + 40)
        let panel = OverlayPanel(contentRect: NSRect(origin: origin, size: size), level: .recordingOverlay, clickThrough: false)
        panel.hasShadow = true

        let view = BubbleView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        view.apply(appearance)
        view.onResize = { [weak self] width in self?.resize(to: width) }
        view.menuProvider = { [weak self] in self?.contextMenu() }
        panel.contentView = view
        self.panel = panel
        bubbleView = view
    }

    static func bubbleSize(for appearance: Appearance) -> NSSize {
        let width = appearance.size.clamped(to: RecordingOptions.cameraSizeRange)
        let height = (width * appearance.shape.heightRatio).rounded()
        return NSSize(width: width, height: height)
    }

    private func resize(to width: Double) {
        appearance.size = width.clamped(to: RecordingOptions.cameraSizeRange)
        applySize(keepingCenter: false)
        onAppearanceChange?(appearance)
    }

    private func applySize(keepingCenter: Bool) {
        guard let panel else { return }
        let size = Self.bubbleSize(for: appearance)
        var frame = panel.frame
        if keepingCenter {
            frame.origin.x = frame.midX - size.width / 2
            frame.origin.y = frame.midY - size.height / 2
        } else {
            // Corner drag: keep the top-left corner fixed.
            frame.origin.y = frame.maxY - size.height
        }
        frame.size = size
        panel.setFrame(frame, display: true)
        bubbleView?.apply(appearance)
        panel.invalidateShadow()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        for shape in RecordingOptions.CameraShape.allCases {
            let item = MenuActionItem(title: shape.title) { [weak self] in self?.change { $0.shape = shape } }
            item.state = appearance.shape == shape ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let mirror = MenuActionItem(title: "Mirror") { [weak self] in self?.change { $0.isMirrored.toggle() } }
        mirror.state = appearance.isMirrored ? .on : .off
        menu.addItem(mirror)
        menu.addItem(.separator())
        let cameras = CameraDevices.available()
        let selected = appearance.deviceID ?? CameraDevices.systemDefault?.id
        for camera in cameras {
            let item = MenuActionItem(title: camera.name) { [weak self] in self?.change { $0.deviceID = camera.id } }
            item.state = camera.id == selected ? .on : .off
            menu.addItem(item)
        }
        if let onTurnOff, canTurnOff() {
            menu.addItem(.separator())
            menu.addItem(MenuActionItem(title: "Turn Off Camera") { onTurnOff() })
        }
        return menu
    }

    private func change(_ body: (inout Appearance) -> Void) {
        var next = appearance
        body(&next)
        update(next)
        onAppearanceChange?(next)
    }

    // MARK: Capture

    private func startSession() {
        let wanted = appearance.deviceID
        if session != nil, currentDeviceID == wanted { return }
        sessionHandle?.stopRunning()

        guard let device = wanted.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            Log.recording.error("No camera available for the webcam bubble")
            return
        }
        let wasDelivering = frameDelegate
        frameOutput?.setSampleBufferDelegate(nil, queue: nil)
        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        if session.canAddInput(input) { session.addInput(input) }
        // The recording's frame output is part of the session from the start:
        // adding it when recording begins reconfigures the running camera,
        // which blanks the bubble and drops about the first second of frames.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        if session.canAddOutput(output) {
            session.addOutput(output)
            // The track is never mirrored; the editor mirrors on request.
            if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            frameOutput = output
        } else {
            Log.recording.error("Camera frames can't be recorded: output rejected")
            frameOutput = nil
        }
        session.commitConfiguration()
        if let wasDelivering, let frameOutput, let queue = deliveryQueue {
            let delegate = wasDelivering.rebound(to: session.synchronizationClock)
            frameOutput.setSampleBufferDelegate(delegate, queue: queue)
            frameDelegate = delegate
        }

        bubbleView?.attach(session: session, appearance: appearance)
        let handle = CaptureSessionHandle(session: session)
        handle.startRunning()
        self.session = session
        sessionHandle = handle
        currentDeviceID = wanted
        currentDevice = device
    }
}

// MARK: - Recording the camera as a track

/// Supplies camera frames to the recording writer (ADR-25).
@MainActor
public protocol RecordingCameraSource: AnyObject {
    /// Pixel size of the frames `startDeliveringFrames` will send, or `nil`
    /// if no camera is running.
    var frameSize: CGSize? { get }
    /// Sends every camera frame, with host-clock timestamps, to `handler` on
    /// `queue`. Returns `false` if the camera isn't running.
    func startDeliveringFrames(on queue: DispatchSerialQueue, _ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> Bool
    func stopDeliveringFrames()
    /// The bubble's place relative to `recordedFrame` (AppKit global).
    func layout(in recordedFrame: CGRect) -> RecordingSidecar.Camera?
}

extension WebcamBubble: RecordingCameraSource {
    public var frameSize: CGSize? {
        guard session != nil, let device = currentDevice else { return nil }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    }

    public func startDeliveringFrames(on queue: DispatchSerialQueue, _ handler: @escaping @Sendable (CMSampleBuffer) -> Void) -> Bool {
        guard let session, let frameOutput else { return false }
        guard frameDelegate == nil else { return true }
        // Only the delegate changes: the session keeps running untouched.
        let delegate = CameraFrameDelegate(clock: session.synchronizationClock, handler: handler)
        frameOutput.setSampleBufferDelegate(delegate, queue: queue)
        frameDelegate = delegate
        deliveryQueue = queue
        return true
    }

    public func stopDeliveringFrames() {
        frameOutput?.setSampleBufferDelegate(nil, queue: nil)
        frameDelegate = nil
        deliveryQueue = nil
    }

    public func layout(in recordedFrame: CGRect) -> RecordingSidecar.Camera? {
        guard let panel, recordedFrame.width > 0, recordedFrame.height > 0 else { return nil }
        let frame = panel.frame // AppKit global, bottom-left origin
        return RecordingSidecar.Camera(
            center: CGPoint(
                x: (frame.midX - recordedFrame.minX) / recordedFrame.width,
                y: (recordedFrame.maxY - frame.midY) / recordedFrame.height
            ),
            size: frame.width / min(recordedFrame.width, recordedFrame.height),
            isCircle: appearance.shape == .circle,
            shape: appearance.shape.rawValue,
            isMirrored: appearance.isMirrored
        )
    }
}

/// Forwards camera frames, converted to the host clock (the screen samples'
/// clock), to the recording writer.
///
/// `@unchecked Sendable`: immutable after `init`; `CMClock` is a thread-safe
/// CF type, and AVFoundation calls the delegate on the writer's serial queue.
private final class CameraFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let clock: CMClock?
    private let handler: @Sendable (CMSampleBuffer) -> Void

    init(clock: CMClock?, handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.clock = clock
        self.handler = handler
    }

    /// The same handler on a new session's clock (the camera was switched mid-recording).
    func rebound(to clock: CMClock?) -> CameraFrameDelegate {
        CameraFrameDelegate(clock: clock, handler: handler)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = CMClockGetHostTimeClock()
        guard let clock, !CFEqual(clock, host) else { return handler(sampleBuffer) }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostTime = CMSyncConvertTime(time, from: clock, to: host)
        guard hostTime.isValid, let converted = AudioBuffers.retimed(sampleBuffer, by: time - hostTime) else { return }
        handler(converted)
    }
}

/// Layer-backed bubble: camera preview clipped to a circle or rounded rect.
private final class BubbleView: NSView {
    var onResize: (Double) -> Void = { _ in }
    var menuProvider: () -> NSMenu? = { nil }

    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let ringLayer = CAShapeLayer()
    private var shape: RecordingOptions.CameraShape = .circle
    private var resizeStart: (mouse: NSPoint, width: CGFloat)?
    private static let resizeHandle: CGFloat = 22

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        // Content, not chrome: a neutral backdrop while the camera warms up.
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        ringLayer.lineWidth = 1.5
        layer?.addSublayer(ringLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Moving is done explicitly (`performDrag`) so the corner can resize instead.
    override var mouseDownCanMoveWindow: Bool { false }

    func attach(session: AVCaptureSession, appearance: WebcamBubble.Appearance) {
        previewLayer.session = session
        apply(appearance)
    }

    func apply(_ appearance: WebcamBubble.Appearance) {
        shape = appearance.shape
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = appearance.isMirrored
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Square and rectangle match the editor's default roundness.
        let radius = min(bounds.width, bounds.height) * (shape == .circle ? 0.5 : 0.18)
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        previewLayer.frame = bounds
        ringLayer.frame = bounds
        ringLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
            cornerWidth: max(radius - 0.75, 0), cornerHeight: max(radius - 0.75, 0), transform: nil
        )
        CATransaction.commit()
        window?.invalidateShadow()
    }

    // Bottom-right corner resizes; everywhere else drags the window.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if point.x > bounds.maxX - Self.resizeHandle, point.y < bounds.minY + Self.resizeHandle {
            resizeStart = (NSEvent.mouseLocation, bounds.width)
        } else {
            resizeStart = nil
            window?.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = resizeStart else { return }
        let mouse = NSEvent.mouseLocation
        let delta = max(mouse.x - start.mouse.x, start.mouse.y - mouse.y)
        onResize(Double(start.width + delta))
    }

    override func mouseUp(with event: NSEvent) { resizeStart = nil }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        onResize(Double(bounds.width + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 8)))
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

    override func resetCursorRects() {
        let corner = NSRect(x: bounds.maxX - Self.resizeHandle, y: bounds.minY, width: Self.resizeHandle, height: Self.resizeHandle)
        addCursorRect(corner, cursor: .crosshair)
    }
}

/// `NSMenuItem` that runs a closure.
final class MenuActionItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
