import AppCore
import Foundation

/// The languages smart editing transcribes (PRD AE-1).
public enum TranscriptLanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case spanish = "es"

    public var id: String { rawValue }

    /// The language's name in that language, for pickers.
    public var title: String {
        switch self {
        case .english: "English"
        case .spanish: "Español"
        }
    }

    /// The English name, for prompts and reports.
    public var englishName: String {
        switch self {
        case .english: "English"
        case .spanish: "Spanish"
        }
    }

    /// The language of `locale`, if it's one we transcribe.
    public init?(locale: Locale) {
        guard let code = locale.language.languageCode?.identifier,
              let language = TranscriptLanguage(rawValue: code) else { return nil }
        self = language
    }

    /// The system language when it's supported, otherwise English.
    public static var preferred: TranscriptLanguage {
        Locale.preferredLanguages.lazy.compactMap { TranscriptLanguage(locale: Locale(identifier: $0)) }.first ?? .english
    }
}

/// One recognized word, timed in **source** seconds of the recording.
public struct TranscriptWord: Codable, Hashable, Sendable {
    /// As recognized, with attached punctuation ("April.", "wait,").
    public var text: String
    public var start: Double
    public var end: Double
    /// Recognizer confidence 0…1, when it reported one.
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, confidence: Double? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    public var range: TimeRange { TimeRange(start: start, end: end) }

    /// Lowercased, without surrounding punctuation ("April." → "april",
    /// "¿Qué?" → "qué"). Apostrophes and accents stay.
    public var bare: String { Self.bare(text) }

    /// Ends a sentence: `.`, `?`, `!`, `…` (closing quotes allowed after it).
    public var endsSentence: Bool {
        let trimmed = text.trimmingCharacters(in: Self.closers)
        guard let last = trimmed.last else { return false }
        return Self.sentenceEnders.contains(last)
    }

    /// Ends a clause: `,`, `;`, `:`, or a dash, without ending the sentence.
    public var endsClause: Bool {
        guard !endsSentence else { return false }
        let trimmed = text.trimmingCharacters(in: Self.closers)
        guard let last = trimmed.last else { return false }
        return Self.clauseEnders.contains(last)
    }

    public static func bare(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: Self.punctuation)
    }

    private static let sentenceEnders: Set<Character> = [".", "?", "!", "…"]
    private static let clauseEnders: Set<Character> = [",", ";", ":", "—", "–", "-"]
    private static let closers = CharacterSet(charactersIn: "\"'”’»)]")
    private static let punctuation = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        .subtracting(CharacterSet(charactersIn: "'’"))
}

/// A recording's microphone track as words with timings (PRD AE-1). The basis
/// for auto-edit and captions.
public struct Transcript: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var language: TranscriptLanguage
    /// The recognizer locale, e.g. "en-US" or "es-MX".
    public var localeIdentifier: String
    /// Which engine produced it ("SpeechTranscriber", or a cloud provider).
    public var engine: String
    public var words: [TranscriptWord]

    public init(language: TranscriptLanguage, localeIdentifier: String, engine: String, words: [TranscriptWord]) {
        self.version = Self.currentVersion
        self.language = language
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.words = words
    }

    public var text: String { words.map(\.text).joined(separator: " ") }

    /// From the first word's start to the last word's end.
    public var spokenRange: TimeRange? {
        guard let first = words.first, let last = words.last else { return nil }
        return TimeRange(start: first.start, end: last.end)
    }

    /// The words in `range`, as text.
    public func text(of range: ClosedRange<Int>) -> String {
        guard !words.isEmpty else { return "" }
        return words[range.clamped(to: 0...(words.count - 1))].map(\.text).joined(separator: " ")
    }

    public static func load(from url: URL) throws -> Transcript {
        try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
