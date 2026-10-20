import AppCore
import Foundation

/// Saves edit projects as JSON at `<Application Support>/Pankapture/Edits/<video file name>.json`
/// so reopening the same recording restores its edits (VE-12).
///
/// The project file changes only when the user saves. Unsaved edits are
/// autosaved to `<video file name>.draft.json`, so a crash doesn't lose
/// them; reopening the recording offers them as unsaved changes.
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

    public func draftLocation(for videoURL: URL) -> URL {
        directory.appendingPathComponent(videoURL.lastPathComponent).appendingPathExtension("draft.json")
    }

    /// The saved project for `videoURL`, or `nil` if there's none, it doesn't
    /// decode, or it was made for a different file with the same name (the
    /// duration no longer matches).
    public func load(for videoURL: URL, sourceDuration: Double? = nil) -> VideoEditProject? {
        decode(at: location(for: videoURL), videoURL: videoURL, sourceDuration: sourceDuration)
    }

    /// Unsaved edits left by a crash (or a window closed without deciding).
    public func loadDraft(for videoURL: URL, sourceDuration: Double? = nil) -> VideoEditProject? {
        decode(at: draftLocation(for: videoURL), videoURL: videoURL, sourceDuration: sourceDuration)
    }

    private func decode(at location: URL, videoURL: URL, sourceDuration: Double?) -> VideoEditProject? {
        guard let data = try? Data(contentsOf: location),
              var project = try? JSONDecoder().decode(VideoEditProject.self, from: data) else { return nil }
        if let sourceDuration, abs(project.sourceDuration - sourceDuration) > 0.5 { return nil }
        project.sourceURL = videoURL
        return project
    }

    public func save(_ project: VideoEditProject) throws {
        try write(project, to: location(for: project.sourceURL))
    }

    public func saveDraft(_ project: VideoEditProject) throws {
        try write(project, to: draftLocation(for: project.sourceURL))
    }

    private func write(_ project: VideoEditProject, to url: URL) throws {
        try AppPaths.ensure(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    public func delete(for videoURL: URL) {
        try? FileManager.default.removeItem(at: location(for: videoURL))
    }

    public func deleteDraft(for videoURL: URL) {
        try? FileManager.default.removeItem(at: draftLocation(for: videoURL))
    }
}
