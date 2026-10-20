import AppCore
import Foundation

/// Saves edit projects as JSON at `<Application Support>/Pankapture/Edits/<video file name>.json`
/// so reopening the same recording restores its edits.
public struct ProjectStore: Sendable {
    public var directory: URL

    public static var defaultDirectory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Edits", isDirectory: true)
    }

    public init(directory: URL = ProjectStore.defaultDirectory) {
        self.directory = directory
    }

    public func location(for videoURL: URL) -> URL {
        directory.appendingPathComponent(videoURL.lastPathComponent).appendingPathExtension("json")
    }

    /// The saved project for `videoURL`, or `nil` if there's none, it doesn't
    /// decode, or it was made for a different file with the same name (the
    /// duration no longer matches).
    public func load(for videoURL: URL, sourceDuration: Double? = nil) -> VideoEditProject? {
        guard let data = try? Data(contentsOf: location(for: videoURL)),
              var project = try? JSONDecoder().decode(VideoEditProject.self, from: data) else { return nil }
        if let sourceDuration, abs(project.sourceDuration - sourceDuration) > 0.5 { return nil }
        project.sourceURL = videoURL
        return project
    }

    public func save(_ project: VideoEditProject) throws {
        try AppPaths.ensure(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: location(for: project.sourceURL), options: .atomic)
    }

    public func delete(for videoURL: URL) {
        try? FileManager.default.removeItem(at: location(for: videoURL))
    }
}
