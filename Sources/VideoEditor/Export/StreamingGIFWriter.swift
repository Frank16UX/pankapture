import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes an animated GIF frame by frame with constant memory.
///
/// `CGImageDestination` keeps every frame until `finalize`, which costs
/// gigabytes for a minute-long GIF. Instead, each frame is encoded by ImageIO
/// as a one-frame GIF in memory (so ImageIO still does the palette
/// quantization and LZW compression), and its image block is spliced into the
/// animated file on disk with its own local color table and frame delay.
final class StreamingGIFWriter {
    enum WriterError: Error {
        case encodeFailed
        case malformedFrame
    }

    private let handle: FileHandle
    private let width: Int
    private let height: Int
    private var elapsedCentiseconds = 0
    private var elapsedSeconds = 0.0
    private(set) var frameCount = 0

    /// - Parameter loopCount: 0 loops forever; otherwise how many times the
    ///   animation plays (ImageIO's `kCGImagePropertyGIFLoopCount` convention).
    init(url: URL, width: Int, height: Int, loopCount: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.width = width
        self.height = height

        var header = Data("GIF89a".utf8)
        header.appendUInt16(width)
        header.appendUInt16(height)
        header.append(contentsOf: [0x00, 0x00, 0x00]) // no global color table, bg 0, square pixels
        // NETSCAPE2.0 application extension. Its field counts *repeats*
        // (0 = forever), so playing once means leaving it out.
        if loopCount != 1 {
            header.append(contentsOf: [0x21, 0xFF, 0x0B])
            header.append(contentsOf: Array("NETSCAPE2.0".utf8))
            header.append(contentsOf: [0x03, 0x01])
            header.appendUInt16(loopCount <= 0 ? 0 : min(loopCount - 1, 0xFFFF))
            header.append(0x00)
        }
        try handle.write(contentsOf: header)
    }

    /// Appends `image` shown for `duration` seconds. Delays are tracked in
    /// absolute time so centisecond rounding never drifts (15 fps → 7, 6, 7, …).
    func append(_ image: CGImage, duration: Double) throws {
        let frame = try Self.encodeSingleFrame(image)
        let block = try Self.imageBlock(from: frame)

        elapsedSeconds += duration
        let end = Int((elapsedSeconds * 100).rounded())
        let delay = max(1, end - elapsedCentiseconds)
        elapsedCentiseconds += delay

        var out = Data()
        // Graphic control extension: disposal "do not dispose", delay, transparency.
        out.append(contentsOf: [0x21, 0xF9, 0x04])
        out.append(UInt8(1 << 2) | (block.transparentIndex != nil ? 1 : 0))
        out.appendUInt16(delay)
        out.append(block.transparentIndex ?? 0)
        out.append(0x00)
        // Image descriptor with a local color table.
        out.append(0x2C)
        out.appendUInt16(block.left)
        out.appendUInt16(block.top)
        out.appendUInt16(block.width)
        out.appendUInt16(block.height)
        out.append(0x80 | (block.interlaced ? 0x40 : 0) | block.colorTableSizeBits)
        out.append(block.colorTable)
        out.append(block.imageData)
        try handle.write(contentsOf: out)
        frameCount += 1
    }

    func finish() throws {
        try handle.write(contentsOf: Data([0x3B]))
        try handle.close()
    }

    /// Closes without a trailer (the caller deletes the partial file).
    func abandon() {
        try? handle.close()
    }

    // MARK: Single-frame encoding

    private static func encodeSingleFrame(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.gif.identifier as CFString, 1, nil) else {
            throw WriterError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WriterError.encodeFailed }
        return data as Data
    }

    struct ImageBlock {
        var left = 0, top = 0, width = 0, height = 0
        var interlaced = false
        /// Color table bytes (3 per entry, power-of-two entry count ≥ 2).
        var colorTable = Data()
        /// Size field N where the table has 2^(N+1) entries.
        var colorTableSizeBits: UInt8 = 0
        var transparentIndex: UInt8?
        /// LZW minimum code size byte plus the data sub-blocks and terminator.
        var imageData = Data()
    }

    /// Extracts the first image (with its effective color table) from a GIF.
    static func imageBlock(from gif: Data) throws -> ImageBlock {
        let bytes = [UInt8](gif)
        var reader = ByteReader(bytes: bytes)
        guard bytes.count > 13, bytes.starts(with: Array("GIF8".utf8)) else { throw WriterError.malformedFrame }
        reader.offset = 10
        let screenPacked = try reader.byte()
        reader.offset = 13
        var globalTable = Data()
        var globalBits: UInt8 = 0
        if screenPacked & 0x80 != 0 {
            globalBits = screenPacked & 0x07
            globalTable = Data(try reader.bytes(3 * (1 << (Int(globalBits) + 1))))
        }

        var block = ImageBlock()
        while true {
            switch try reader.byte() {
            case 0x21: // extension
                let label = try reader.byte()
                if label == 0xF9 {
                    let size = try reader.byte()
                    let body = try reader.bytes(Int(size))
                    if size >= 4, body[body.startIndex] & 0x01 != 0 { block.transparentIndex = body[body.startIndex + 3] }
                    try reader.skipSubBlocks()
                } else {
                    try reader.skipSubBlocks()
                }
            case 0x2C: // image descriptor
                block.left = try reader.uint16()
                block.top = try reader.uint16()
                block.width = try reader.uint16()
                block.height = try reader.uint16()
                let packed = try reader.byte()
                block.interlaced = packed & 0x40 != 0
                if packed & 0x80 != 0 {
                    block.colorTableSizeBits = packed & 0x07
                    block.colorTable = Data(try reader.bytes(3 * (1 << (Int(block.colorTableSizeBits) + 1))))
                } else if !globalTable.isEmpty {
                    block.colorTableSizeBits = globalBits
                    block.colorTable = globalTable
                } else {
                    throw WriterError.malformedFrame
                }
                let start = reader.offset
                _ = try reader.byte() // LZW minimum code size
                try reader.skipSubBlocks()
                block.imageData = Data(bytes[start..<reader.offset])
                return block
            default:
                throw WriterError.malformedFrame
            }
        }
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw StreamingGIFWriter.WriterError.malformedFrame }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw StreamingGIFWriter.WriterError.malformedFrame }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    mutating func uint16() throws -> Int {
        let low = Int(try byte())
        let high = Int(try byte())
        return low | (high << 8)
    }

    /// Skips data sub-blocks up to and including the zero-length terminator.
    mutating func skipSubBlocks() throws {
        while true {
            let size = Int(try byte())
            if size == 0 { return }
            _ = try bytes(size)
        }
    }
}

private extension Data {
    mutating func appendUInt16(_ value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
}
