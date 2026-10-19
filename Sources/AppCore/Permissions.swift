import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// The privacy (TCC) permissions Pankapture depends on.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    /// Required for every capture. Without it ScreenCaptureKit only returns the wallpaper.
    case screenRecording
    /// Voice-over in recordings.
    case microphone
    /// Webcam overlay in recordings.
    case camera
    /// Keystroke display while recording.
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenRecording: "Screen & System Audio Recording"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .accessibility: "Accessibility"
        }
    }

    public var purpose: String {
        switch self {
        case .screenRecording: "Required to take screenshots and record your screen and system audio."
        case .microphone: "Record your voice alongside screen recordings."
        case .camera: "Show your webcam in a bubble while recording."
        case .accessibility: "Display the keys you press while recording."
        }
    }

    public var isRequired: Bool { self == .screenRecording }

    var settingsAnchor: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .camera: "Privacy_Camera"
        case .accessibility: "Privacy_Accessibility"
        }
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    case notGranted
    case notDetermined
}

@MainActor
public enum Permissions {
    public static func status(_ kind: PermissionKind) -> PermissionStatus {
        switch kind {
        case .screenRecording:
            // The preflight can't tell "denied" from "never asked".
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .microphone:
            return status(for: AVCaptureDevice.authorizationStatus(for: .audio))
        case .camera:
            return status(for: AVCaptureDevice.authorizationStatus(for: .video))
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        }
    }

    /// Triggers the system prompt where one exists. Screen Recording and
    /// Accessibility only prompt once; afterwards the user must use System Settings.
    @discardableResult
    public static func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .camera:
            _ = await AVCaptureDevice.requestAccess(for: .video)
        case .accessibility:
            // String literal instead of kAXTrustedCheckOptionPrompt, which is a
            // global `var` and therefore not concurrency-safe under Swift 6.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        let result = status(kind)
        Log.permissions.info("\(kind.rawValue, privacy: .public) → \(String(describing: result), privacy: .public)")
        return result
    }

    public static func openSystemSettings(for kind: PermissionKind) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(kind.settingsAnchor)")!
        NSWorkspace.shared.open(url)
    }

    private static func status(for av: AVAuthorizationStatus) -> PermissionStatus {
        switch av {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .notGranted
        }
    }
}
