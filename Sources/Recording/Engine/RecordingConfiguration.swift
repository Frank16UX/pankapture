import CoreGraphics
import Foundation

/// Everything the engine needs to make one recording. Built by the app (usually
/// via `RecordingOptions.makeConfiguration(source:overlayWindowIDs:)`) and also
/// persisted in the in-progress manifest so a crashed recording can be named
/// and placed correctly on recovery.
public struct RecordingConfiguration: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        /// A whole display.
        case display(CGDirectDisplayID)
        /// A single window, followed as it moves (desktop-independent window capture).
        case window(CGWindowID)
        /// A rectangle on one display, in **display-local points, top-left origin**
        /// (the same space as `DisplaySnapshot.crop(toLocalRect:)`).
        case area(displayID: CGDirectDisplayID, rect: CGRect)

        /// The display the source lives on, when it is known up front.
        public var displayID: CGDirectDisplayID? {
            switch self {
            case .display(let id): id
            case .area(let id, _): id
            case .window: nil
            }
        }
    }

    public enum Codec: String, Codable, CaseIterable, Sendable, Identifiable {
        case h264
        case hevc

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .h264: "H.264"
            case .hevc: "HEVC"
            }
        }
    }

    /// Bit-rate presets expressed as bits per pixel per frame, so the same preset
    /// scales from a small area at 30 fps to a 5K display at 60 fps.
    public enum Quality: String, Codable, CaseIterable, Sendable, Identifiable {
        case low
        case medium
        case high

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }

        /// H.264 bits per pixel per frame. Screen content is mostly static, so
        /// these are far below camera-footage rates.
        public var bitsPerPixel: Double {
            switch self {
            case .low: 0.04
            case .medium: 0.08
            case .high: 0.15
            }
        }
    }

    public var source: Source
    /// 30 or 60.
    public var framesPerSecond: Int
    public var codec: Codec
    public var quality: Quality
    public var capturesSystemAudio: Bool
    public var capturesMicrophone: Bool
    /// `AVCaptureDevice.uniqueID` of the microphone; `nil` uses the system default.
    public var microphoneDeviceID: String?
    public var showsCursor: Bool
    public var hidesDesktopIcons: Bool
    /// Seconds of countdown before capture starts (0, 3, or 5).
    public var countdown: Int
    /// Pankapture windows that **must appear** in the recording (webcam bubble,
    /// click rings, keystroke pill) even though every other Pankapture window is
    /// excluded. See ADR-5.
    public var includedOverlayWindowIDs: [CGWindowID]

    public init(
        source: Source,
        framesPerSecond: Int = 60,
        codec: Codec = .h264,
        quality: Quality = .medium,
        capturesSystemAudio: Bool = true,
        capturesMicrophone: Bool = false,
        microphoneDeviceID: String? = nil,
        showsCursor: Bool = true,
        hidesDesktopIcons: Bool = false,
        countdown: Int = 3,
        includedOverlayWindowIDs: [CGWindowID] = []
    ) {
        self.source = source
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.quality = quality
        self.capturesSystemAudio = capturesSystemAudio
        self.capturesMicrophone = capturesMicrophone
        self.microphoneDeviceID = microphoneDeviceID
        self.showsCursor = showsCursor
        self.hidesDesktopIcons = hidesDesktopIcons
        self.countdown = countdown
        self.includedOverlayWindowIDs = includedOverlayWindowIDs
    }

    /// Average video bit rate for a given output size.
    public func videoBitRate(width: Int, height: Int) -> Int {
        Self.videoBitRate(width: width, height: height, fps: framesPerSecond, codec: codec, quality: quality)
    }

    public static func videoBitRate(width: Int, height: Int, fps: Int, codec: Codec, quality: Quality) -> Int {
        // HEVC reaches the same quality at roughly 70% of the H.264 rate.
        let codecFactor = codec == .hevc ? 0.7 : 1.0
        let raw = Double(width * height * max(fps, 1)) * quality.bitsPerPixel * codecFactor
        return max(1_000_000, Int(raw.rounded()))
    }
}

/// What `ScreenRecorder.stop()` produces.
public struct RecordingResult: Equatable, Sendable {
    /// Final MP4 in the user's save folder.
    public var url: URL
    /// Seconds of output timeline (pauses removed).
    public var duration: Double
    /// File size in bytes.
    public var fileSize: Int64
    /// Pixel size of the video frames.
    public var videoSize: CGSize
    /// Number of clicks logged to the sidecar.
    public var clickCount: Int
    public var configuration: RecordingConfiguration

    public init(url: URL, duration: Double, fileSize: Int64, videoSize: CGSize, clickCount: Int, configuration: RecordingConfiguration) {
        self.url = url
        self.duration = duration
        self.fileSize = fileSize
        self.videoSize = videoSize
        self.clickCount = clickCount
        self.configuration = configuration
    }
}

public enum RecordingError: LocalizedError, Equatable, Sendable {
    /// Screen & System Audio Recording isn't granted.
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case displayNotFound(CGDirectDisplayID)
    case windowNotFound(CGWindowID)
    /// The area is empty or entirely off its display.
    case invalidArea
    /// `start` while a recording is already active (or vice versa).
    case invalidState
    /// The user cancelled (countdown Esc, cancel button).
    case cancelled
    /// No complete video frame arrived, so there is nothing to save.
    case noFramesCaptured
    /// The system stopped the stream (display disconnected, permission revoked, …).
    case streamStopped(String)
    case writerFailed(String)
    case recoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied: "Pankapture needs Screen & System Audio Recording permission."
        case .microphonePermissionDenied: "Pankapture needs Microphone permission to record your voice."
        case .displayNotFound: "The display to record is no longer available."
        case .windowNotFound: "The window to record is no longer available."
        case .invalidArea: "The recording area is empty."
        case .invalidState: "A recording is already in progress."
        case .cancelled: "Recording cancelled."
        case .noFramesCaptured: "Nothing was recorded."
        case .streamStopped(let reason): "Recording stopped: \(reason)"
        case .writerFailed(let reason): "Couldn't write the recording: \(reason)"
        case .recoveryFailed(let reason): "Couldn't recover the recording: \(reason)"
        }
    }
}
