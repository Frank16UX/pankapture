import Foundation

/// Builds capture file names like `Pankapture 2026-10-19 at 14.27.05.png`
/// and avoids collisions by appending ` (2)`, ` (3)`, …
public struct CaptureFileNamer: Sendable {
    public var prefix: String
    public var timeZone: TimeZone

    public init(prefix: String = "Pankapture", timeZone: TimeZone = .current) {
        self.prefix = prefix
        self.timeZone = timeZone
    }

    public func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    public func uniqueURL(
        in directory: URL,
        for date: Date,
        fileExtension: String,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = baseName(for: date)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var counter = 2
        while fileExists(candidate) {
            candidate = directory
                .appendingPathComponent("\(base) (\(counter))")
                .appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }
}
