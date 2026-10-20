import CoreGraphics
import Foundation

/// A zoom & pan segment (VE-4). Times are **source** seconds so edits to cuts
/// or trim never shift a zoom off the content it was made for.
public struct ZoomSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var range: TimeRange
    /// Target area, normalized to the video frame with a **top-left** origin.
    /// Kept square in normalized units (same aspect as the frame).
    public var rect: CGRect
    /// Seconds spent easing in at the start and out at the end.
    public var easeDuration: Double
    /// Created by auto-zoom (VE-5); re-running auto-zoom replaces these only.
    public var isAutomatic: Bool

    public init(
        id: UUID = UUID(),
        range: TimeRange,
        rect: CGRect,
        easeDuration: Double = ZoomSegment.defaultEase,
        isAutomatic: Bool = false
    ) {
        self.id = id
        self.range = range
        self.rect = rect
        self.easeDuration = easeDuration
        self.isAutomatic = isAutomatic
    }

    public static let defaultEase: Double = 0.5
    public static let defaultScale: Double = 2
    public static let scaleRange: ClosedRange<Double> = 1.1...5
    public static let easeRange: ClosedRange<Double> = 0.1...2
    public static let minimumDuration: Double = 0.3

    /// Magnification at full zoom (2 = twice as large).
    public var scale: Double {
        let side = max(rect.width, rect.height)
        return side > 0 ? 1 / side : 1
    }

    public var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    /// A square (in normalized units) zoom rect around `center`, shifted so it
    /// stays inside the frame.
    public static func rect(center: CGPoint, scale: Double) -> CGRect {
        let side = 1 / scale.clamped(to: 1...20)
        return ZoomMath.clampInsideFrame(
            CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        )
    }
}

/// Playback-rate change over a source range (VE-11). Rate 2 = twice as fast.
public struct SpeedSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var range: TimeRange
    public var rate: Double

    public init(id: UUID = UUID(), range: TimeRange, rate: Double) {
        self.id = id
        self.range = range
        self.rate = rate
    }

    public static let rateRange: ClosedRange<Double> = 0.25...8
    public static let presets: [Double] = [0.5, 1, 1.5, 2, 4]
}

public struct TrackVolume: Codable, Hashable, Sendable {
    /// Linear gain, 0…1.
    public var volume: Double
    public var isMuted: Bool

    public init(volume: Double = 1, isMuted: Bool = false) {
        self.volume = volume
        self.isMuted = isMuted
    }

    public var effectiveVolume: Double { isMuted ? 0 : volume.clamped(to: 0...1) }
}

/// Which recorded source an audio track carries (REC-4).
public enum AudioRole: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
}

public struct TrackVolumes: Codable, Hashable, Sendable {
    public var system: TrackVolume
    public var microphone: TrackVolume

    public init(system: TrackVolume = TrackVolume(), microphone: TrackVolume = TrackVolume()) {
        self.system = system
        self.microphone = microphone
    }

    public subscript(role: AudioRole) -> TrackVolume {
        get { role == .system ? system : microphone }
        set {
            switch role {
            case .system: system = newValue
            case .microphone: microphone = newValue
            }
        }
    }
}

