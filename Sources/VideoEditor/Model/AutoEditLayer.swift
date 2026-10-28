import AppCore
import AutoEdit
import Foundation
import Transcription

/// How much room pauses keep (PRD AE-3). The model (or rules) judges each
/// pause's intent; the preset sets its length, so changing it needs no new
/// analysis. Pauses are never lengthened.
public enum Pacing: String, Codable, CaseIterable, Sendable, Identifiable {
    case tight
    case natural
    case relaxed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tight: "Tight"
        case .natural: "Natural"
        case .relaxed: "Relaxed"
        }
    }

    /// Seconds a pause of `kind` keeps; `nil` = never shortened (screen actions).
    public func target(for kind: PauseKind) -> Double? {
        switch (self, kind) {
        case (_, .action): nil
        case (.tight, .hesitation): 0.10
        case (.tight, .sentence): 0.25
        case (.tight, .section): 0.60
        case (.tight, .emphasis): 0.50
        case (.natural, .hesitation): 0.15
        case (.natural, .sentence): 0.40
        case (.natural, .section): 1.00
        case (.natural, .emphasis): 0.80
        case (.relaxed, .hesitation): 0.25
        case (.relaxed, .sentence): 0.60
        case (.relaxed, .section): 1.50
        case (.relaxed, .emphasis): 1.20
        }
    }

    public static var lastUsed: Pacing {
        UserDefaults.standard.string(forKey: PreferenceKey.autoEditPacing).flatMap(Pacing.init(rawValue:)) ?? .natural
    }
}

/// The review groups the user switches on and off (PRD AE-7).
public enum AutoEditGroup: String, Codable, CaseIterable, Sendable, Identifiable {
    case pauses
    case fillers
    case repeats
    case mistakes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pauses: "Pauses"
        case .fillers: "Fillers"
        case .repeats: "Repeats"
        case .mistakes: "Mistakes"
        }
    }

    public var systemImage: String {
        switch self {
        case .pauses: "pause.circle"
        case .fillers: "text.bubble"
        case .repeats: "repeat"
        case .mistakes: "arrow.uturn.backward.circle"
        }
    }

    public static func of(_ kind: SuggestionKind) -> AutoEditGroup {
        switch kind {
        case .filler: .fillers
        case .stutter, .repeat: .repeats
        case .retake, .falseStart: .mistakes
        }
    }
}

/// Auto-edit's suggestions for one recording, on their own layer next to the
/// user's cuts (PRD AE-7). The timeline subtracts what's enabled; nothing
/// here touches `VideoEditProject.cuts`. Re-running the analysis replaces
/// only items the user hasn't changed.
public struct AutoEditLayer: Codable, Hashable, Sendable {
    /// A pause and what the user decided about it.
    public struct PauseItem: Codable, Hashable, Sendable, Identifiable {
        public var pause: Pause
        /// "Keep as is" (AE-8): never shortened.
        public var keepsLength: Bool
        /// The removed part after the user dragged its edges (AE-8).
        public var adjustedCut: TimeRange?

        public init(pause: Pause, keepsLength: Bool = false, adjustedCut: TimeRange? = nil) {
            self.pause = pause
            self.keepsLength = keepsLength
            self.adjustedCut = adjustedCut
        }

        public var id: Int { pause.id }

        /// Shorter than this isn't worth a cut (and a join).
        static let minimumCut = 0.05

        /// The part removed at `pacing`: the middle of the pause, keeping half
        /// the target on each side so speech keeps its breathing room.
        public func cut(pacing: Pacing) -> TimeRange? {
            if keepsLength { return nil }
            if let adjustedCut { return adjustedCut }
            guard let target = pacing.target(for: pause.kind), pause.duration - target >= Self.minimumCut else { return nil }
            return TimeRange(start: pause.range.start + target / 2, end: pause.range.end - target / 2)
        }

        public var isUserEdited: Bool { keepsLength || adjustedCut != nil || pause.kindSource == .user }
    }

    /// A removal the analysis suggested, and whether it applies.
    public struct Removal: Codable, Hashable, Sendable, Identifiable {
        public var suggestion: Suggestion
        /// The words it removes, for the review list.
        public var text: String
        public var isEnabled: Bool
        /// Toggled or resized by the user: survives re-runs.
        public var isUserEdited: Bool

        public init(suggestion: Suggestion, text: String, isEnabled: Bool, isUserEdited: Bool = false) {
            self.suggestion = suggestion
            self.text = text
            self.isEnabled = isEnabled
            self.isUserEdited = isUserEdited
        }

        public var id: UUID { suggestion.id }
        public var range: TimeRange { suggestion.range }
        public var group: AutoEditGroup { .of(suggestion.kind) }
    }

    public var language: TranscriptLanguage
    public var pacing: Pacing
    /// Groups that apply (AE-7). A switched-off group keeps its items.
    public var groups: Set<AutoEditGroup>
    /// Rate for silent screen actions, or `nil` to leave them as recorded (AE-3).
    public var actionSpeed: Double?
    public var pauses: [PauseItem]
    public var removals: [Removal]
    /// "Rules", or the provider and model that judged.
    public var judgedBy: String

