import AppCore
import Foundation
import Synchronization

/// Where exports go: the user's save folder, named like every other capture.
public enum ExportDestination {
    public static func newFileURL(for format: ExportFormat, date: Date = Date(), defaults: UserDefaults = .standard) throws -> URL {
        let directory = try AppPaths.ensure(Preferences.saveDirectory(in: defaults))
        return CaptureFileNamer().uniqueURL(in: directory, for: date, fileExtension: format.fileExtension)
    }
}

/// A thread-safe "stop" flag for synchronous loops running off the main actor.
final class CancellationFlag: Sendable {
    private let state = Mutex(false)

    var isSet: Bool { state.withLock { $0 } }

    func set() {
        state.withLock { $0 = true }
    }
}
