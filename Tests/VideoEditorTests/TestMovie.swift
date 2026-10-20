import AVFoundation
import CoreVideo
import Foundation

/// Writes small synthetic movies for media tests: solid-color H.264 frames plus
/// optional AAC tracks (a 440 Hz tone at the given amplitude, 0 = silence).
enum TestMovie {
    struct Spec {
        var duration: Double = 2
        var fps: Int32 = 30
        var width = 160
        var height = 90
        /// BGRA bytes.
        var color: (b: UInt8, g: UInt8, r: UInt8) = (0, 0, 255)
        /// If set, the right half of each (stored, un-rotated) frame uses this color.
        var rightColor: (b: UInt8, g: UInt8, r: UInt8)?
        /// Track display transform (e.g. a 90° rotation, like phone footage).
        var transform: CGAffineTransform = .identity
        /// One entry per audio track: tone amplitude 0…1.
        var audioAmplitudes: [Double] = [0]
        /// Adds a disabled second video track titled "Camera" in this color,
        /// like the recorder's webcam track.
        var cameraColor: (b: UInt8, g: UInt8, r: UInt8)?
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoEditorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Async so it never blocks a Swift concurrency thread: tests run in
    /// parallel, and blocked pool threads can starve `finishWriting`.
    static func make(_ spec: Spec = Spec(), in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("movie-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = spec.transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(videoInput)

        let sampleRate = 44_100.0
        let audioInputs: [AVAssetWriterInput] = spec.audioAmplitudes.map { _ in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }

        var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        if spec.cameraColor != nil {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
            ])
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = false
            let title = AVMutableMetadataItem()
            title.identifier = .commonIdentifierTitle
            title.value = "Camera" as NSString
            title.extendedLanguageTag = "und"
            input.metadata = [title]
            cameraAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 48,
            ])
            writer.add(input)
        }

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        // Feed whichever input is ready: the writer interleaves tracks and may
        // hold one back until the others catch up.
        let frameCount = Int(spec.duration * Double(spec.fps))
        let samplesPerFrame = Int(sampleRate) / Int(spec.fps)
        var nextVideo = 0
        var nextAudio = Array(repeating: 0, count: audioInputs.count)
        var nextCamera = cameraAdaptor == nil ? frameCount : 0
        let deadline = Date().addingTimeInterval(20)
        while nextVideo < frameCount || nextCamera < frameCount || nextAudio.contains(where: { $0 < frameCount }) {
            var progressed = false
            if let cameraAdaptor, let cameraColor = spec.cameraColor, nextCamera < frameCount,
               cameraAdaptor.assetWriterInput.isReadyForMoreMediaData {
                guard let pool = cameraAdaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                fill(buffer, color: cameraColor, rightColor: nil)
                cameraAdaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(nextCamera), timescale: spec.fps))
                nextCamera += 1
                if nextCamera == frameCount { cameraAdaptor.assetWriterInput.markAsFinished() }
                progressed = true
            }
            if nextVideo < frameCount, videoInput.isReadyForMoreMediaData {
                guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw CocoaError(.fileWriteUnknown) }
                fill(buffer, color: spec.color, rightColor: spec.rightColor)
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(nextVideo), timescale: spec.fps))
                nextVideo += 1
                if nextVideo == frameCount { videoInput.markAsFinished() }
                progressed = true
            }
            for (index, input) in audioInputs.enumerated() where nextAudio[index] < frameCount && input.isReadyForMoreMediaData {
                let sample = try toneBuffer(
                    startSample: nextAudio[index] * samplesPerFrame,
                    count: samplesPerFrame,
                    sampleRate: sampleRate,
                    amplitude: spec.audioAmplitudes[index]
                )
                input.append(sample)
                nextAudio[index] += 1
                if nextAudio[index] == frameCount { input.markAsFinished() }
                progressed = true
            }
            if !progressed {
                if Date() > deadline || writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(for: .milliseconds(1))
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private static func fill(_ buffer: CVPixelBuffer, color: (b: UInt8, g: UInt8, r: UInt8), rightColor: (b: UInt8, g: UInt8, r: UInt8)?) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let color = x >= width / 2 ? (rightColor ?? color) : color
                row[x * 4] = color.b
                row[x * 4 + 1] = color.g
                row[x * 4 + 2] = color.r
                row[x * 4 + 3] = 255
            }
        }
    }

    private static func toneBuffer(startSample: Int, count: Int, sampleRate: Double, amplitude: Double) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        var samples = (0..<count).map { index -> Int16 in
            let t = Double(startSample + index) / sampleRate
            return Int16(amplitude * Double(Int16.max) * sin(2 * .pi * 440 * t))
        }
        let length = count * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block
        )
        guard let block, let format else { throw CocoaError(.fileWriteUnknown) }
        samples.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
