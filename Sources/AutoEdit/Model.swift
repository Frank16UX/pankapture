import AIProviders
import AppCore
import Foundation
import Transcription

/// What a pause is for (PRD AE-2). Pacing (AE-3) gives each kind its own
/// target length; deliberate kinds keep more room.
public enum PauseKind: String, Codable, CaseIterable, Sendable {
    /// Mid-thought, searching for words.
    case hesitation
    /// An ordinary break between sentences (or after a comma).
    case sentence
    /// A deliberate break between parts of the recording.
    case section
    /// A deliberate dramatic pause.
    case emphasis
    /// Silent while something happens on screen.
    case action

    /// Pauses the speaker meant to make. Pacing never squeezes these to
    /// hesitation length.
    public var isDeliberate: Bool {
        switch self {
        case .section, .emphasis, .action: true
        case .hesitation, .sentence: false
        }
    }

    public var title: String {
        switch self {
        case .hesitation: "Hesitation"
        case .sentence: "Sentence break"
        case .section: "Section break"
        case .emphasis: "Emphasis"
        case .action: "Screen action"
        }
    }
}

/// Who made a judgment: the built-in rules, the configured model, or the user.
public enum DecisionSource: String, Codable, Sendable {
    case rules
    case model
    case user
}

/// What happened on screen during a pause.
public struct ScreenActivity: Codable, Hashable, Sendable {
    /// Clicks recorded in the sidecar during the pause.
    public var clicks: Int
    /// Largest share of pixels that changed noticeably between samples, 0…1.
    /// `nil` when the video couldn't be sampled: unknown counts as active, so
    /// a pause that might hide on-screen work is never cut.
    public var changedFraction: Double?

    public init(clicks: Int = 0, changedFraction: Double? = 0) {
        self.clicks = clicks
        self.changedFraction = changedFraction
    }

    public static let none = ScreenActivity()

    /// About 60 pixels of a 160 × 100 frame: a menu opening, typing, a page
    /// changing. A cursor moving across a still screen stays below it.
    public static let changeThreshold = 0.004

    public var isUnknown: Bool { changedFraction == nil }
    public var isChanging: Bool { (changedFraction ?? 0) >= Self.changeThreshold }
    public var isActive: Bool { clicks > 0 || isChanging || isUnknown }

    /// "still", "changing", "2 clicks, changing": how prompts describe it.
    public var summary: String {
        var parts: [String] = []
        if clicks > 0 { parts.append(clicks == 1 ? "1 click" : "\(clicks) clicks") }
        if isChanging { parts.append("changing") }
        if isUnknown { parts.append("unknown") }
        return parts.isEmpty ? "still" : parts.joined(separator: ", ")
    }
}

/// A silence between two words on the microphone track.
public struct Pause: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    /// The silent span, source seconds.
    public var range: TimeRange
    /// Index of the transcript word right before the pause.
    public var afterWord: Int
    public var activity: ScreenActivity
    public var kind: PauseKind
    public var kindSource: DecisionSource

    public init(id: Int, range: TimeRange, afterWord: Int, activity: ScreenActivity = .none,
                kind: PauseKind = .sentence, kindSource: DecisionSource = .rules) {
        self.id = id
        self.range = range
        self.afterWord = afterWord
        self.activity = activity
        self.kind = kind
        self.kindSource = kindSource
    }

    public var duration: Double { range.duration }
}

public enum SuggestionKind: String, Codable, CaseIterable, Sendable {
    case filler
    /// A single word said twice ("the the"), not on purpose.
    case stutter
    /// Words said twice; the earlier copy goes.
    case `repeat`
    /// A correction: the abandoned words and the cue ("April. Wait, sorry, I meant").
    case retake
    /// A sentence started and abandoned.
    case falseStart

    /// Mistakes (AE-5, AE-6) as opposed to fillers (AE-4).
    public var isMistake: Bool { self != .filler }

    public var title: String {
        switch self {
        case .filler: "Filler"
        case .stutter: "Stutter"
        case .repeat: "Repeat"
        case .retake: "Retake"
        case .falseStart: "False start"
        }
    }
}

/// A part of the recording auto-edit suggests removing (AE-4–AE-6).
public struct Suggestion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SuggestionKind
    /// What to remove, source seconds.
    public var range: TimeRange
    /// The transcript words it removes, when it maps to words.
    public var words: ClosedRange<Int>?
    /// 0…1. Suggestions below `enabledThreshold` start switched off.
    public var confidence: Double
    /// Why it was suggested, for the review UI and reports.
    public var reason: String
    public var source: DecisionSource

    public init(id: UUID = UUID(), kind: SuggestionKind, range: TimeRange, words: ClosedRange<Int>?,
                confidence: Double, reason: String, source: DecisionSource) {
        self.id = id
        self.kind = kind
        self.range = range
        self.words = words
        self.confidence = confidence
        self.reason = reason
        self.source = source
    }

    public static let enabledThreshold = 0.5
    public var isEnabledByDefault: Bool { confidence >= Self.enabledThreshold }
}

/// What auto-edit knows about a recording before any model is asked: the
/// transcript, the pauses (kinds from the rules), and the rules' suggestions.
public struct AutoEditInput: Codable, Sendable {
    public var transcript: Transcript
    public var pauses: [Pause]
    public var ruleSuggestions: [Suggestion]
    /// Length of the analyzed audio, seconds.
    public var duration: Double

    public init(transcript: Transcript, pauses: [Pause], ruleSuggestions: [Suggestion], duration: Double) {
        self.transcript = transcript
        self.pauses = pauses
        self.ruleSuggestions = ruleSuggestions
        self.duration = duration
    }
}

/// How a model pass went, for the review UI and the evaluation report.
public struct ModelPassReport: Codable, Sendable {
    public var provider: String
    public var model: String
    public var latency: Double
    public var usage: TokenUsage
    /// Answers the checks fixed or dropped (AI-6).
    public var warnings: [String]
    /// The answer as received, for debugging prompts.
    public var rawContent: String
    /// The first answer passed the checks (the evaluation's "valid answers").
    public var firstTryValid: Bool
    public var attempts: Int
}

/// Auto-edit's result: pauses with their kinds, and the suggested removals.
public struct AutoEditAnalysis: Codable, Sendable {
    public var transcript: Transcript
    public var pauses: [Pause]
    public var suggestions: [Suggestion]
    /// Set when a model pass ran (successfully or not).
    public var modelReport: ModelPassReport?

    public init(transcript: Transcript, pauses: [Pause], suggestions: [Suggestion], modelReport: ModelPassReport? = nil) {
        self.transcript = transcript
        self.pauses = pauses
        self.suggestions = suggestions
        self.modelReport = modelReport
    }

    /// The rules' judgment alone (no provider configured, AI-1).
    public init(rulesOnly input: AutoEditInput) {
        self.init(transcript: input.transcript, pauses: input.pauses, suggestions: input.ruleSuggestions)
    }
}
