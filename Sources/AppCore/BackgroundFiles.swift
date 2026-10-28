import Foundation

/// Private copies of pictures and movies used as backgrounds (image editor
/// ED-2, video editor VE-6), at `<Application Support>/Pankapture/Backgrounds/
/// <uuid>.<ext>`. Settings point at the copy, so they keep working if the
/// original moves.
public enum BackgroundFiles {
    public static var directory: URL {
        AppPaths.applicationSupport.appendingPathComponent("Backgrounds", isDirectory: true)
    }

    /// Copies `url` into the folder and returns the copy; a file already in
    /// the folder is returned as is.
    public static func copyIn(_ url: URL) throws -> URL {
        if url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {
            return url
        }
        try AppPaths.ensure(directory)
        let copy = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension.lowercased())
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}
