import AppCore
import CoreGraphics
import Foundation
import Observation

/// Observable state behind `RecordingOptionsView`: the persisted options plus
/// device lists, permission status, and the live mic meter.
@MainActor
@Observable
public final class RecordingOptionsModel {
    /// Every change is saved to UserDefaults immediately.
    public var options: RecordingOptions {
        didSet {
            guard options != oldValue else { return }
            options.save(to: defaults)
            onChange?(oldValue, options)
            updateMeter()
        }
    }

    /// Source highlighted in the options UI (not persisted).
    public var selectedSource: RecordingOptions.SourceKind = .area

    /// Windows offered for the Window source.
    public private(set) var windows: [RecordableWindow] = []
    /// Window chosen from the list; nil means click one on screen. Not
    /// persisted: window IDs don't survive the app quitting.
    public var chosenWindowID: CGWindowID?

    public private(set) var microphones: [CaptureDeviceInfo] = []
    public private(set) var cameras: [CaptureDeviceInfo] = []
    public private(set) var microphonePermission: PermissionStatus = .notDetermined
    public private(set) var cameraPermission: PermissionStatus = .notDetermined
    public private(set) var accessibilityPermission: PermissionStatus = .notGranted
    public let levelMonitor = MicrophoneLevelMonitor()

    /// Lets the controller react (e.g. update the webcam bubble). `(old, new)`.
    @ObservationIgnored var onChange: ((RecordingOptions, RecordingOptions) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var meterWanted = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        options = RecordingOptions.load(from: defaults)
    }

    /// Re-reads devices and permission status (call when the options UI appears).
    public func refresh() {
        microphones = MicrophoneDevices.available()
        cameras = CameraDevices.available()
        microphonePermission = Permissions.status(.microphone)
        cameraPermission = Permissions.status(.camera)
        accessibilityPermission = Permissions.status(.accessibility)
        if let id = options.microphoneDeviceID, !microphones.contains(where: { $0.id == id }) {
            options.microphoneDeviceID = nil // unplugged: fall back to the default input
        }
        if let id = options.cameraDeviceID, !cameras.contains(where: { $0.id == id }) {
            options.cameraDeviceID = nil
        }
    }

    /// Re-reads the window list; drops the chosen window if it closed.
    public func refreshWindows() async {
        windows = await RecordableWindows.list()
        if let id = chosenWindowID, !windows.contains(where: { $0.id == id }) {
            chosenWindowID = nil
        }
    }

    /// Runs the mic meter while the options UI is visible and the mic is on.
    public func setMeterActive(_ active: Bool) {
        meterWanted = active
        updateMeter()
    }

    /// Asks for microphone access (only when the user turns the mic on).
    public func requestMicrophoneAccess() async {
        microphonePermission = await Permissions.request(.microphone)
        updateMeter()
    }

    public func requestCameraAccess() async {
        cameraPermission = await Permissions.request(.camera)
    }

    /// Shows the system Accessibility prompt (only when keystrokes are turned on).
    public func requestAccessibilityAccess() async {
        accessibilityPermission = await Permissions.request(.accessibility)
    }

    private func updateMeter() {
        if meterWanted, options.capturesMicrophone, microphonePermission == .granted {
            levelMonitor.start(deviceID: options.microphoneDeviceID)
        } else {
            levelMonitor.stop()
        }
    }
}
