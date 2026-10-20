import CoreGraphics
import Foundation

/// Stitches successive captures of a scrolling area into one tall image (SC-11).
///
/// Each frame is reduced to per-row signatures (a 64-column grayscale strip
/// per pixel row). The vertical scroll offset between two frames is found by
/// locating a high-detail block of rows from the new frame inside the previous
/// one, then verified over the whole overlap. Rows that stay put at the top or
/// bottom (sticky headers/footers) are detected and kept only once.
///
/// Only downward scrolling is stitched; frames that scrolled up or didn't move
/// are ignored. Not thread-safe: feed frames from one task.
public final class ScrollStitcher {
    public struct Signatures: Sendable {
        public let rows: Int
        public static let width = 64
        /// `rows × width` grayscale samples.
        let data: [UInt8]

        func row(_ index: Int) -> ArraySlice<UInt8> {
            data[(index * Self.width)..<((index + 1) * Self.width)]
        }
    }

    public enum FrameResult: Equatable, Sendable {
        case first
        case appended(rows: Int)
        case unchanged
        case unmatched
    }

    private var strips: [CGImage] = []
    private var previous: CGImage?
    private var previousSignatures: Signatures?
    private var headerRows = 0
    private var footerRows = 0
    /// Rows appended so far (pixels), excluding the footer.
    public private(set) var height = 0
    public let maxHeight: Int

    public init(maxHeight: Int = 40_000) {
        self.maxHeight = maxHeight
    }

    public var frameCount: Int { strips.count }
    public var isFull: Bool { height >= maxHeight }

    /// Adds a frame captured after scrolling.
    @discardableResult
    public func add(_ frame: CGImage) -> FrameResult {
        guard let signatures = Self.signatures(of: frame) else { return .unmatched }
        guard let previous, let previousSignatures, previous.width == frame.width, previous.height == frame.height else {
            self.previous = frame
            self.previousSignatures = signatures
            strips = [frame]
            height = frame.height
            return .first
        }

        let (header, footer) = Self.stickyEdges(previousSignatures, signatures)
        guard let offset = Self.offset(previous: previousSignatures, next: signatures, header: header, footer: footer) else {
            return .unmatched
        }
        guard offset > 0 else { return .unchanged }

        // First real scroll: drop the footer from what we already have; it's
        // re-added once at the end.
        if footerRows == 0, footer > 0, strips.count == 1, let first = strips.first,
           let trimmed = first.cropping(to: CGRect(x: 0, y: 0, width: first.width, height: first.height - footer)) {
            strips = [trimmed]
            height = trimmed.height
        }
        headerRows = max(headerRows, header)
        footerRows = max(footerRows, footer)

        let newRows = min(offset, frame.height - footerRows - headerRows)
        guard newRows > 0,
              let strip = frame.cropping(to: CGRect(x: 0, y: frame.height - footerRows - newRows,
                                                    width: frame.width, height: newRows)) else { return .unmatched }
        strips.append(strip)
        height += newRows
        self.previous = frame
        self.previousSignatures = signatures
        return .appended(rows: newRows)
    }

    /// The stitched image (with the sticky footer from the last frame).
    public func makeImage() -> CGImage? {
        guard let first = strips.first else { return nil }
        let footer: CGImage? = footerRows > 0
            ? previous?.cropping(to: CGRect(x: 0, y: (previous?.height ?? 0) - footerRows, width: previous?.width ?? 0, height: footerRows))
            : nil
        let total = min(height + (footer?.height ?? 0), maxHeight + footerRows)
        let width = first.width
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        var y = 0 // from the top
        for strip in strips + [footer].compactMap({ $0 }) {
            guard y < total else { break }
            context.draw(strip, in: CGRect(x: 0, y: total - y - strip.height, width: strip.width, height: strip.height))
            y += strip.height
        }
        return context.makeImage()
    }

