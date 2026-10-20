import CoreGraphics
import Testing
@testable import Recording

@Suite("RecordingGeometry")
struct RecordingGeometryTests {
    @Test func evenRounding() {
        #expect(RecordingGeometry.evenPixels(1919) == 1920)
        #expect(RecordingGeometry.evenPixels(1081) == 1082)
        #expect(RecordingGeometry.evenPixels(1080.4) == 1080)
        #expect(RecordingGeometry.evenPixels(0.5) == 2)
        #expect(RecordingGeometry.evenPixels(-4) == 2)
        #expect(RecordingGeometry.evenPixelsNotExceeding(1081) == 1080)
    }

    @Test func outputSizeScalesPointsToPixels() {
        let size = RecordingGeometry.outputPixelSize(forPointSize: CGSize(width: 1512, height: 982), scale: 2)
        #expect(size.width == 3024 && size.height == 1964)
        let odd = RecordingGeometry.outputPixelSize(forPointSize: CGSize(width: 333.5, height: 101), scale: 1)
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
    }

    @Test func areaOnRetinaDisplayMapsOneToOne() throws {
        let area = try #require(RecordingGeometry.areaCapture(
            rect: CGRect(x: 100, y: 50, width: 640, height: 360),
            displaySize: CGSize(width: 1512, height: 982),
            scale: 2
        ))
        #expect(area.sourceRect == CGRect(x: 100, y: 50, width: 640, height: 360))
        #expect(area.width == 1280 && area.height == 720)
    }

    @Test func oddPixelAreaShrinksToEvenAndStaysOnGrid() throws {
        // 1x display, 301×201 pt → 300×200 px; sourceRect matches exactly.
        let area = try #require(RecordingGeometry.areaCapture(
            rect: CGRect(x: 10.3, y: 20.7, width: 301, height: 201),
            displaySize: CGSize(width: 1920, height: 1080),
            scale: 1
        ))
        #expect(area.width % 2 == 0 && area.height % 2 == 0)
        #expect(area.sourceRect.minX == 10 && area.sourceRect.minY == 20)
        #expect(area.sourceRect.width * 1 == CGFloat(area.width))
        #expect(area.sourceRect.height * 1 == CGFloat(area.height))
        // Never extends past the selection's far edge.
        #expect(area.sourceRect.maxX <= 10.3 + 301)
        #expect(area.sourceRect.maxY <= 20.7 + 201)
    }

    @Test func halfPointSelectionOnRetinaSnapsToPixels() throws {
        let area = try #require(RecordingGeometry.areaCapture(
            rect: CGRect(x: 0.5, y: 0.5, width: 100.5, height: 50.5),
            displaySize: CGSize(width: 1000, height: 1000),
            scale: 2
        ))
        #expect(area.width == 200 && area.height == 100)
        #expect(area.sourceRect == CGRect(x: 0.5, y: 0.5, width: 100, height: 50))
    }

    @Test func areaIsClampedToDisplay() throws {
        let area = try #require(RecordingGeometry.areaCapture(
            rect: CGRect(x: -50, y: 900, width: 400, height: 400),
            displaySize: CGSize(width: 1440, height: 1000),
            scale: 2
        ))
        #expect(area.sourceRect == CGRect(x: 0, y: 900, width: 350, height: 100))
        #expect(area.width == 700 && area.height == 200)
    }

    @Test func emptyOrOffscreenAreaIsRejected() {
        let display = CGSize(width: 1000, height: 800)
        #expect(RecordingGeometry.areaCapture(rect: .zero, displaySize: display, scale: 2) == nil)
        #expect(RecordingGeometry.areaCapture(rect: CGRect(x: 2000, y: 0, width: 100, height: 100), displaySize: display, scale: 2) == nil)
    }

    // MARK: Coordinate flips

    @Test func appKitToQuartzFlipsAroundPrimaryHeight() {
        let quartz = RecordingGeometry.quartzPoint(fromAppKit: CGPoint(x: 100, y: 900), primaryDisplayHeight: 1000)
        #expect(quartz == CGPoint(x: 100, y: 100))
    }

    @Test func rectFlipRoundTrips() {
        let quartz = CGRect(x: 1512, y: -300, width: 1920, height: 1080)
        let appKit = RecordingGeometry.appKitRect(fromQuartz: quartz, primaryDisplayHeight: 982)
        #expect(appKit == CGRect(x: 1512, y: 982 - 780, width: 1920, height: 1080))
        #expect(RecordingGeometry.quartzRect(fromAppKit: appKit, primaryDisplayHeight: 982) == quartz)
    }

    @Test func clickOnPrimaryDisplayNormalizes() throws {
        // Primary 1440×900. AppKit (360, 675) is a quarter in from the left and
        // a quarter down from the top.
        let location = try #require(RecordingGeometry.normalizedLocation(
            ofAppKitPoint: CGPoint(x: 360, y: 675),
            inQuartzFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            primaryDisplayHeight: 900
        ))
        #expect(location == CGPoint(x: 0.25, y: 0.25))
    }

    @Test func clickInAreaOnSecondaryDisplayAboveThePrimary() throws {
        // Secondary display sits above the primary: Quartz origin (0, -1080).
        let secondary = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        // Area at display-local (200, 100), 800×600.
        let areaQuartz = RecordingGeometry.quartzRect(
            fromDisplayLocal: CGRect(x: 200, y: 100, width: 800, height: 600),
            displayBounds: secondary
        )
        #expect(areaQuartz == CGRect(x: 200, y: -980, width: 800, height: 600))

        // Click at the area's center. Quartz (600, -680) → AppKit y = 900 − (−680) = 1580.
        let location = try #require(RecordingGeometry.normalizedLocation(
            ofAppKitPoint: CGPoint(x: 600, y: 1580),
            inQuartzFrame: areaQuartz,
            primaryDisplayHeight: 900
        ))
        #expect(location == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func clickOutsideFrameIsIgnored() {
        let location = RecordingGeometry.normalizedLocation(
            ofQuartzPoint: CGPoint(x: 10, y: 10),
            in: CGRect(x: 100, y: 100, width: 50, height: 50)
        )
        #expect(location == nil)
    }

    @Test func bitRateScalesWithPixelsAndCodec() {
        let h264 = RecordingConfiguration.videoBitRate(width: 1920, height: 1080, fps: 60, codec: .h264, quality: .medium)
        let hevc = RecordingConfiguration.videoBitRate(width: 1920, height: 1080, fps: 60, codec: .hevc, quality: .medium)
        let high = RecordingConfiguration.videoBitRate(width: 1920, height: 1080, fps: 60, codec: .h264, quality: .high)
        #expect(h264 == 9_953_280)
        #expect(hevc < h264 && high > h264)
        #expect(RecordingConfiguration.videoBitRate(width: 100, height: 100, fps: 30, codec: .h264, quality: .low) == 1_000_000)
    }
}
