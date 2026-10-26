import CoreImage
import Foundation
import Testing
@testable import VideoEditor

/// Camera backgrounds (PRD CAM-1–CAM-3): the model, the key, and the layer.
@Suite("Camera background")
struct CameraBackgroundTests {
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private static let screenGreen = RGBAColor(red: 0.1, green: 0.75, blue: 0.25)

    private func pixels(_ image: CIImage, size: CGSize) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &data, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return { x, y in
            let i = (y * width + x) * 4
            return (data[i], data[i + 1], data[i + 2])
        }
    }

    private func solid(_ color: RGBAColor, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue)).cropped(to: rect)
    }

    /// A 64×48 camera frame: the screen color on the left, red on the right.
    private func halfScreenFrame() -> CIImage {
        solid(RGBAColor(red: 1, green: 0, blue: 0), CGRect(x: 32, y: 0, width: 32, height: 48))
            .composited(over: solid(Self.screenGreen, CGRect(x: 0, y: 0, width: 32, height: 48)))
    }

    private func close(_ pixel: (r: UInt8, g: UInt8, b: UInt8), _ expected: (Int, Int, Int), within tolerance: Int = 12) -> Bool {
        abs(Int(pixel.r) - expected.0) <= tolerance && abs(Int(pixel.g) - expected.1) <= tolerance && abs(Int(pixel.b) - expected.2) <= tolerance
    }

    // MARK: Model

    @Test func oldProjectsOpenWithNoBackground() throws {
        let json = #"{"isVisible":true,"center":[0.5,0.5],"size":0.3,"shape":"circle","isMirrored":true}"#
        let camera = try JSONDecoder().decode(CameraOverlay.self, from: Data(json.utf8))
        #expect(camera.background == CameraBackground())
        #expect(!camera.background.isActive)
        let partial = try JSONDecoder().decode(CameraBackground.self, from: Data(#"{"effect":"blur"}"#.utf8))
        #expect(partial.effect == .blur && partial.blurAmount == 0.5)
    }

    @Test func blurAlwaysFindsThePersonAndRemoveCanDropTheShape() {
        var background = CameraBackground(effect: .blur, matte: .greenScreen)
        #expect(background.effectiveMatte == .person)
        background.effect = .replace
        #expect(background.effectiveMatte == .greenScreen)
        #expect(background.drawsShape)
        background.effect = .remove
        #expect(!background.drawsShape)
        background.keepsShape = true
        #expect(background.drawsShape)
    }

    @Test func defaultRoundTripsAndSeedsNewProjects() async throws {
        let defaults = try #require(UserDefaults(suiteName: "CameraBackgroundTests-\(UUID().uuidString)"))
        #expect(CameraBackground.savedDefault(in: defaults) == CameraBackground())
        let chosen = CameraBackground(effect: .replace, color: RGBAColor(red: 0, green: 0, blue: 1))
        CameraBackground.saveDefault(chosen, in: defaults)
        #expect(CameraBackground.savedDefault(in: defaults) == chosen)

        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 0.5, cameraColor: (0, 255, 0)), in: directory)
        let source = try await SourceMedia.load(url: movie)
        let project = VideoEditProject.initial(for: source, cameraBackground: chosen)
        #expect(project.camera?.background == chosen)
    }

    // MARK: Chroma key

    @Test func keyCubeClearsTheScreenAndKeepsEverythingElse() throws {
        let dimension = 5  // channels 0, 0.25, 0.5, 0.75, 1
        func entry(_ data: Data, _ r: Int, _ g: Int, _ b: Int) -> [Float] {
            data.withUnsafeBytes { raw in
                let values = raw.bindMemory(to: Float.self)
                let i = ((b * dimension + g) * dimension + r) * 4
                return Array(values[i..<(i + 4)])
            }
        }
        let data = try #require(CameraMatte.cubeData(key: Self.screenGreen, tolerance: 0.4, spill: 0.5, dimension: dimension))
        #expect(entry(data, 0, 4, 0)[3] == 0)    // pure green
        #expect(entry(data, 4, 0, 0)[3] == 1)    // red
        #expect(entry(data, 2, 2, 2)[3] == 1)    // gray
        #expect(entry(data, 0, 0, 0)[3] == 1)    // black

        // Full spill removal brings a greenish highlight back to neutral.
        let strict = try #require(CameraMatte.cubeData(key: Self.screenGreen, tolerance: 0, spill: 1, dimension: dimension))
        let greenish = entry(strict, 3, 4, 3)
        #expect(greenish[3] == 1)
        #expect(abs(greenish[1] - 0.75) < 0.001)

        // A blue screen keys blue, not green; a gray "screen" can't be keyed.
        let blue = try #require(CameraMatte.cubeData(key: RGBAColor(red: 0.1, green: 0.2, blue: 0.9), tolerance: 0.4, spill: 0.5, dimension: dimension))
        #expect(entry(blue, 0, 0, 4)[3] == 0)
        #expect(entry(blue, 0, 4, 0)[3] == 1)
        #expect(CameraMatte.cubeData(key: RGBAColor(red: 0.5, green: 0.5, blue: 0.5), tolerance: 0.4, spill: 0.5, dimension: dimension) == nil)
    }

    /// Half-keyed pixels come out at half strength, not darker.
    @Test func partlyKeyedColorsKeepTheirBrightness() throws {
        // Leans to green 18/40 = 0.45 of its brightness; the key, 0.5/0.75.
        // At tolerance 0 that's halfway between kept and removed.
        let color = RGBAColor(red: 22.0 / 63, green: 40.0 / 63, blue: 22.0 / 63)
        let frame = solid(color, CGRect(x: 0, y: 0, width: 8, height: 8))
        let keyed = try #require(CameraMatte.chromaKeyed(frame, key: Self.screenGreen, tolerance: 0, spill: 0))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame.extent)
        let pixel = pixels(keyed.composited(over: black), size: CGSize(width: 8, height: 8))(4, 4)
        #expect(close(pixel, (Int(22.0 / 63 * 0.5 * 255), Int(40.0 / 63 * 0.5 * 255), Int(22.0 / 63 * 0.5 * 255)), within: 4), "\(pixel)")
    }

    @Test func shadowsOnTheScreenKeyToo() throws {
        let shadow = solid(RGBAColor(red: 0.05, green: 0.3, blue: 0.1), CGRect(x: 0, y: 0, width: 8, height: 8))
        let keyed = try #require(CameraMatte.chromaKeyed(shadow, key: Self.screenGreen, tolerance: 0.4, spill: 0.5))
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: shadow.extent)
        #expect(close(pixels(keyed.composited(over: white), size: CGSize(width: 8, height: 8))(4, 4), (255, 255, 255), within: 6))
        // Near-black stays, whatever its tint.
        let dark = solid(RGBAColor(red: 0, green: 0.03, blue: 0), CGRect(x: 0, y: 0, width: 8, height: 8))
        let kept = try #require(CameraMatte.chromaKeyed(dark, key: Self.screenGreen, tolerance: 0.4, spill: 0))
        #expect(close(pixels(kept.composited(over: white), size: CGSize(width: 8, height: 8))(4, 4), (0, 8, 0), within: 6))
    }

    @Test func grayKeyColorIsFlagged() {
        #expect(CameraBackground(keyColor: Self.screenGreen).keyColorIsUsable)
        #expect(!CameraBackground(keyColor: RGBAColor(red: 0.5, green: 0.52, blue: 0.5)).keyColorIsUsable)
    }

    // MARK: Rendering

    /// Renders a 200×100 frame with the camera layer in the middle (80×60,
    /// no rounding, not mirrored) over `source`.
    private func renderLayer(_ background: CameraBackground, source: RGBAColor) -> (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 10)
        project.camera = CameraOverlay(center: CGPoint(x: 0.5, y: 0.5), size: 0.8, shape: .roundedRectangle, roundness: 0,
                                       isMirrored: false, background: background)
        let plan = RenderPlan(project: project, sourceSize: CGSize(width: 200, height: 100), hasCameraTrack: true)
        let image = FrameRenderer(plan: plan).render(
            source: solid(source, CGRect(origin: .zero, size: plan.sourceSize)),
            outputTime: 0,
            camera: halfScreenFrame()
        )
        return pixels(image, size: plan.renderSize)
    }

    @Test func greenScreenShowsTheReplacementColor() {
        let background = CameraBackground(effect: .replace, color: RGBAColor(red: 0, green: 0, blue: 1), matte: .greenScreen,
                                          keyColor: Self.screenGreen)
        let pixel = renderLayer(background, source: RGBAColor(red: 1, green: 1, blue: 1))
        // The layer spans x 60…140, y 20…80; its left half was the screen.
        #expect(close(pixel(80, 50), (0, 0, 255)), "\(pixel(80, 50))")
        #expect(close(pixel(120, 50), (255, 0, 0)), "\(pixel(120, 50))")
    }

    @Test func removedBackgroundShowsTheScreenRecording() {
        let background = CameraBackground(effect: .remove, matte: .greenScreen, keyColor: Self.screenGreen)
        let pixel = renderLayer(background, source: RGBAColor(red: 1, green: 1, blue: 1))
        #expect(close(pixel(80, 50), (255, 255, 255)), "\(pixel(80, 50))")
        #expect(close(pixel(120, 50), (255, 0, 0)), "\(pixel(120, 50))")
    }

    @Test func noBackgroundLeavesTheCameraAlone() {
        let pixel = renderLayer(CameraBackground(), source: RGBAColor(red: 1, green: 1, blue: 1))
        #expect(close(pixel(80, 50), (26, 191, 64)), "\(pixel(80, 50))")
    }

    @Test func replacementPictureFillsTheFrame() throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("backdrop.png")
        let picture = solid(RGBAColor(red: 1, green: 1, blue: 0), CGRect(x: 0, y: 0, width: 30, height: 10))
        try context.writePNGRepresentation(of: picture, to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)

        let filled = try #require(CameraMatte.replacementPicture(at: url, filling: CGRect(x: 0, y: 0, width: 64, height: 48)))
        #expect(filled.extent == CGRect(x: 0, y: 0, width: 64, height: 48))
        let background = CameraBackground(effect: .replace, imageURL: url, matte: .greenScreen, keyColor: Self.screenGreen)
        let pixel = renderLayer(background, source: RGBAColor(red: 0, green: 0, blue: 0))
        #expect(close(pixel(80, 50), (255, 255, 0)), "\(pixel(80, 50))")
    }

    /// Person segmentation runs on any frame; with nobody in it the mask may
    /// be empty, and the layer is still drawn.
    @Test func segmentationReturnsAFullSizeMask() {
        let frame = halfScreenFrame().transformed(by: CGAffineTransform(scaleX: 20, y: 15))
        if let mask = CameraMatte.personMask(for: frame, quality: .fast) {
            #expect(mask.extent == frame.extent)
        }
        let blurred = CameraMatte.apply(CameraBackground(effect: .blur), to: frame, quality: .fast)
        if let blurred { #expect(blurred.extent == frame.extent) }
    }
}
