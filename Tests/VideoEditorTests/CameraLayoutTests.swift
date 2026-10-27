import AppCore
import CoreImage
import Foundation
import Testing
@testable import VideoEditor

/// Camera Only and Screen Only stretches (PRD CAM-6).
@Suite("Camera layouts")
struct CameraLayoutTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private func pixels(_ image: CIImage, size: CGSize) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4,
                       bounds: CGRect(origin: .zero, size: size), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return { x, y in
            let i = (y * width + x) * 4
            return (data[i], data[i + 1], data[i + 2], data[i + 3])
        }
    }

    private func solid(_ color: CIColor, _ size: CGSize) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func project(_ layouts: [CameraLayoutSegment] = [], isVisible: Bool = true) -> VideoEditProject {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 20)
        project.camera = CameraOverlay(isVisible: isVisible, center: CGPoint(x: 0.15, y: 0.7), size: 0.4,
                                       shape: .roundedRectangle, isMirrored: false)
        project.cameraLayouts = layouts
        return project
    }

    // MARK: State over time

    @Test func cameraEasesIntoAndOutOfTheFullFrame() {
        let segments = [CameraLayoutSegment(range: TimeRange(start: 2, end: 6), layout: .fullFrame)]
        func state(_ time: Double) -> CameraLayoutState {
            CameraLayoutMath.state(at: time, segments: segments, isVisible: true)
        }
        #expect(state(1) == .usual)
        #expect(state(4) == CameraLayoutState(fullness: 1, visibility: 1))
        let entering = state(2 + CameraLayoutSegment.transition / 2)
        #expect(entering.fullness > 0.1 && entering.fullness < 0.9 && entering.visibility == 1)
        let leaving = state(6 - CameraLayoutSegment.transition / 2)
        #expect(leaving.fullness > 0.1 && leaving.fullness < 0.9)
        #expect(state(7) == .usual)
    }

    @Test func screenOnlyFadesTheCameraOut() {
        let segments = [CameraLayoutSegment(range: TimeRange(start: 2, end: 6), layout: .hidden)]
        #expect(CameraLayoutMath.state(at: 4, segments: segments, isVisible: true) == .hidden)
        let fading = CameraLayoutMath.state(at: 2.2, segments: segments, isVisible: true)
        #expect(fading.fullness == 0 && fading.visibility > 0 && fading.visibility < 1)
    }

    /// With Show Camera off, Camera Only fades the full-frame camera in
    /// rather than growing it from a bubble that isn't there.
    @Test func hiddenCameraFadesInForCameraOnly() {
        let segments = [CameraLayoutSegment(range: TimeRange(start: 0, end: 5), layout: .fullFrame)]
        #expect(CameraLayoutMath.state(at: 3, segments: segments, isVisible: false) == CameraLayoutState(fullness: 1, visibility: 1))
        let appearing = CameraLayoutMath.state(at: 0.1, segments: segments, isVisible: false)
        #expect(appearing.fullness == 1 && appearing.visibility > 0 && appearing.visibility < 1)
        #expect(CameraLayoutMath.state(at: 8, segments: segments, isVisible: false) == .hidden)
        #expect(CameraLayoutMath.showsCamera(segments: segments, isVisible: false))
        #expect(!CameraLayoutMath.showsCamera(segments: [], isVisible: false))
    }

    // MARK: Editing

    @Test func layoutsAreAddedInFreeSpaceOnly() throws {
        var project = project()
        let firstAdded = project.addCameraLayout(.fullFrame, at: 2)
        let first = try #require(firstAdded)
        #expect(first.range == TimeRange(start: 2, end: 5))
        // Inside a layout: nothing added.
        let inside = project.addCameraLayout(.hidden, at: 3)
        #expect(inside == nil)
        // Before the next one: shortened to fit.
        let secondAdded = project.addCameraLayout(.hidden, at: 0.5)
        let second = try #require(secondAdded)
        #expect(second.range == TimeRange(start: 0.5, end: 2))
        // Near the end: moved back to keep the minimum length.
        let lastAdded = project.addCameraLayout(.hidden, at: 19.9)
        let last = try #require(lastAdded)
        #expect(abs(last.range.start - (20 - CameraLayoutSegment.minimumDuration)) < 1e-9 && last.range.end == 20)
        #expect(project.cameraLayouts.map(\.range.start) == [0.5, 2, 19.5])
    }

    @Test func editsStopAtTheNeighbors() throws {
        var project = project()
        let leftAdded = project.addCameraLayout(.fullFrame, at: 2)
        let left = try #require(leftAdded)   // 2–5
        let rightAdded = project.addCameraLayout(.hidden, at: 8)
        let right = try #require(rightAdded)     // 8–11
        // Edges stop at the neighbor.
        var stretched = left
        stretched.range.end = 9
        project.updateCameraLayout(stretched)
        #expect(project.cameraLayouts.first { $0.id == left.id }?.range == TimeRange(start: 2, end: 8))
        var pulled = right
        pulled.range.start = 5
        project.updateCameraLayout(pulled)
        #expect(project.cameraLayouts.first { $0.id == right.id }?.range == TimeRange(start: 8, end: 11))
        // Never shorter than the minimum.
        var squeezed = left
        squeezed.range = TimeRange(start: 2, end: 2.1)
        project.updateCameraLayout(squeezed)
        #expect(project.cameraLayouts.first { $0.id == left.id }?.range == TimeRange(start: 2, end: 2 + CameraLayoutSegment.minimumDuration))

        // Moving keeps the length and stops at the neighbor.
        var shortened = left
        shortened.range = TimeRange(start: 2, end: 6)
        project.updateCameraLayout(shortened)
        let moving = try #require(project.cameraLayouts.first { $0.id == left.id })
        project.moveCameraLayout(moving, by: 10)
        let moved = try #require(project.cameraLayouts.first { $0.id == left.id })
        #expect(moved.range == TimeRange(start: 4, end: 8))
        project.moveCameraLayout(moved, by: -10)
        #expect(project.cameraLayouts.first { $0.id == left.id }?.range == TimeRange(start: 0, end: 4))
        project.removeCameraLayout(id: right.id)
        #expect(project.cameraLayouts.count == 1)
    }

    @Test func layoutsSurviveSavingAndOldProjectsOpen() throws {
        let saved = project([CameraLayoutSegment(range: TimeRange(start: 1, end: 4), layout: .hidden)])
        let decoded = try JSONDecoder().decode(VideoEditProject.self, from: JSONEncoder().encode(saved))
        #expect(decoded.cameraLayouts == saved.cameraLayouts)

        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json["cameraLayouts"] = nil
        let old = try JSONDecoder().decode(VideoEditProject.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.cameraLayouts.isEmpty)
        #expect(!saved.isUnedited)
    }

    // MARK: Drawing

    @Test func cameraOnlyFillsTheFrame() {
        let plan = RenderPlan(project: project([CameraLayoutSegment(range: TimeRange(start: 2, end: 6), layout: .fullFrame)]),
                              sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true)
        func pixel(at time: Double, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let image = FrameRenderer(plan: plan).render(
                source: solid(CIColor(red: 0, green: 0, blue: 1), plan.sourceSize),
                outputTime: time,
                camera: solid(CIColor(red: 0, green: 1, blue: 0), CGSize(width: 64, height: 48))
            )
            return pixels(image, size: plan.renderSize)(x, y)
        }
        // Before: the bubble (center 30, 70) over the screen.
        #expect(pixel(at: 1, 30, 70) == (0, 255, 0, 255))
        #expect(pixel(at: 1, 150, 30) == (0, 0, 255, 255))
        // Inside: the camera everywhere, corners included.
        #expect(pixel(at: 4, 150, 30) == (0, 255, 0, 255))
        #expect(pixel(at: 4, 1, 1) == (0, 255, 0, 255))
        #expect(pixel(at: 4, 198, 98) == (0, 255, 0, 255))
    }

    @Test func screenOnlyHidesTheCameraAndShowingItDrawsTheLayer() {
        let hidden = project([CameraLayoutSegment(range: TimeRange(start: 2, end: 6), layout: .hidden)])
        let plan = RenderPlan(project: hidden, sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true)
        let image = FrameRenderer(plan: plan).render(
            source: solid(CIColor(red: 0, green: 0, blue: 1), plan.sourceSize),
            outputTime: 4,
            camera: solid(CIColor(red: 0, green: 1, blue: 0), CGSize(width: 64, height: 48))
        )
        #expect(pixels(image, size: plan.renderSize)(30, 70) == (0, 0, 255, 255))

        // Show Camera off: no layer, unless a layout fills the frame with it.
        #expect(RenderPlan(project: project(isVisible: false), sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true).camera == nil)
        let intro = project([CameraLayoutSegment(range: TimeRange(start: 0, end: 3), layout: .fullFrame)], isVisible: false)
        #expect(RenderPlan(project: intro, sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true).camera != nil)
    }
}