    /// A small rendering of the stitched result for live preview.
    public func makePreview(maxWidth: Int) -> CGImage? {
        guard let first = strips.first else { return nil }
        let factor = min(1, CGFloat(maxWidth) / CGFloat(first.width))
        let width = max(1, Int(CGFloat(first.width) * factor))
        let total = max(1, Int(CGFloat(height) * factor))
        guard let context = CGContext(
            data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        var y: CGFloat = 0
        for strip in strips {
            let h = CGFloat(strip.height) * factor
            context.draw(strip, in: CGRect(x: 0, y: CGFloat(total) - y - h, width: CGFloat(width), height: h))
            y += h
        }
        return context.makeImage()
    }

    // MARK: - Analysis (internal for tests)

    static func signatures(of image: CGImage) -> Signatures? {
        let width = Signatures.width
        let rows = image.height
        guard rows > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: width * rows)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: rows))
            return true
        }
        // CGContext memory is top-row-first, matching CGImage row order.
        return drawn ? Signatures(rows: rows, data: data) : nil
    }

    static func rowDifference(_ a: ArraySlice<UInt8>, _ b: ArraySlice<UInt8>) -> Int {
        var total = 0
        for (x, y) in zip(a, b) { total += abs(Int(x) - Int(y)) }
        return total
    }

    /// Rows identical at the same position in both frames at the top and bottom.
    /// Only meaningful when something in the middle changed.
    static func stickyEdges(_ a: Signatures, _ b: Signatures) -> (header: Int, footer: Int) {
        let rows = min(a.rows, b.rows)
        let limit = rows / 3
        let tolerance = Signatures.width * 2
        var header = 0
        while header < limit, rowDifference(a.row(header), b.row(header)) <= tolerance { header += 1 }
        var footer = 0
        while footer < limit, rowDifference(a.row(rows - 1 - footer), b.row(rows - 1 - footer)) <= tolerance { footer += 1 }
        if header == limit && footer == limit { return (0, 0) } // nothing moved at all
        // Short runs are usually just matching backgrounds, not sticky bars.
        return (header >= 8 ? header : 0, footer >= 8 ? footer : 0)
    }

    /// How many rows the content moved up between `previous` and `next`, or nil
    /// if no confident match. 0 means unchanged.
    static func offset(previous: Signatures, next: Signatures, header: Int, footer: Int) -> Int? {
        let rows = min(previous.rows, next.rows)
        let bodyStart = header
        let bodyEnd = rows - footer
        let body = bodyEnd - bodyStart
        guard body > 32 else { return nil }

        if (bodyStart..<bodyEnd).allSatisfy({ rowDifference(previous.row($0), next.row($0)) <= Signatures.width }) {
            return 0
        }

        // Anchors: detailed blocks near the top of the new frame (the top is what
        // overlaps the previous frame, whatever the scroll distance). Try the most
        // detailed few and keep the first offset that verifies over the overlap.
        let blockSize = min(24, body / 4)
        let searchEnd = bodyStart + max(blockSize, body / 3)
        let candidates = stride(from: bodyStart, to: searchEnd, by: max(1, blockSize / 2))
            .map { (row: $0, detail: detail(next, from: $0, count: blockSize)) }
            .filter { $0.detail > 0 }
            .sorted { $0.detail > $1.detail }
            .prefix(3)

        for anchor in candidates.map(\.row) {
            guard let position = bestMatch(of: next, block: anchor, count: blockSize, in: previous,
                                           from: anchor, to: bodyEnd - blockSize) else { continue }
            let offset = position - anchor
            if offset == 0 { return 0 }
            if verify(previous: previous, next: next, offset: offset, bodyStart: bodyStart, bodyEnd: bodyEnd) {
                return offset
            }
        }
        return nil
    }

    private static func bestMatch(of next: Signatures, block: Int, count: Int, in previous: Signatures,
                                  from start: Int, to end: Int) -> Int? {
        guard start <= end else { return nil }
        var best: (position: Int, score: Int)?
        for position in start...end {
            var score = 0
            for i in 0..<count {
                score += rowDifference(previous.row(position + i), next.row(block + i))
                if let best, score >= best.score { break }
            }
            if best == nil || score < best!.score { best = (position, score) }
        }
        return best?.position
    }

    private static func verify(previous: Signatures, next: Signatures, offset: Int, bodyStart: Int, bodyEnd: Int) -> Bool {
        let overlap = bodyEnd - bodyStart - offset
        guard overlap >= 16 else { return false }
        var total = 0
        for i in 0..<overlap {
            total += rowDifference(previous.row(bodyStart + offset + i), next.row(bodyStart + i))
        }
        return Double(total) / Double(overlap * Signatures.width) < 6
    }

    /// Variation inside a block (vertical + horizontal), so anchors avoid blank areas.
    private static func detail(_ signatures: Signatures, from start: Int, count: Int) -> Int {
        var total = 0
        for row in start..<(start + count - 1) {
            total += rowDifference(signatures.row(row), signatures.row(row + 1))
            let r = signatures.row(row)
            for (a, b) in zip(r, r.dropFirst()) { total += abs(Int(a) - Int(b)) }
        }
        return total
    }
}
