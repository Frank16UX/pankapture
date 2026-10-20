import AppCore
import CoreGraphics
import Foundation
import Testing
@testable import VideoEditor

private func zoom(_ start: Double, _ end: Double, rect: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), ease: Double = 0.5) -> ZoomSegment {
    ZoomSegment(range: TimeRange(start: start, end: end), rect: rect, easeDuration: ease)
}

private func isInsideFrame(_ rect: CGRect) -> Bool {
    rect.minX >= -1e-9 && rect.minY >= -1e-9 && rect.maxX <= 1 + 1e-9 && rect.maxY <= 1 + 1e-9
}

@Suite("Zoom math")
struct ZoomMathTests {
    @Test func easingIsSymmetricAndBounded() {
        #expect(ZoomMath.ease(0) == 0)
        #expect(ZoomMath.ease(1) == 1)
        #expect(abs(ZoomMath.ease(0.5) - 0.5) < 1e-12)
        for x in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(ZoomMath.ease(x) + ZoomMath.ease(1 - x) - 1) < 1e-9)
        }
        #expect(ZoomMath.ease(-1) == 0)
        #expect(ZoomMath.ease(2) == 1)
    }

    @Test func progressRampsInHoldsAndRampsOut() {
        let segment = zoom(2, 6, ease: 1)
        #expect(ZoomMath.progress(of: segment, at: 1.9) == 0)
        #expect(ZoomMath.progress(of: segment, at: 2) == 0)
        #expect(abs(ZoomMath.progress(of: segment, at: 2.5) - 0.5) < 1e-9)
        #expect(ZoomMath.progress(of: segment, at: 3) == 1)
        #expect(ZoomMath.progress(of: segment, at: 4.5) == 1)
        #expect(abs(ZoomMath.progress(of: segment, at: 5.5) - 0.5) < 1e-9)
        #expect(ZoomMath.progress(of: segment, at: 6) == 0)
    }

    @Test func shortSegmentStaysContinuous() {
        let segment = zoom(0, 0.6, ease: 1) // shorter than two eases
        let mid = ZoomMath.progress(of: segment, at: 0.3)
        #expect(abs(mid - 1) < 1e-9)
        #expect(ZoomMath.progress(of: segment, at: 0.01) < 0.01)
    }

    @Test func transformInterpolatesFromFullFrame() {
        let segment = zoom(0, 4, ease: 1)
        #expect(ZoomMath.transform(at: -1, zooms: [segment]) == .identity)
        let full = ZoomMath.transform(at: 2, zooms: [segment])
        #expect(full.visibleRect == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(abs(full.scale - 2) < 1e-9)
        let half = ZoomMath.transform(at: 0.5, zooms: [segment])
        #expect(abs(half.visibleRect.width - 0.75) < 1e-9)
        #expect(abs(half.visibleRect.minX - 0.125) < 1e-9)
    }

    @Test func rectIsClampedInsideTheFrame() {
        let clamped = ZoomMath.clampInsideFrame(CGRect(x: 0.8, y: -0.2, width: 0.5, height: 0.4))
        #expect(clamped == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let oversized = ZoomMath.clampInsideFrame(CGRect(x: 0.3, y: 0.3, width: 2, height: 2))
        #expect(oversized == CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(ZoomMath.clampInsideFrame(.null) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func visibleRectAlwaysStaysInsideTheFrame() {
        let edgy = zoom(0, 3, rect: CGRect(x: 0.9, y: 0.9, width: 0.3, height: 0.3), ease: 0.7)
        for t in stride(from: -0.5, through: 3.5, by: 0.05) {
            #expect(isInsideFrame(ZoomMath.transform(at: t, zooms: [edgy]).visibleRect))
        }
    }

    @Test func overlappingZoomsPickTheMostZoomedIn() {
        let a = zoom(0, 4, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), ease: 1)
        let b = zoom(3.5, 8, rect: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5), ease: 1)
        // At 3.6: a eases out (~0.94 → progress of 0.4 ramp), b just started.
        #expect(ZoomMath.transform(at: 3.6, zooms: [a, b]).visibleRect.minX < 0.25)
        #expect(ZoomMath.transform(at: 5, zooms: [a, b]).visibleRect.minX == 0.5)
    }

    @Test func zoomRectFromCenterAndScale() {
        let rect = ZoomSegment.rect(center: CGPoint(x: 0.95, y: 0.05), scale: 2)
        #expect(rect == CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        #expect(ZoomSegment(range: TimeRange(start: 0, end: 1), rect: rect).scale == 2)
    }
}

