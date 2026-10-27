import AppCore
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Synchronization
import Vision

/// Separates the person from the background in camera frames and draws the
/// chosen background behind them (PRD CAM-1, CAM-2, ADR-39).
///
/// Called by the compositor from several queues, out of order while
/// scrubbing, so each frame gets a new Vision request (the model itself is
/// loaded once by Vision). Steadying the mask over time is the compositor's
/// `MatteSmoother`, which knows the order its frames come in. The other
/// state, the chroma cube and the replacement picture, is cached behind
/// `Mutex`es.
public enum CameraMatte {
    /// Segmentation detail: fast in the preview, balanced for exports.
    public enum Quality: Sendable, Equatable {
        case fast
        case balanced
    }

    /// `image` (extent at the origin) with `background` applied, or `nil`
    /// when the person couldn't be found (the frame is then drawn as is).
    /// `smoother` steadies the person's outline against the frame before,
    /// at source `time`.
    static func apply(_ background: CameraBackground, to image: CIImage, quality: Quality,
                      smoother: MatteSmoother? = nil, time: Double = 0) -> CIImage? {
        let extent = image.extent
        guard background.isActive, extent.width >= 2, extent.height >= 2 else { return nil }

        // The person, with transparency where the background was.
        let person: CIImage
        switch background.effectiveMatte {
        case .person:
            guard let mask = personMask(for: image, quality: quality, smoother: smoother, time: time) else { return nil }
            if background.effect == .blur {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = image
                blend.backgroundImage = blurredBackground(image, mask: mask, amount: background.blurAmount)
                blend.maskImage = mask
                return blend.outputImage?.cropped(to: extent)
            }
            let blend = CIFilter.blendWithMask()
            blend.inputImage = image
            blend.backgroundImage = CIImage.empty()
            blend.maskImage = mask
            guard let cut = blend.outputImage else { return nil }
            person = cut.cropped(to: extent)
        case .greenScreen:
            guard let keyed = chromaKeyed(image, key: background.keyColor, tolerance: background.tolerance, spill: background.spill) else {
                return nil
            }
            person = keyed
        }

        switch background.effect {
        case .none, .remove:
            return person
        case .blur:
            return person.composited(over: blurred(image, amount: background.blurAmount))
        case .replace:
            let fill = background.imageURL.flatMap { replacementPicture(at: $0, filling: extent) }
                ?? CIImage(color: CIColor(cgColor: background.color.cgColor)).cropped(to: extent)
            return person.composited(over: fill)
        }
    }

    // MARK: Person segmentation

    /// White where the person is, at `image`'s size.
    ///
    /// Vision's mask is small (256×192 fast, 512×384 balanced). Scaling it up
    /// and blurring it left a wide half-transparent band where the old
    /// background showed through: a halo. Instead it's upsampled guided by
    /// the frame, so its edge follows the person's, then the soft band is
    /// narrowed and only lightly feathered (ADR-39). `smoother` steadies it
    /// against the frame before.
    static func personMask(for image: CIImage, quality: Quality, smoother: MatteSmoother? = nil, time: Double = 0) -> CIImage? {
        guard let mask = coverage(of: image, quality: quality, smoother: smoother, time: time) else { return nil }
        let extent = image.extent
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }

