import AppCore
import Foundation
import Transcription

/// How captions look and whether they're on (PRD CAP-1, CAP-3, CAP-4).
/// Caption colors are content, like annotation colors, so they're fixed.
public struct CaptionSettings: Codable, Hashable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable, Identifiable {
        /// White text on a dark rounded box.
        case box
        /// White text with a dark outline, no box.
        case outline
        /// Dark text on a yellow box.
        case highlight

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .box: "Box"
            case .outline: "Outline"
            case .highlight: "Highlight"
            }
        }
    }

    public enum Position: String, Codable, CaseIterable, Sendable, Identifiable {
        case bottom
        case top

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    public enum Size: String, Codable, CaseIterable, Sendable, Identifiable {
        case small
        case medium
        case large

        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }

        /// Font size as a share of the output height.
        public var heightFraction: Double {
            switch self {
            case .small: 0.042
            case .medium: 0.052
            case .large: 0.066
            }
        }
    }

    /// A captions file saved next to MP4 exports (CAP-4).
    public enum FileFormat: String, Codable, CaseIterable, Sendable, Identifiable {
        case none
        case srt
        case vtt

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .none: "None"
            case .srt: "SRT"
            case .vtt: "WebVTT"
            }
        }
    }

    public var isEnabled: Bool
    public var style: Style
    public var position: Position
    public var size: Size
    public var fileFormat: FileFormat

    public init(isEnabled: Bool = true, style: Style = .box, position: Position = .bottom, size: Size = .medium, fileFormat: FileFormat = .none) {
        self.isEnabled = isEnabled
        self.style = style
        self.position = position
        self.size = size
        self.fileFormat = fileFormat
    }
}

/// One caption on screen, timed in **output** seconds.
public struct CaptionCue: Hashable, Sendable {
    public var output: TimeRange
    public var lines: [String]

    public var text: String { lines.joined(separator: "\n") }
}

/// The cues drawn into frames, with their look. Part of `RenderPlan`.
public struct CaptionTrack: Hashable, Sendable {
    public var cues: [CaptionCue]
    public var style: CaptionSettings.Style
    public var position: CaptionSettings.Position
    public var size: CaptionSettings.Size

    /// The cue showing at output `time`, if any.
    public func cue(at time: Double) -> CaptionCue? {
        var low = 0
        var high = cues.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let cue = cues[middle]
            if time < cue.output.start {
                high = middle - 1
            } else if time >= cue.output.end {
                low = middle + 1
            } else {
                return cue
            }
        }
        return nil
    }
}

/// Groups transcript words into readable cues (PRD CAP-1): at most two lines,
/// 0.8–6 s each, broken at sentence ends, pauses, and cuts. Times follow the
/// edited timeline, so captions match the exported video. Pure.
public enum CaptionBuilder {
    public static let minimumDuration = 0.8
    public static let maximumDuration = 6.0
    /// A pause this long ends a cue.
    public static let pauseBreak = 0.35
    /// How long a cue lingers after its last word when nothing follows soon.
    static let linger = 0.25

    /// - Parameter maxLineLength: characters per line (about 42 for
    ///   landscape video, fewer for portrait).
    public static func cues(words: [TranscriptWord], timeline: Timeline, maxLineLength: Int = 42) -> [CaptionCue] {
        struct Placed {
            var text: String
            var start: Double
            var end: Double
            var sourceEnd: Double
        }
        var groups: [[Placed]] = []
        var current: [Placed] = []
        func flush() {
            if !current.isEmpty { groups.append(current) }
            current = []
        }

        for (index, word) in words.enumerated() {
            // Words the edit removes end the cue and aren't shown.
            guard timeline.isKept(source: word.range.midpoint) else {
                flush()
                continue
            }
            let start = timeline.nearestOutputTime(forSource: word.start)
            let end = max(start, timeline.nearestOutputTime(forSource: word.end))
            if let previous = current.last, let first = current.first {
                let length = current.reduce(0) { $0 + $1.text.count + 1 } + word.text.count
                // Footage was removed between the two words: start a new cue.
                let spliced = (start - previous.end) < (word.start - previous.sourceEnd) - 0.05
                if length > 2 * maxLineLength || end - first.start > maximumDuration || spliced { flush() }
            }
            current.append(Placed(text: word.text, start: start, end: end, sourceEnd: word.end))
            let next = words.indices.contains(index + 1) ? words[index + 1] : nil
            if word.endsSentence || (next.map { $0.start - word.end >= pauseBreak } ?? true) { flush() }
        }
        flush()

        var cues = groups.map { group in
            CaptionCue(output: TimeRange(start: group[0].start, end: group[group.count - 1].end),
                       lines: wrap(group.map(\.text), maxLineLength: maxLineLength))
        }
        // Each cue stays up long enough to read, without running into the next.
        for index in cues.indices {
            let next = index + 1 < cues.count ? cues[index + 1].output.start : Double.infinity
            var end = max(cues[index].output.end + linger, cues[index].output.start + minimumDuration)
            end = min(end, next - 0.04)
            cues[index].output.end = max(end, cues[index].output.start + 0.1)
        }
        return cues
    }

    /// One line if it fits; otherwise two lines of about equal length.
    static func wrap(_ words: [String], maxLineLength: Int) -> [String] {
        let full = words.joined(separator: " ")
        guard full.count > maxLineLength, words.count > 1 else { return [full] }
        var best = 1
        var bestScore = Int.max
        for split in 1..<words.count {
            let first = words[..<split].joined(separator: " ").count
            let second = words[split...].joined(separator: " ").count
            let overflow = max(0, first - maxLineLength) + max(0, second - maxLineLength)
            let score = overflow * 1_000 + abs(first - second)
            if score < bestScore {
                bestScore = score
                best = split
            }
        }
        return [words[..<best].joined(separator: " "), words[best...].joined(separator: " ")]
    }

    // MARK: Files (CAP-4)

    public static func srt(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.output.start, separator: ",")) --> \(timestamp(cue.output.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    public static func vtt(_ cues: [CaptionCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.output.start, separator: ".")) --> \(timestamp(cue.output.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (WebVTT).
    static func timestamp(_ seconds: Double, separator: String) -> String {
        let milliseconds = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60, separator, milliseconds % 1000)
    }
}

public extension VideoEditProject {
    /// The captions to draw for `timeline`, or `nil` when they're off or
    /// there's no transcript yet.
    func captionTrack(timeline: Timeline, portrait: Bool) -> CaptionTrack? {
        guard let settings = captions, settings.isEnabled, let words = transcript?.words, !words.isEmpty else { return nil }
        let cues = CaptionBuilder.cues(words: words, timeline: timeline, maxLineLength: portrait ? 32 : 42)
        guard !cues.isEmpty else { return nil }
        return CaptionTrack(cues: cues, style: settings.style, position: settings.position, size: settings.size)
    }
}
