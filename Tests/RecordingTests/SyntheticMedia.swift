import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
@testable import Recording

/// Builds sample buffers shaped like ScreenCaptureKit's, so the writer can be
/// exercised without Screen Recording permission.
enum SyntheticMedia {
    static func videoFrame(at time: CMTime, width: Int = 320, height: Int = 240, shade: UInt8 = 128) -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        let buffer = pixelBuffer!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(shade), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format!,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    /// Float32 PCM. `interleaved: false` matches ScreenCaptureKit's system audio.
    static func audio(
        at time: CMTime,
        frames: Int = 1024,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        interleaved: Bool = false,
        value: Float = 0.25
    ) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(4 * (interleaved ? channels : 1)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * (interleaved ? channels : 1)),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )

        let bufferCount = interleaved ? 1 : channels
        let samplesPerBuffer = interleaved ? frames * channels : frames
        let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for index in 0..<bufferCount {
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: samplesPerBuffer)
            memory.initialize(repeating: value, count: samplesPerBuffer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(interleaved ? channels : 1),
                mDataByteSize: UInt32(samplesPerBuffer * 4),
                mData: UnsafeMutableRawPointer(memory)
            )
        }
        var timings = [CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )]
        return AudioBuffers.makeBuffer(format: format!, frames: frames, timings: &timings, audioBufferList: list.unsafePointer)!
    }
}
