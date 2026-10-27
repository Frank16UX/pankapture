import AppCore
import AutoEdit
import CoreGraphics
import Foundation
import Transcription

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
    /// Zooms move a camera over the whole frame (background included) until
    /// the zoomed area fills it, instead of zooming inside the padded video.
    public var zoomFillsFrame: Bool
    /// Split points (source seconds), sorted (VE-3). They divide the kept
    /// footage into segments that can be selected and deleted (cut).
    public var splits: [Double]
    /// The webcam layer, for recordings with a camera track (ADR-25).
    public var camera: CameraOverlay?
    /// Where the camera fills the frame or is hidden (PRD CAM-6), sorted,
    /// never overlapping.
    public var cameraLayouts: [CameraLayoutSegment]
    /// Auto-edit's suggestions (PRD §5.11), on their own layer: the
    /// timeline removes what's enabled there on top of `cuts`.
    public var autoEdit: AutoEditLayer?
    /// The recording's transcript with the user's corrections (PRD CAP-2),
    /// saved with the edits so corrections follow Save and undo.
    public var transcript: Transcript?
    /// Burned-in captions and the captions file (PRD CAP-1–CAP-4).
    public var captions: CaptionSettings?
    /// Noise removal and loudness for the microphone (PRD AU-1, AU-2).
    public var voice: VoiceProcessing?

    public init(
        sourceURL: URL,
        sourceDuration: Double,
        trim: TimeRange? = nil,
        cuts: [TimeRange] = [],
        zooms: [ZoomSegment] = [],
        speedSegments: [SpeedSegment] = [],
        background: VideoBackground = VideoBackground(),
        trackVolumes: TrackVolumes = TrackVolumes(),
        zoomFillsFrame: Bool = false,
        splits: [Double] = [],
        camera: CameraOverlay? = nil,
        cameraLayouts: [CameraLayoutSegment] = [],
        autoEdit: AutoEditLayer? = nil,
        transcript: Transcript? = nil,
        captions: CaptionSettings? = nil,
        voice: VoiceProcessing? = nil
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
        self.zoomFillsFrame = zoomFillsFrame
        self.splits = splits
        self.camera = camera
        self.cameraLayouts = cameraLayouts
        self.autoEdit = autoEdit
        self.transcript = transcript
        self.captions = captions
        self.voice = voice
    }

    private enum CodingKeys: String, CodingKey {
        case version, sourceURL, sourceDuration, trim, cuts, zooms, speedSegments, background, trackVolumes
        case zoomFillsFrame, splits, camera, cameraLayouts, autoEdit, transcript, captions, voice
    }

    /// Keys added after version 1 are optional, so older saved projects open.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        sourceDuration = try container.decode(Double.self, forKey: .sourceDuration)
        trim = try container.decode(TimeRange.self, forKey: .trim)
        cuts = try container.decode([TimeRange].self, forKey: .cuts)
        zooms = try container.decode([ZoomSegment].self, forKey: .zooms)
        speedSegments = try container.decode([SpeedSegment].self, forKey: .speedSegments)
        background = try container.decode(VideoBackground.self, forKey: .background)
        trackVolumes = try container.decode(TrackVolumes.self, forKey: .trackVolumes)
        zoomFillsFrame = try container.decodeIfPresent(Bool.self, forKey: .zoomFillsFrame) ?? false
        splits = try container.decodeIfPresent([Double].self, forKey: .splits) ?? []
        camera = try container.decodeIfPresent(CameraOverlay.self, forKey: .camera)
        cameraLayouts = try container.decodeIfPresent([CameraLayoutSegment].self, forKey: .cameraLayouts) ?? []
        autoEdit = try container.decodeIfPresent(AutoEditLayer.self, forKey: .autoEdit)
        transcript = try container.decodeIfPresent(Transcript.self, forKey: .transcript)
        captions = try container.decodeIfPresent(CaptionSettings.self, forKey: .captions)
        voice = try container.decodeIfPresent(VoiceProcessing.self, forKey: .voice)
    }

    /// The user's cuts plus auto-edit's enabled ones: what the timeline
    /// removes. Auto-edit is ignored if it would leave almost nothing.
    public var effectiveCuts: [TimeRange] {
        guard let auto = autoEdit?.cuts, !auto.isEmpty else { return cuts }
        let combined = TimeRange.merged(cuts + auto)
        let kept = Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: combined)
        return kept.reduce(0) { $0 + $1.duration } >= Self.minimumKeptDuration ? combined : cuts
    }

    /// The user's speed changes plus auto-edit's faster screen actions; the
    /// user's win where they overlap.
    public var effectiveSpeedSegments: [SpeedSegment] {
        let auto = (autoEdit?.speedSegments ?? []).filter { segment in
            !speedSegments.contains { $0.range.overlaps(segment.range) }
        }
        return speedSegments + auto
    }

    public var fullRange: TimeRange { TimeRange(start: 0, end: sourceDuration) }

    /// A fresh project for `source`, with the webcam layer where the bubble
    /// was while recording (from the recording's sidecar).
    /// - Parameter cameraBackground: the default from Settings ▸ Recording
    ///   (PRD CAM-3), so the automatic camera composite gets it too.
    public static func initial(
        for source: SourceMedia,
        sidecar: RecordingSidecar? = nil,
        cameraBackground: CameraBackground = .savedDefault()
    ) -> VideoEditProject {
        var project = VideoEditProject(sourceURL: source.url, sourceDuration: source.duration)
        if source.camera != nil {
            var camera = (sidecar ?? RecordingSidecar.load(for: source.url))?.camera.map(CameraOverlay.init) ?? .standard
            camera.background = cameraBackground
            project.camera = camera
        }
        return project
    }

    /// True when nothing was changed (export can be a straight copy).
    public var isUnedited: Bool {
        cuts.isEmpty && zooms.isEmpty && speedSegments.isEmpty && camera?.isVisible != true && cameraLayouts.isEmpty
            && (autoEdit.map { $0.cuts.isEmpty && $0.speedSegments.isEmpty } ?? true)
            && !(captions?.isEnabled == true && transcript != nil)
            && voice?.isActive != true
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
        Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: effectiveCuts).reduce(0) { $0 + $1.duration }
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
        cameraLayouts = cameraLayouts.compactMap { segment in
            guard let range = segment.range.clamped(to: full), range.duration > 0 else { return nil }
            var segment = segment
            segment.range = range
            return segment
        }
        splits = splits.filter { $0 > 0 && $0 < duration }
        if var layer = autoEdit {
            layer.pauses = layer.pauses.compactMap { item in
                guard let range = item.pause.range.clamped(to: full) else { return nil }
                var item = item
                item.pause.range = range
                item.adjustedCut = item.adjustedCut?.clamped(to: full)
                return item
            }
            layer.removals = layer.removals.compactMap { removal in
                guard let range = removal.range.clamped(to: full) else { return nil }
                var removal = removal
                removal.suggestion.range = range
                return removal
            }
            autoEdit = layer
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
        let kept = Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: merged + (autoEdit?.cuts ?? []))
        guard kept.reduce(0, { $0 + $1.duration }) >= Self.minimumKeptDuration else { return false }
        cuts = merged
        return true
    }

    public mutating func removeCut(_ range: TimeRange) {
        cuts.removeAll { $0 == range }
    }

    // MARK: Splits

    /// Shortest segment a split may create (seconds).
    public static let minimumSegmentDuration: Double = 0.05

    /// Splits the kept footage at `time`. Ignored outside the kept footage or
    /// too close to an existing boundary. Returns whether a split was added.
    @discardableResult
    public mutating func addSplit(at time: Double) -> Bool {
        guard let segment = segments.first(where: { $0.contains(time) }),
              time - segment.start >= Self.minimumSegmentDuration,
              segment.end - time >= Self.minimumSegmentDuration else { return false }
        splits.append(time)
        splits.sort()
        return true
    }

    public mutating func removeSplit(at time: Double) {
        splits.removeAll { abs($0 - time) < 1e-9 }
    }

    /// The kept footage (trim minus cuts) divided at the split points, in
    /// source seconds. Deleting a segment cuts it.
    public var segments: [TimeRange] {
        let kept = Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: effectiveCuts)
        return kept.flatMap { range in
            var pieces: [TimeRange] = []
            var start = range.start
            for split in splits where split > range.start && split < range.end {
                pieces.append(TimeRange(start: start, end: split))
                start = split
            }
            pieces.append(TimeRange(start: start, end: range.end))
            return pieces
        }
    }

    /// Split points that currently divide kept footage (others sit in removed parts).
    public var visibleSplits: [Double] {
        let kept = Timeline.keptRanges(sourceDuration: sourceDuration, trim: trim, cuts: effectiveCuts)
        return splits.filter { split in kept.contains { split > $0.start && split < $0.end } }
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
