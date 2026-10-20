import AudioToolbox
import CoreMedia

/// Sample-buffer helpers shared by the writer and the level meter.
enum AudioBuffers {
    /// Copy of `sampleBuffer` shifted earlier by `offset` (pause compensation).
    /// Returns the original when `offset` is zero.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        var timings = timingInfo(of: sampleBuffer)
        guard !timings.isEmpty else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    static func timingInfo(of sampleBuffer: CMSampleBuffer) -> [CMSampleTimingInfo] {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return [] }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count
        ) == noErr else { return [] }
        return timings
    }

    static func streamDescription(of sampleBuffer: CMSampleBuffer) -> AudioStreamBasicDescription? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    }

    /// Runs `body` with the buffer's PCM data as an `AudioBufferList`.
    static func withAudioBufferList<T>(
        _ sampleBuffer: CMSampleBuffer,
        _ body: (UnsafeMutableAudioBufferListPointer) -> T
    ) -> T? {
        var listSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &listSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        ) == noErr, listSize > 0 else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)

        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: listSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }
        // `blockBuffer` keeps the memory alive until we return.
        return withExtendedLifetime(blockBuffer) { body(UnsafeMutableAudioBufferListPointer(list)) }
    }

    /// Peak amplitude (0…1) of linear-PCM audio (float32, int16, or int32;
    /// interleaved or not). Returns 0 for formats it can't read.
    static func peakLevel(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let asbd = streamDescription(of: sampleBuffer), asbd.mFormatID == kAudioFormatLinearPCM else { return 0 }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = asbd.mBitsPerChannel
        return withAudioBufferList(sampleBuffer) { buffers in
            var peak: Float = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let bytes = Int(buffer.mDataByteSize)
                if isFloat, bits == 32 {
                    let samples = data.bindMemory(to: Float.self, capacity: bytes / 4)
                    for i in 0..<(bytes / 4) { peak = max(peak, abs(samples[i])) }
                } else if !isFloat, bits == 16 {
                    let samples = data.bindMemory(to: Int16.self, capacity: bytes / 2)
                    for i in 0..<(bytes / 2) { peak = max(peak, abs(Float(samples[i])) / 32_768) }
                } else if !isFloat, bits == 32 {
                    let samples = data.bindMemory(to: Int32.self, capacity: bytes / 4)
                    for i in 0..<(bytes / 4) { peak = max(peak, abs(Float(samples[i])) / 2_147_483_648) }
                }
            }
            return min(peak, 1)
        } ?? 0
    }

    /// Maps a linear peak to a perceptual 0…1 meter value (−50 dBFS … 0 dBFS).
    static func meterValue(forPeak peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return max(0, min(1, (decibels + 50) / 50))
    }

    /// A copy of `sampleBuffer` with the same format, timing, and layout but
    /// all-zero samples. Used when the microphone is muted so the track stays
    /// continuous (digital silence) instead of having gaps.
    static func silencedCopy(of sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        var timings = timingInfo(of: sampleBuffer)
        guard frames > 0, !timings.isEmpty else { return nil }

        return withAudioBufferList(sampleBuffer) { source -> CMSampleBuffer? in
            // Build a zeroed list with the same buffer count and sizes.
            let zeroed = AudioBufferList.allocate(maximumBuffers: source.count)
            defer {
                for buffer in zeroed { buffer.mData?.deallocate() }
                free(zeroed.unsafeMutablePointer)
            }
            for (index, buffer) in source.enumerated() {
                let size = Int(buffer.mDataByteSize)
                let memory = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 16)
                memory.initializeMemory(as: UInt8.self, repeating: 0, count: max(size, 1))
                zeroed[index] = AudioBuffer(
                    mNumberChannels: buffer.mNumberChannels,
                    mDataByteSize: buffer.mDataByteSize,
                    mData: memory
                )
            }
            return makeBuffer(format: format, frames: frames, timings: &timings, audioBufferList: zeroed.unsafePointer)
        } ?? nil
    }

    /// Creates a PCM sample buffer whose data is copied from `audioBufferList`.
    static func makeBuffer(
        format: CMFormatDescription,
        frames: CMItemCount,
        timings: inout [CMSampleTimingInfo],
        audioBufferList: UnsafePointer<AudioBufferList>
    ) -> CMSampleBuffer? {
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        ) == noErr else { return nil }
        return buffer
    }
}
