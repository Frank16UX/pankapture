import AppCore
import Foundation

/// One line of a sample's `labels.tsv` (PRD §11.3).
struct Label: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case retake
        case falseStart = "false_start"
        case `repeat`
        case sectionPause = "section_pause"
        case emphasisPause = "emphasis_pause"
        case actionPause = "action_pause"

        /// The labeled part should be removed.
        var isRemoval: Bool { self == .retake || self == .falseStart || self == .repeat }
        /// The labeled part is a deliberate pause.
        var isPause: Bool { !isRemoval }
    }

    var range: TimeRange
    var kind: Kind
    var note: String
    /// The note holds "?": reported, not scored.
    var isUnsure: Bool { note.contains("?") }
}

enum LabelParser {
    struct ParseError: LocalizedError {
        var line: Int
        var message: String
        var errorDescription: String? { "line \(line): \(message)" }
    }

    /// Tab-separated `start  end  kind  note`, times as `m:ss.s`. A header
    /// row, blank lines, and `#` comments are skipped.
    static func parse(_ text: String) throws -> [Label] {
        var labels: [Label] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.lowercased().hasPrefix("start") { continue }
            let fields = rawLine.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3 else {
                throw ParseError(line: offset + 1, message: "expected start, end, and kind separated by tabs")
            }
            guard let start = time(fields[0]), let end = time(fields[1]) else {
                throw ParseError(line: offset + 1, message: "times must look like 1:02.5")
            }
            guard end > start else { throw ParseError(line: offset + 1, message: "end must be after start") }
            guard let kind = Label.Kind(rawValue: fields[2].lowercased()) else {
                let kinds = Label.Kind.allCases.map(\.rawValue).joined(separator: ", ")
                throw ParseError(line: offset + 1, message: "unknown kind “\(fields[2])” (use \(kinds))")
            }
            let note = fields.count > 3 ? fields[3...].joined(separator: " ") : ""
            labels.append(Label(range: TimeRange(start: start, end: end), kind: kind, note: note))
        }
        return labels.sorted { $0.range.start < $1.range.start }
    }

    /// "1:02.5", "0:01:02.5", or plain seconds "62.5".
    static func time(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            if index < parts.count - 1, value != value.rounded() { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((seconds * 10).rounded())
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
