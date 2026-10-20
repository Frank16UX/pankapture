import Foundation

public enum VideoEditorError: LocalizedError, Sendable, Equatable {
    case noVideoTrack
    case emptyTimeline
    case compositionFailed(String)
    case exportFailed(String)
    case cancelled
    case unsupportedBackground

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file doesn't contain a video track."
        case .emptyTimeline: "Nothing is left to export after trimming and cutting."
        case let .compositionFailed(detail): "Couldn't prepare the video (\(detail))."
        case let .exportFailed(detail): "Export failed: \(detail)"
        case .cancelled: "Export was cancelled."
        case .unsupportedBackground: "Choose a picture or a movie file for the background."
        }
    }
}