@Suite("Auto zoom")
struct AutoZoomTests {
    private func click(_ time: Double, _ x: Double, _ y: Double) -> RecordingSidecar.Click {
        RecordingSidecar.Click(time: time, location: CGPoint(x: x, y: y))
    }

    @Test func nearbyClicksFormOneZoom() throws {
        let clicks = [click(5, 0.30, 0.40), click(5.8, 0.34, 0.42), click(6.5, 0.32, 0.38)]
        let zooms = AutoZoomSuggester().suggest(clicks: clicks, sourceDuration: 30)
        #expect(zooms.count == 1)
        let zoom = try #require(zooms.first)
        #expect(zoom.isAutomatic)
        #expect(abs(zoom.range.start - 4.2) < 1e-9)
        #expect(abs(zoom.range.end - 8.1) < 1e-9)
        #expect(abs(zoom.scale - 2) < 1e-9)
        #expect(abs(zoom.center.x - 0.32) < 1e-6)
        #expect(abs(zoom.center.y - 0.40) < 1e-6)
    }

    @Test func clicksFarApartInTimeSplit() {
        let clicks = [click(2, 0.5, 0.5), click(10, 0.5, 0.5)]
        #expect(AutoZoomSuggester().suggest(clicks: clicks, sourceDuration: 30).count == 2)
    }

    @Test func clicksFarApartInSpaceSplitAndMeetHalfway() {
        let clicks = [click(2, 0.1, 0.1), click(3, 0.9, 0.9)]
        let zooms = AutoZoomSuggester().suggest(clicks: clicks, sourceDuration: 30)
        #expect(zooms.count == 2)
        #expect(zooms[0].range.end == zooms[1].range.start)
        #expect(zooms[0].center.x < 0.5)
        #expect(zooms[1].center.x > 0.5)
    }

    @Test func zoomsAreClampedToTheSourceAndFrame() {
        let clicks = [click(0.1, 0.99, 0.01), click(29.9, 0.01, 0.99)]
        let zooms = AutoZoomSuggester().suggest(clicks: clicks, sourceDuration: 30)
        #expect(zooms.count == 2)
        #expect(zooms[0].range.start == 0)
        #expect(zooms[0].range.duration >= 2)
        #expect(zooms[1].range.end == 30)
        for zoom in zooms {
            #expect(zoom.rect.minX >= 0 && zoom.rect.maxX <= 1 && zoom.rect.minY >= 0 && zoom.rect.maxY <= 1)
        }
    }

    @Test func clicksOutsideTheSourceAreIgnored() {
        #expect(AutoZoomSuggester().suggest(clicks: [click(-1, 0.5, 0.5), click(40, 0.5, 0.5)], sourceDuration: 30).isEmpty)
        #expect(AutoZoomSuggester().suggest(clicks: [click(1, 0.5, 0.5)], sourceDuration: 0).isEmpty)
    }

    @Test func applyingSuggestionsKeepsManualZooms() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mp4"), sourceDuration: 30)
        let manual = project.addZoom(at: 4, duration: 3)
        project.applyAutoZooms(AutoZoomSuggester().suggest(clicks: [click(5, 0.5, 0.5), click(15, 0.5, 0.5)], sourceDuration: 30))
        #expect(project.zooms.count == 2)
        #expect(project.zooms.contains(manual))
        // Re-running replaces automatic zooms instead of stacking them.
        project.applyAutoZooms(AutoZoomSuggester().suggest(clicks: [click(20, 0.5, 0.5)], sourceDuration: 30))
        #expect(project.zooms.count == 2)
        #expect(project.zooms.filter(\.isAutomatic).first?.range.contains(20) == true)
    }
}
