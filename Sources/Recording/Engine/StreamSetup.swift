import AppCore
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Builds the `SCContentFilter` + `SCStreamConfiguration` for a recording.
struct StreamSetup {
    static let finderBundleID = "com.apple.finder"

    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    /// The area actually captured (display-local points, pixel-snapped), for area sources.
    let sourceRect: CGRect?
    let outputSize: CGSize

    @MainActor
    static func make(for config: RecordingConfiguration) async throws -> StreamSetup {
        let content: SCShareableContent
        do {
            // Desktop windows are included so Finder's desktop-icon windows can be
            // found (and excluded) when hiding desktop icons; off-screen windows so
            // overlay panels that are momentarily hidden still resolve by ID.
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            Log.recording.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
            throw RecordingError.screenRecordingPermissionDenied
        }

        let stream = SCStreamConfiguration()
        stream.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(config.framesPerSecond, 1)))
        stream.queueDepth = 6
        stream.showsCursor = config.showsCursor
        stream.showMouseClicks = false // click rings are our own overlay (REC-11)
        stream.captureResolution = .best
        // 4:2:0 video-range YUV straight from the compositor: what the hardware
        // encoder wants, so IOSurfaces pass through without conversion.
        stream.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        stream.colorSpaceName = CGColorSpace.sRGB
        stream.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2

        stream.capturesAudio = config.capturesSystemAudio
        stream.sampleRate = 48_000
        stream.channelCount = 2
        stream.excludesCurrentProcessAudio = true
        stream.captureMicrophone = config.capturesMicrophone
        stream.microphoneCaptureDeviceID = config.capturesMicrophone ? config.microphoneDeviceID : nil

        switch config.source {
        case .window(let windowID):
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.windowNotFound(windowID)
            }
            if !config.includedOverlayWindowIDs.isEmpty,
               let setup = windowWithOverlays(window, config: config, content: content, stream: stream) {
                return setup
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let size = RecordingGeometry.outputPixelSize(
                forPointSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)
            )
            stream.width = size.width
            stream.height = size.height
            stream.ignoreShadowsSingleWindow = true
            stream.scalesToFit = true
            stream.preservesAspectRatio = true
            return StreamSetup(
                filter: filter, configuration: stream, sourceRect: nil,
                outputSize: CGSize(width: size.width, height: size.height)
            )

        case .display(let displayID):
            let filter = try displayFilter(displayID, config: config, content: content)
            let size = RecordingGeometry.outputPixelSize(
                forPointSize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)
            )
            stream.width = size.width
            stream.height = size.height
            return StreamSetup(
                filter: filter, configuration: stream, sourceRect: nil,
                outputSize: CGSize(width: size.width, height: size.height)
            )

        case .area(let displayID, let rect):
            let filter = try displayFilter(displayID, config: config, content: content)
            guard let area = RecordingGeometry.areaCapture(
                rect: rect, displaySize: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale)
            ) else { throw RecordingError.invalidArea }
            stream.sourceRect = area.sourceRect
            stream.width = area.width
            stream.height = area.height
            return StreamSetup(
                filter: filter, configuration: stream, sourceRect: area.sourceRect,
                outputSize: CGSize(width: area.width, height: area.height)
            )
        }
    }

    /// A single-window filter renders only that window, so the webcam bubble,
    /// click rings, and keystrokes (ADR-5) would be missing. With overlays,
    /// record the window's area of its display instead, showing only the
    /// window and the overlays. The area is fixed at the window's frame when
    /// recording starts. Returns `nil` if the window isn't on a display.
    private static func windowWithOverlays(
        _ window: SCWindow,
        config: RecordingConfiguration,
        content: SCShareableContent,
        stream: SCStreamConfiguration
    ) -> StreamSetup? {
        // SCWindow/SCDisplay frames are Quartz global points.
        let windowFrame = window.frame
        guard let display = content.displays.max(by: {
            area($0.frame.intersection(windowFrame)) < area($1.frame.intersection(windowFrame))
        }), area(display.frame.intersection(windowFrame)) > 0 else { return nil }

        let included = Set(config.includedOverlayWindowIDs)
        let overlays = content.windows.filter { included.contains($0.windowID) }
        let filter = SCContentFilter(display: display, including: [window] + overlays)
        let displayLocal = windowFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        guard let capture = RecordingGeometry.areaCapture(
            rect: displayLocal, displaySize: display.frame.size, scale: CGFloat(filter.pointPixelScale)
        ) else { return nil }
        stream.sourceRect = capture.sourceRect
        stream.width = capture.width
        stream.height = capture.height
        return StreamSetup(
            filter: filter, configuration: stream, sourceRect: capture.sourceRect,
            outputSize: CGSize(width: capture.width, height: capture.height)
        )
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// Re-resolves just the filter (used to keep newly opened Finder windows
    /// visible while desktop icons are hidden).
    @MainActor
    static func refreshedFilter(for config: RecordingConfiguration) async -> SCContentFilter? {
        guard let displayID = config.source.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return nil }
        return try? displayFilter(displayID, config: config, content: content)
    }

    /// Display filter that excludes every Pankapture window except the overlays
    /// that belong in the video (ADR-5), and optionally Finder's desktop icons.
    private static func displayFilter(
        _ displayID: CGDirectDisplayID,
        config: RecordingConfiguration,
        content: SCShareableContent
    ) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw RecordingError.displayNotFound(displayID)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var excludedApps = content.applications.filter { $0.processID == ownPID }
        let included = Set(config.includedOverlayWindowIDs)
        var exceptions = content.windows.filter { included.contains($0.windowID) }

        if config.hidesDesktopIcons {
            // Desktop icons are Finder windows below the normal window level.
            // Excluding Finder and excepting its regular windows hides only the icons.
            excludedApps += content.applications.filter { $0.bundleIdentifier == finderBundleID }
            exceptions += content.windows.filter {
                $0.owningApplication?.bundleIdentifier == finderBundleID && $0.windowLayer >= 0
            }
        }
        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: exceptions)
    }
}

/// Receives ScreenCaptureKit callbacks on the writer's queue and forwards them
/// synchronously into the writer actor (which is isolated to that same queue).
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let writer: RecordingWriter
    let onStop: @Sendable (any Error) -> Void

    init(writer: RecordingWriter, onStop: @escaping @Sendable (any Error) -> Void) {
        self.writer = writer
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let sample = ReadySampleBuffer(sampleBuffer)
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            writer.assumeIsolated { $0.appendVideo(sample.buffer) }
        case .audio:
            writer.assumeIsolated { $0.appendAudio(sample.buffer, from: .system) }
        case .microphone:
            writer.assumeIsolated { $0.appendAudio(sample.buffer, from: .microphone) }
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop(error)
    }

    /// ScreenCaptureKit also sends idle/blank status buffers with no image;
    /// only complete frames carry new pixels.
    static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }
}

/// Carries a ready `CMSampleBuffer` into the writer's isolation domain.
///
/// `@unchecked Sendable`: an immutable wrapper around a CF type. A sample buffer
/// handed to us by ScreenCaptureKit is fully formed (data ready, timing set) and
/// CoreMedia buffers are safe to read from any thread; we never mutate it, we
/// only make retimed copies. (The writer also runs on the very queue that
/// delivered it, so no cross-thread access happens in practice.)
struct ReadySampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
    init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
}