        let upsample = CIFilter.edgePreserveUpsample()
        upsample.inputImage = image
        upsample.smallImage = mask
        guard let upsampled = upsample.outputImage?.cropped(to: extent) else { return nil }
        let sigma = Double(min(extent.width, extent.height)) * 0.0012
        return narrowedEdge(upsampled).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }

    /// Coverage below 25 % becomes none and above 75 % full; a ramp between.
    static func narrowedEdge(_ mask: CIImage) -> CIImage {
        let ramp = CIFilter.colorMatrix()
        ramp.inputImage = mask
        ramp.rVector = CIVector(x: 2, y: 0, z: 0, w: 0)
        ramp.gVector = CIVector(x: 0, y: 2, z: 0, w: 0)
        ramp.bVector = CIVector(x: 0, y: 0, z: 2, w: 0)
        ramp.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        ramp.biasVector = CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = ramp.outputImage
        return clamp.outputImage ?? mask
    }

    /// Vision's mask at its own size (256×192 fast, 512×384 balanced),
    /// steadied against the frame before when there's a `smoother`.
    private static func coverage(of image: CIImage, quality: Quality, smoother: MatteSmoother?, time: Double) -> CIImage? {
        let interval = Log.signposter.beginInterval("cameraMatte", id: Log.signposter.makeSignpostID())
        defer { Log.signposter.endInterval("cameraMatte", interval) }
        if let smoother, let reused = smoother.reusableMask(at: time, luma: { luminance(of: image, width: $0, height: $1) }) {
            return maskImage(reused.mask, width: reused.width, height: reused.height)
        }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality == .fast ? .fast : .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: image, options: [.ciContext: VideoEditCompositor.ciContext])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        // Raw coverage, not a gray picture to color-manage.
        let raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard let smoother, let values = values(of: buffer), let luma = luminance(of: image, width: width, height: height) else { return raw }
        return maskImage(smoother.smooth(values, luma: luma, width: width, height: height, time: time), width: width, height: height)
    }

    /// A one-byte-per-pixel buffer's values, 0…1, top row first.
    static func values(of buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { values[y * width + x] = Float(base[y * rowBytes + x]) / 255 }
        }
        return values
    }

    /// `image`'s luminance shrunk to `width` × `height` (stretched like
    /// Vision's mask), 0…1, top row first.
    static func luminance(of image: CIImage, width: Int, height: Int) -> [Float]? {
        let extent = image.extent
        guard width > 0, height > 0, extent.width > 0, extent.height > 0 else { return nil }
        let scaleY = CGFloat(height) / extent.height
        let shrink = CIFilter.lanczosScaleTransform()
        shrink.inputImage = image.clampedToExtent()
        shrink.scale = Float(scaleY)
        shrink.aspectRatio = Float((CGFloat(width) / extent.width) / scaleY)
        guard let small = shrink.outputImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        VideoEditCompositor.ciContext.render(small, toBitmap: &pixels, rowBytes: width * 4,
                                             bounds: CGRect(x: extent.minX * CGFloat(width) / extent.width, y: extent.minY * scaleY,
                                                            width: CGFloat(width), height: CGFloat(height)),
                                             format: .RGBA8, colorSpace: sRGB)
        var luma = [Float](repeating: 0, count: width * height)
        for index in luma.indices {
            let pixel = index * 4
            luma[index] = (0.2126 * Float(pixels[pixel]) + 0.7152 * Float(pixels[pixel + 1]) + 0.0722 * Float(pixels[pixel + 2])) / 255
        }
        return luma
    }

    /// Coverage values as an image Core Image reads as is (no color management).
    static func maskImage(_ values: [Float], width: Int, height: Int) -> CIImage {
        let bytes = values.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width, size: CGSize(width: width, height: height), format: .L8, colorSpace: nil)
    }

    /// Loads Vision's segmentation model, so the first frame that needs it
    /// doesn't wait for it (about 0.2 s). Call it off the main actor.
    public static func prepare(quality: Quality) {
        let blank = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        _ = personMask(for: blank, quality: quality)
    }

    // MARK: Blur

    static func blurSigma(for extent: CGRect, amount: Double) -> Double {
        Double(min(extent.width, extent.height)) * (0.008 + 0.042 * amount.clamped(to: 0...1))
    }

    static func blurred(_ image: CIImage, amount: Double) -> CIImage {
        image.clampedToExtent().applyingGaussianBlur(sigma: blurSigma(for: image.extent, amount: amount)).cropped(to: image.extent)
    }

    /// The background blurred without the person in it, so their colors don't
    /// smear into it as a dark outline: the background is cut out (alpha
    /// 1 − mask), blurred with its alpha, then divided by that blurred alpha
    /// (unpremultiplied). A little of the whole frame keeps the division
    /// defined where no background is near.
    static func blurredBackground(_ image: CIImage, mask: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let floor: CGFloat = 0.02
        let weight = CIFilter.colorMatrix()
        weight.inputImage = mask
        weight.rVector = CIVector(x: -(1 - floor), y: 0, z: 0, w: 0)
        weight.gVector = CIVector(x: 0, y: -(1 - floor), z: 0, w: 0)
        weight.bVector = CIVector(x: 0, y: 0, z: -(1 - floor), w: 0)
        weight.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        weight.biasVector = CIVector(x: 1, y: 1, z: 1, w: 0)
        let cut = CIFilter.blendWithMask()
        cut.inputImage = image
        cut.backgroundImage = CIImage.empty()
        cut.maskImage = weight.outputImage
        guard let background = cut.outputImage?.cropped(to: extent) else { return blurred(image, amount: amount) }
        return background
            .clampedToExtent()
            .applyingGaussianBlur(sigma: blurSigma(for: extent, amount: amount))
            .cropped(to: extent)
            .applyingFilter("CIUnpremultiply")
            .settingAlphaOne(in: extent)
    }

    // MARK: Chroma key (CAM-2)

    struct CubeKey: Hashable {
        var key: RGBAColor
        var tolerance: Double
        var spill: Double
    }

    static let cubeDimension = 64
    private static let cubes = Mutex<[CubeKey: Data]>([:])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// `image` with the key color made transparent and its tint taken off
    /// what's left; `nil` when the key color is too gray to key on.
    static func chromaKeyed(_ image: CIImage, key: RGBAColor, tolerance: Double, spill: Double) -> CIImage? {
        let cubeKey = CubeKey(key: key, tolerance: tolerance, spill: spill)
        // Built under the lock, so frames rendered at the same time share one build.
        let data = cubes.withLock { cache -> Data? in
            if let cached = cache[cubeKey] { return cached }
            guard let made = cubeData(key: key, tolerance: tolerance, spill: spill, dimension: cubeDimension) else { return nil }
            if cache.count >= 8 { cache.removeAll() }
            cache[cubeKey] = made
            return made
        }
        guard let data else { return nil }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = data
        filter.colorSpace = sRGB
        return filter.outputImage?.cropped(to: image.extent)
    }

    /// How strongly `color` leans toward one channel, relative to its
    /// brightness, and which channel; `nil` for grays.
    static func keyStrength(of color: RGBAColor) -> (channel: Int, strength: Double)? {
        let channels = [color.red, color.green, color.blue]
        let dominant = channels.indices.max { channels[$0] < channels[$1] }!
        let rest = channels.indices.filter { $0 != dominant }.map { channels[$0] }.max()!
        let excess = channels[dominant] - rest
        guard excess > 0.05, channels[dominant] > 0 else { return nil }
        return (dominant, excess / channels[dominant])
    }

    /// A color-difference keyer as an RGBA lookup cube (straight alpha, red
    /// varying fastest). A color is screen when its key channel rises above
    /// the other two as much as the key color's does, relative to its own
    /// brightness, so shadows on the screen key too; near-black never does.
    static func cubeData(key: RGBAColor, tolerance: Double, spill: Double, dimension: Int) -> Data? {
        guard let (dominant, keyStrength) = keyStrength(of: key) else { return nil }
        let first = (dominant + 1) % 3
        let second = (dominant + 2) % 3

        // A score (1 = as strong as the key) above `transparentAbove` is the screen; below `opaqueBelow`, the person.
        let transparentAbove = 0.8 - 0.55 * tolerance.clamped(to: 0...1)
        let opaqueBelow = transparentAbove - 0.25
        let spillAmount = spill.clamped(to: 0...1)

        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        let step = 1 / Double(dimension - 1)
        var index = 0
        var color = SIMD3<Double>()
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    color = SIMD3(Double(red) * step, Double(green) * step, Double(blue) * step)
                    let excess = color[dominant] - max(color[first], color[second])
                    var alpha = 1.0
                    if excess > 0 {
                        let score = (excess / color[dominant]) / keyStrength * smoothstep(0.02, 0.1, color[dominant])
                        alpha = 1 - smoothstep(opaqueBelow, transparentAbove, score)
                        color[dominant] -= spillAmount * excess
                    }
                    // Core Image multiplies by alpha itself.
                    values[index] = Float(color.x)
                    values[index + 1] = Float(color.y)
                    values[index + 2] = Float(color.z)
                    values[index + 3] = Float(alpha)
                    index += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = ((x - edge0) / (edge1 - edge0)).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }

    // MARK: Replacement picture

    private static let pictures = Mutex<[URL: CIImage]>([:])

    /// The picture scaled to cover `extent`, decoded once (at most 1920 px).
    static func replacementPicture(at url: URL, filling extent: CGRect) -> CIImage? {
        let image: CIImage
        if let cached = pictures.withLock({ $0[url] }) {
            image = cached
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1920,
                  ] as CFDictionary) else { return nil }
            image = CIImage(cgImage: decoded)
            pictures.withLock { cache in
                if cache.count >= 4 { cache.removeAll() }
                cache[url] = image
            }
        }
        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = max(extent.width / size.width, extent.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: extent.midX - scaled.width / 2, y: extent.midY - scaled.height / 2)))
            .cropped(to: extent)
    }
}
