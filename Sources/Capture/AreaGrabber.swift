import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Repeatedly captures one fixed area of a display (scrolling capture).
/// Pankapture's own windows are excluded, so its HUD and frame never appear.
public final class AreaGrabber: @unchecked Sendable {
    // @unchecked: `filter` and `configuration` are set once in init and never
    // mutated; ScreenCaptureKit only reads them.
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    public let scale: CGFloat

    private init(filter: SCContentFilter, configuration: SCStreamConfiguration, scale: CGFloat) {
        self.filter = filter
        self.configuration = configuration
        self.scale = scale
    }

    /// - Parameter rect: display-local points, top-left origin.
    public static func make(displayID: CGDirectDisplayID, rect: CGRect,
                            excludingBundleID bundleID: String? = Bundle.main.bundleIdentifier) async throws -> AreaGrabber {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenshotError.permissionDenied
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenshotError.noDisplays
        }
        let excluded = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int((rect.width * scale).rounded())
        config.height = Int((rect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.displayP3
        return AreaGrabber(filter: filter, configuration: config, scale: scale)
    }

    public func capture() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