    public init(language: TranscriptLanguage, pacing: Pacing = .natural, groups: Set<AutoEditGroup> = Set(AutoEditGroup.allCases),
                actionSpeed: Double? = nil, pauses: [PauseItem] = [], removals: [Removal] = [], judgedBy: String = "Rules") {
        self.language = language
        self.pacing = pacing
        self.groups = groups
        self.actionSpeed = actionSpeed
        self.pauses = pauses
        self.removals = removals
        self.judgedBy = judgedBy
    }

    /// A layer from an analysis. Removal edges snap to the quietest moment
    /// within ±80 ms (AE-9): recognizer timings come in 60 ms steps, and a
    /// cut mid-consonant is audible.
    public init(analysis: AutoEditAnalysis, envelope: LoudnessEnvelope?, language: TranscriptLanguage, judgedBy: String, keeping previous: AutoEditLayer? = nil) {
        let removals = analysis.suggestions.map { suggestion in
            var snapped = suggestion
            if let envelope { snapped.range = Self.snap(suggestion.range, to: envelope) }
            let text = suggestion.words.map { analysis.transcript.text(of: $0) } ?? ""
            return Removal(suggestion: snapped, text: text, isEnabled: suggestion.isEnabledByDefault)
        }
        self.init(
            language: language,
            pacing: previous?.pacing ?? .lastUsed,
            groups: previous?.groups ?? Set(AutoEditGroup.allCases),
            actionSpeed: previous?.actionSpeed,
            pauses: analysis.pauses.map { PauseItem(pause: $0) },
            removals: removals,
            judgedBy: judgedBy
        )
        if let previous { keepUserEdits(from: previous) }
    }

    static let snapWindow = 0.08

    static func snap(_ range: TimeRange, to envelope: LoudnessEnvelope) -> TimeRange {
        let start = envelope.quietestTime(in: TimeRange(start: range.start - snapWindow, end: range.start + snapWindow)) ?? range.start
        let end = envelope.quietestTime(in: TimeRange(start: range.end - snapWindow, end: range.end + snapWindow)) ?? range.end
        return end - start > 0.02 ? TimeRange(start: start, end: end) : range
    }

    /// Brings over everything the user changed in `previous`, dropping new
    /// items that overlap it.
    mutating func keepUserEdits(from previous: AutoEditLayer) {
        let editedRemovals = previous.removals.filter(\.isUserEdited)
        removals.removeAll { new in editedRemovals.contains { $0.range.overlaps(new.range) } }
        removals = (removals + editedRemovals).sorted { $0.range.start < $1.range.start }

        let editedPauses = previous.pauses.filter(\.isUserEdited)
        pauses.removeAll { new in editedPauses.contains { $0.pause.range.overlaps(new.pause.range) } }
        pauses = (pauses + editedPauses).sorted { $0.pause.range.start < $1.pause.range.start }
        // IDs only identify items within the layer: renumber so they stay unique.
        for index in pauses.indices { pauses[index].pause.id = index }
    }

    // MARK: What applies

    /// Source ranges removed by the enabled items, merged.
    public var cuts: [TimeRange] {
        var ranges: [TimeRange] = []
        if groups.contains(.pauses) { ranges += pauses.compactMap { $0.cut(pacing: pacing) } }
        ranges += removals.filter { $0.isEnabled && groups.contains($0.group) }.map(\.range)
        return TimeRange.merged(ranges)
    }

    /// Silent screen actions played faster (AE-3), when chosen.
    public var speedSegments: [SpeedSegment] {
        guard let rate = actionSpeed, groups.contains(.pauses) else { return [] }
        return pauses.filter { $0.pause.kind == .action && !$0.keepsLength && $0.adjustedCut == nil }
            .map { SpeedSegment(range: $0.pause.range, rate: rate) }
    }

    public var removedDuration: Double { cuts.reduce(0) { $0 + $1.duration } }

    public func count(of group: AutoEditGroup) -> Int {
        switch group {
        case .pauses: pauses.filter { $0.cut(pacing: pacing) != nil }.count
        default: removals.filter { $0.group == group && $0.isEnabled }.count
        }
    }

    // MARK: Editing

    /// Moves an edge of a pause's cut or of a removal to `time` (AE-8).
    public mutating func setEdge(of item: AutoEditItem, start: Bool, to time: Double) {
        switch item {
        case .pause(let id):
            guard let index = pauses.firstIndex(where: { $0.id == id }) else { return }
            var range = pauses[index].cut(pacing: pacing) ?? pauses[index].pause.range
            if start { range.start = min(time, range.end - PauseItem.minimumCut) } else { range.end = max(time, range.start + PauseItem.minimumCut) }
            pauses[index].adjustedCut = range
            pauses[index].keepsLength = false
        case .removal(let id):
            guard let index = removals.firstIndex(where: { $0.id == id }) else { return }
            var range = removals[index].suggestion.range
            if start { range.start = min(time, range.end - 0.02) } else { range.end = max(time, range.start + 0.02) }
            removals[index].suggestion.range = range
            removals[index].isEnabled = true
            removals[index].isUserEdited = true
        }
    }

    public func range(of item: AutoEditItem) -> TimeRange? {
        switch item {
        case .pause(let id):
            guard let pause = pauses.first(where: { $0.id == id }) else { return nil }
            return pause.cut(pacing: pacing) ?? pause.pause.range
        case .removal(let id):
            return removals.first { $0.id == id }?.range
        }
    }
}

/// One item of the auto-edit layer, for selection and editing.
public enum AutoEditItem: Hashable, Sendable {
    case pause(Int)
    case removal(UUID)
}
