import AppCore
import AVFoundation
import Observation
import Synchronization

/// A selectable capture device (microphone or camera).
public struct CaptureDeviceInfo: Identifiable, Hashable, Sendable {
    /// `AVCaptureDevice.uniqueID` (also what ScreenCaptureKit's `microphoneCaptureDeviceID` expects).
    public let id: String
    public let name: String

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
    }
}

/// Audio input devices (REC-3).
@MainActor
public enum MicrophoneDevices {
    public static func available() -> [CaptureDeviceInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map(CaptureDeviceInfo.init)
    }

    public static var systemDefault: CaptureDeviceInfo? {
        AVCaptureDevice.default(for: .audio).map(CaptureDeviceInfo.init)
    }
}

/// Video input devices for the webcam bubble (REC-10).
@MainActor
public enum CameraDevices {
    public static func available() -> [CaptureDeviceInfo] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.map(CaptureDeviceInfo.init)
    }

    public static var systemDefault: CaptureDeviceInfo? {
        AVCaptureDevice.default(for: .video).map(CaptureDeviceInfo.init)
    }
}

/// Starts/stops an `AVCaptureSession` off the main thread (it blocks).
///
/// `@unchecked Sendable`: an immutable wrapper. `AVCaptureSession`'s
/// `startRunning`/`stopRunning` are documented as thread-safe and Apple
/// recommends calling them on a background queue; configuration still happens
/// on the main actor before the session is handed over.
struct CaptureSessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
    private static let queue = DispatchQueue(label: "com.franklinperez.Pankapture.recording.capture-session")

    func startRunning() {
        Self.queue.async { session.startRunning() }
    }

    func stopRunning() {
        Self.queue.async { session.stopRunning() }
    }
}

/// Live input level for the pre-record meter (REC-3). Runs only while the
/// options UI is visible with the microphone enabled; stop it before recording
/// starts (ScreenCaptureKit opens the mic itself).
@MainActor
@Observable
public final class MicrophoneLevelMonitor {
    /// Perceptual level, 0…1.
    public private(set) var level: Float = 0
    public private(set) var isRunning = false

    @ObservationIgnored private var handle: CaptureSessionHandle?
    @ObservationIgnored private var delegate: LevelDelegate?
    @ObservationIgnored private var deviceID: String?

    public init() {}

    /// Starts metering `deviceID` (or the default input). Does nothing unless
    /// microphone permission is already granted.
    public func start(deviceID: String?) {
        if isRunning, self.deviceID == deviceID { return }
        stop()
        guard Permissions.status(.microphone) == .granted else { return }
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        let delegate = LevelDelegate { [weak self] value in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                // Fast attack, slower release reads naturally on a meter.
                self.level = value > self.level ? value : max(value, self.level * 0.8)
            }
        }
        output.setSampleBufferDelegate(delegate, queue: delegate.queue)

        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let handle = CaptureSessionHandle(session: session)
        handle.startRunning()
        self.handle = handle
        self.delegate = delegate
        self.deviceID = deviceID
        isRunning = true
    }

    public func stop() {
        handle?.stopRunning()
        handle = nil
        delegate = nil
        isRunning = false
        level = 0
    }
}

/// Computes peak levels on the capture queue and reports ~15 Hz.
private final class LevelDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, Sendable {
    let queue = DispatchQueue(label: "com.franklinperez.Pankapture.recording.level-meter")
    private let report: @Sendable (Float) -> Void
    private let lastReport = Mutex<CMTime>(.negativeInfinity)

    init(report: @escaping @Sendable (Float) -> Void) {
        self.report = report
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let due = lastReport.withLock { last -> Bool in
            guard time - last >= CMTime(value: 1, timescale: 15) else { return false }
            last = time
            return true
        }
        guard due else { return }
        report(AudioBuffers.meterValue(forPeak: AudioBuffers.peakLevel(of: sampleBuffer)))
    }
}
