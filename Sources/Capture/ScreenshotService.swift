import AppCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A frozen, full-resolution image of one display, taken the instant a capture
/// is triggered. The selection overlay draws this image and the final capture is
/// a crop of it, so what you select is exactly what you get (no second capture,
/// no race with content changing underneath the overlay).
public struct DisplaySnapshot: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    /// Display frame in global Quartz coordinates (points, top-left origin).
    public let frame: CGRect
    /// Pixels per point for this display (2.0 on Retina).
    public let scale: CGFloat
    public let image: CGImage

    /// Crops a rectangle given in this display's local point space.
    public func crop(toLocalRect rect: CGRect) -> CGImage? {
        let pixelRect = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        return image.cropping(to: pixelRect)
    }
}

public enum ScreenshotError: Error, Sendable {
    case permissionDenied
    case noDisplays
    case windowNotFound
}

public enum ScreenshotService {
    /// Snapshots every connected display, excluding Pankapture's own windows
    /// (toolbars, thumbnails, pinned images) so they never leak into captures.
    public static func snapshotDisplays(
        excludingBundleID bundleID: String? = Bundle.main.bundleIdentifier,
        showsCursor: Bool = false,
        hidesDesktopIcons: Bool = false
    ) async throws -> [DisplaySnapshot] {
        let start = ContinuousClock.now

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.capture.error("Shareable content unavailable: \(error.localizedDescription, privacy: .public)")
            throw ScreenshotError.permissionDenied
        }
        guard !content.displays.isEmpty else { throw ScreenshotError.noDisplays }

        let excludedApps = content.applications.filter { $0.bundleIdentifier == bundleID }
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let excludedWindows = hidesDesktopIcons
            ? content.windows.filter { $0.windowLayer == desktopIconLevel && $0.owningApplication?.bundleIdentifier == "com.apple.finder" }
            : []

        var snapshots: [DisplaySnapshot] = []
        for display in content.displays {
            let filter: SCContentFilter
            if excludedWindows.isEmpty {
                filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
            } else {
                let ownWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID }
                filter = SCContentFilter(display: display, excludingWindows: ownWindows + excludedWindows)
            }
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = showsCursor
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.displayP3

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            snapshots.append(DisplaySnapshot(
                displayID: display.displayID,
                frame: display.frame,
                scale: scale,
                image: image
            ))
        }

        let elapsed = ContinuousClock.now - start
        Log.capture.debug("Snapshotted \(snapshots.count) display(s) in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)")
        return snapshots
    }

    /// Captures a single window by itself, with transparent corners and
    /// (optionally) its shadow, independent of what's in front of it (SC-6).
    /// Returns the image and its pixels-per-point scale.
    public static func captureWindow(
        id windowID: CGWindowID,
        includeShadow: Bool,
        showsCursor: Bool = false
    ) async throws -> (image: CGImage, scale: CGFloat) {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenshotError.permissionDenied
        }
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenshotError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = !includeShadow
        config.shouldBeOpaque = false
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.colorSpaceName = CGColorSpace.displayP3
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }
}
