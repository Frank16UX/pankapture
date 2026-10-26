import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Synchronization
import Vision

/// Separates the person from the background in camera frames and draws the
/// chosen background behind them (PRD CAM-1, CAM-2, ADR-38).
///
/// Called by the compositor from several queues, out of order while
/// scrubbing, so segmentation is stateless: a new Vision request per frame
/// (the model itself is loaded once by Vision). The only state, the chroma
/// cube and the replacement picture, is cached behind `Mutex`es.
public enum CameraMatte {
    /// Segmentation detail: fast in the preview, balanced for exports.
    public enum Quality: Sendable, Equatable {
        case fast
        case balanced
    }

    /// `image` (extent at the origin) with `background` applied, or `nil`
    /// when the person couldn't be found (the frame is then drawn as is).
    static func apply(_ background: CameraBackground, to image: CIImage, quality: Quality) -> CIImage? {
        let extent = image.extent
        guard background.isActive, extent.width >= 2, extent.height >= 2 else { return nil }

        // The person, with transparency where the background was.
        let person: CIImage
        switch background.effectiveMatte {
        case .person:
            guard let mask = personMask(for: image, quality: quality) else { return nil }
            if background.effect == .blur {
                let blend = CIFilter.blendWithMask()
                blend.inputImage = image
                blend.backgroundImage = blurred(image, amount: background.blurAmount)
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

    /// White where the person is, scaled to `image`'s extent and softened a little.
    static func personMask(for image: CIImage, quality: Quality) -> CIImage? {
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
        let mask = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        let scaled = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width,
                                                            y: extent.height / mask.extent.height))
        let sigma = Double(min(extent.width, extent.height)) * 0.004
        return scaled.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
    }

    // MARK: Blur

    static func blurred(_ image: CIImage, amount: Double) -> CIImage {
        let sigma = Double(min(image.extent.width, image.extent.height)) * (0.008 + 0.042 * amount.clamped(to: 0...1))
        return image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
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
        let cached = cubes.withLock { $0[cubeKey] }
        let data: Data
        if let cached {
            data = cached
        } else {
            guard let made = cubeData(key: key, tolerance: tolerance, spill: spill, dimension: cubeDimension) else { return nil }
            data = made
            cubes.withLock { cache in
                if cache.count >= 8 { cache.removeAll() }
                cache[cubeKey] = made
            }
        }
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = image
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = data
        filter.colorSpace = sRGB
        return filter.outputImage?.cropped(to: image.extent)
    }

    /// A color-difference keyer as an RGBA lookup cube (premultiplied, red
    /// varying fastest): how far a color's key channel rises above the
    /// other two, relative to the key color's, decides its transparency.
    static func cubeData(key: RGBAColor, tolerance: Double, spill: Double, dimension: Int) -> Data? {
        let keyChannels = [key.red, key.green, key.blue]
        guard let dominant = keyChannels.indices.max(by: { keyChannels[$0] < keyChannels[$1] }) else { return nil }
        let others = keyChannels.indices.filter { $0 != dominant }
        let keyExcess = keyChannels[dominant] - max(keyChannels[others[0]], keyChannels[others[1]])
        guard keyExcess > 0.05 else { return nil }

        // A ratio above `transparentAbove` is the screen; below `opaqueBelow`, the person.
        let transparentAbove = 0.8 - 0.55 * tolerance.clamped(to: 0...1)
        let opaqueBelow = transparentAbove - 0.25
        let spillAmount = spill.clamped(to: 0...1)

        var values = [Float](repeating: 0, count: dimension * dimension * dimension * 4)
        let step = 1 / Double(dimension - 1)
        var index = 0
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    var color = [Double(red) * step, Double(green) * step, Double(blue) * step]
                    let excess = color[dominant] - max(color[others[0]], color[others[1]])
                    let alpha = 1 - smoothstep(opaqueBelow, transparentAbove, excess / keyExcess)
                    if excess > 0 { color[dominant] -= spillAmount * excess }
                    values[index] = Float(color[0] * alpha)
                    values[index + 1] = Float(color[1] * alpha)
                    values[index + 2] = Float(color[2] * alpha)
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

    private struct Picture {
        var url: URL
        var image: CIImage
    }

    private static let picture = Mutex<Picture?>(nil)

    /// The picture scaled to cover `extent`, decoded once (at most 1920 px).
    static func replacementPicture(at url: URL, filling extent: CGRect) -> CIImage? {
        let image: CIImage
        if let cached = picture.withLock({ $0?.url == url ? $0?.image : nil }) {
            image = cached
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1920,
                  ] as CFDictionary) else { return nil }
            image = CIImage(cgImage: decoded)
            picture.withLock { $0 = Picture(url: url, image: image) }
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