/// Everything the user changed about one recording. Pure value type: the
/// editor UI mutates it, `Timeline`/`RenderPlan` interpret it, and it's saved
/// as JSON next to nothing in the user's folders (see `ProjectStore`).
public struct VideoEditProject: Codable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Shortest output the editor allows (seconds), so the timeline never empties.
    public static let minimumKeptDuration: Double = 0.1

    public var version: Int
    public var sourceURL: URL
    /// Source duration when the project was created; used to detect a replaced file.
    public var sourceDuration: Double
    /// Kept part of the source, in source seconds (VE-2).
    public var trim: TimeRange
    /// Removed middle segments, in source seconds (VE-3). Kept merged and sorted.
    public var cuts: [TimeRange]
    public var zooms: [ZoomSegment]
    public var speedSegments: [SpeedSegment]
    public var background: VideoBackground
    public var trackVolumes: TrackVolumes

    public init(
        sourceURL: URL,
        sourceDuration: Double,
        trim: TimeRange? = nil,
        cuts: [TimeRange] = [],
        zooms: [ZoomSegment] = [],
        speedSegments: [SpeedSegment] = [],
        background: VideoBackground = VideoBackground(),
        trackVolumes: TrackVolumes = TrackVolumes()
    ) {
        self.version = Self.currentVersion
        self.sourceURL = sourceURL
        self.sourceDuration = sourceDuration
        self.trim = trim ?? TimeRange(start: 0, end: sourceDuration)
        self.cuts = cuts
        self.zooms = zooms
        self.speedSegments = speedSegments
        self.background = background
        self.trackVolumes = trackVolumes
    }

    public var fullRange: TimeRange { TimeRange(start: 0, end: sourceDuration) }

    /// True when nothing was changed (export can be a straight copy).
    public var isUnedited: Bool {
        cuts.isEmpty && zooms.isEmpty && speedSegments.isEmpty
            && !background.altersFrame && trackVolumes == TrackVolumes()
            && abs(trim.start) < 1e-6 && abs(trim.end - sourceDuration) < 1e-6
    }

    public var timeline: Timeline { Timeline(project: self) }

    // MARK: Trim

    /// Moves the trim start. Ignored if the new trim (with the cuts) would
    /// leave less than `minimumKeptDuration` of video.
    public mutating func setTrimStart(_ time: Double) {
        let upper = trim.end - Self.minimumKeptDuration
        let candidate = TimeRange(start: time.clamped(to: 0...max(0, upper)), end: trim.end)
        if keptDuration(trim: candidate) >= Self.minimumKeptDuration - 1e-9 { trim = candidate }
    }

    /// Moves the trim end, with the same guard as `setTrimStart`.
    public mutating func setTrimEnd(_ time: Double) {
        let lower = trim.start + Self.minimumKeptDuration
        let candidate = TimeRange(start: trim.start, end: time.clamped(to: min(lower, sourceDuration)...sourceDuration))
        if keptDuration(trim: candidate) >= Self.minimumKeptDuration - 1e-9 { trim = candidate }
    }

    private func keptDuration(trim: TimeRange) -> Double {
        Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: cuts).reduce(0) { $0 + $1.duration }
    }

    /// Fits a saved project to the media's actual duration: clamps trim,
    /// cuts, zooms, and speed changes into it.
    public mutating func adapt(toSourceDuration duration: Double) {
        guard duration > 0, duration != sourceDuration else { return }
        sourceDuration = duration
        let full = fullRange
        trim = trim.clamped(to: full) ?? full
        if trim.duration < Self.minimumKeptDuration { trim = full }
        cuts = TimeRange.merged(cuts.compactMap { $0.clamped(to: full) })
        zooms = zooms.compactMap { zoom in
            guard let range = zoom.range.clamped(to: full) else { return nil }
            var zoom = zoom
            zoom.range = range
            return zoom
        }
        speedSegments = speedSegments.compactMap { segment in
            guard let range = segment.range.clamped(to: full) else { return nil }
            var segment = segment
            segment.range = range
            return segment
        }
        if Timeline(project: self).outputDuration < Self.minimumKeptDuration { cuts = [] }
    }

    // MARK: Cuts

    /// Adds a cut, merging it with overlapping ones. Refuses (returns `false`)
    /// if the cut would leave less than `minimumKeptDuration` of video.
    @discardableResult
    public mutating func addCut(_ range: TimeRange) -> Bool {
        guard let clamped = range.clamped(to: fullRange) else { return false }
        let merged = TimeRange.merged(cuts + [clamped])
        let kept = Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: merged)
        guard kept.reduce(0, { $0 + $1.duration }) >= Self.minimumKeptDuration else { return false }
        cuts = merged
        return true
    }

    public mutating func removeCut(_ range: TimeRange) {
        cuts.removeAll { $0 == range }
    }

    // MARK: Zooms

    /// Adds a manual zoom centered in the frame starting at `time`.
    @discardableResult
    public mutating func addZoom(at time: Double, duration: Double = 3, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomSegment {
        let start = time.clamped(to: 0...max(0, sourceDuration - ZoomSegment.minimumDuration))
        let end = min(sourceDuration, start + duration)
        let zoom = ZoomSegment(
            range: TimeRange(start: start, end: end),
            rect: ZoomSegment.rect(center: center, scale: ZoomSegment.defaultScale)
        )
        zooms.append(zoom)
        zooms.sort { $0.range.start < $1.range.start }
        return zoom
    }

    public mutating func updateZoom(_ zoom: ZoomSegment) {
        guard let index = zooms.firstIndex(where: { $0.id == zoom.id }) else { return }
        var zoom = zoom
        zoom.range.start = zoom.range.start.clamped(to: 0...sourceDuration)
        zoom.range.end = zoom.range.end.clamped(to: zoom.range.start...sourceDuration)
        zoom.rect = ZoomMath.clampInsideFrame(zoom.rect)
        zooms[index] = zoom
        zooms.sort { $0.range.start < $1.range.start }
    }

    public mutating func removeZoom(id: ZoomSegment.ID) {
        zooms.removeAll { $0.id == id }
    }

    /// Replaces previous automatic zooms with `suggestions`, keeping manual
    /// zooms and dropping suggestions that overlap them.
    public mutating func applyAutoZooms(_ suggestions: [ZoomSegment]) {
        let manual = zooms.filter { !$0.isAutomatic }
        let accepted = suggestions.filter { suggestion in
            !manual.contains { $0.range.overlaps(suggestion.range) }
        }
        zooms = (manual + accepted).sorted { $0.range.start < $1.range.start }
    }

    // MARK: Speed

    /// Sets the playback rate over `range`, replacing any overlapping speed
    /// changes there. Rate 1 simply clears the range.
    public mutating func setSpeed(_ rate: Double, for range: TimeRange) {
        guard let range = range.clamped(to: fullRange) else { return }
        var result: [SpeedSegment] = []
        for segment in speedSegments {
            for part in segment.range.subtracting(range) where part.duration > 1e-6 {
                result.append(SpeedSegment(range: part, rate: segment.rate))
            }
        }
        let rate = rate.clamped(to: SpeedSegment.rateRange)
        if abs(rate - 1) > 1e-6 {
            result.append(SpeedSegment(range: range, rate: rate))
        }
        speedSegments = result.sorted { $0.range.start < $1.range.start }
    }

    public mutating func removeSpeedSegment(id: SpeedSegment.ID) {
        speedSegments.removeAll { $0.id == id }
    }
}
