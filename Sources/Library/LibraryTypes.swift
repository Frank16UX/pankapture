import Annotation
import AppCore
import CoreGraphics
import Foundation

/// What a library item holds.
public enum CaptureKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case screenshot
    case recording
    case gif

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .recording: "Recording"
        case .gif: "GIF"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .screenshot: "Screenshots"
        case .recording: "Recordings"
        case .gif: "GIFs"
        }
    }

    public var symbolName: String {
        switch self {
        case .screenshot: "photo"
        case .recording: "video"
        case .gif: "photo.stack"
        }
    }

    /// Recordings and GIFs live only at their exported location; screenshots keep
    /// an original inside the library so they stay re-editable (ED-3).
    public var isVideoLike: Bool { self != .screenshot }
}

/// Progress of on-device text recognition for an item (HI-3).
public enum OCRStatus: String, Codable, Sendable {
    case pending
    case done
    case failed
    /// Recordings and GIFs aren't text-indexed.
    case notApplicable
}

/// How long captures stay in the library (HI-5).
public enum HistoryRetention: String, CaseIterable, Sendable, Identifiable {
    case forever
    case days30
    case days90

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .forever: "Forever"
        case .days30: "30 Days"
        case .days90: "90 Days"
        }
    }

    public var days: Int? {
        switch self {
        case .forever: nil
        case .days30: 30
        case .days90: 90
        }
    }
}

/// History preferences, read from `UserDefaults` with their documented defaults
/// so the app doesn't need to register anything for the Library to behave.
public struct LibrarySettings: Equatable, Sendable {
    public var isEnabled: Bool
    public var keepsUnsavedCaptures: Bool
    public var retention: HistoryRetention
    /// 0 = no cap.
    public var storageCapGB: Double

    public init(
        isEnabled: Bool = true,
        keepsUnsavedCaptures: Bool = true,
        retention: HistoryRetention = .forever,
        storageCapGB: Double = 0
    ) {
        self.isEnabled = isEnabled
        self.keepsUnsavedCaptures = keepsUnsavedCaptures
        self.retention = retention
        self.storageCapGB = storageCapGB
    }

    public init(defaults: UserDefaults) {
        self.init(
            isEnabled: defaults.object(forKey: PreferenceKey.historyEnabled) as? Bool ?? true,
            keepsUnsavedCaptures: defaults.object(forKey: PreferenceKey.historyKeepsUnsavedCaptures) as? Bool ?? true,
            retention: defaults.string(forKey: PreferenceKey.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .forever,
            storageCapGB: defaults.double(forKey: PreferenceKey.historyStorageCapGB)
        )
    }

    /// Defaults for the history keys; safe to merge into the app's `register(defaults:)`.
    public static var registrationDefaults: [String: Any] {
        [
            PreferenceKey.historyEnabled: true,
            PreferenceKey.historyKeepsUnsavedCaptures: true,
            PreferenceKey.historyRetention: HistoryRetention.forever.rawValue,
            PreferenceKey.historyStorageCapGB: 0,
        ]
    }

    public var storageCapBytes: Int64? {
        storageCapGB > 0 ? Int64(storageCapGB * 1_000_000_000) : nil
    }
}

/// Read-only value copy of a library item. `@Model` objects never leave the
/// store actor; everything else in the app works with snapshots.
public struct CaptureSnapshot: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: CaptureKind
    public var createdAt: Date
    /// Last time annotations were re-edited (equals `createdAt` until then).
    public var editedAt: Date
    /// File name (or the generated name of an unsaved capture), searched (HI-3).
    public var title: String
    /// Name the user gave it in the library (HI-7); empty when not renamed.
    public var customName: String
    /// Sorted, case-insensitively unique (HI-8).
    public var tags: [String]
    /// The library folder it's in (HI-9), if any.
    public var folderID: UUID?
    public var pixelSize: CGSize
    /// Pixels per point of the original capture (screenshots).
    public var scale: CGFloat
    /// Seconds (recordings and GIFs).
    public var duration: TimeInterval?
    /// Where the user's file was saved, if anywhere.
    public var exportURL: URL?
    /// The exported file shows the latest annotations (false after a re-edit
    /// that wasn't saved again).
    public var isExportCurrent: Bool
    /// The exported file was moved to the Trash or deleted.
    public var isExportMissing: Bool
    /// Un-annotated original inside the library (screenshots).
    public var originalURL: URL?
    public var thumbnailURL: URL?
    public var annotationCount: Int
    /// Crop applied on top of the original, in capture-local points.
    public var cropRect: CGRect?
    public var ocrText: String
    public var ocrStatus: OCRStatus
    public var sourceAppName: String?
    /// Bytes this item uses inside the library folder (counts toward the cap).
    public var libraryByteSize: Int64
    /// Size of the user-facing file (export, or the original when unsaved).
    public var fileByteSize: Int64

    /// What the library shows: the user's name, else the file name.
    public var displayName: String { customName.isEmpty ? title : customName }

    /// `displayName` as a file name for Save As and drags (no extension).
    public var suggestedFileName: String {
        let base = customName.isEmpty ? (title as NSString).deletingPathExtension : customName
        return base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    /// A recording/GIF whose file is gone can't be opened at all.
    public var isUnavailable: Bool { kind.isVideoLike && (exportURL == nil || isExportMissing) }

    public var isReEditable: Bool {
        switch kind {
        case .screenshot: originalURL != nil
        case .recording: !isUnavailable
        case .gif: false
        }
    }

    /// The user's own file, when it exists and reflects the latest edit.
    public var currentUserFileURL: URL? {
        guard let exportURL, !isExportMissing else { return nil }
        return kind == .screenshot && !isExportCurrent ? nil : exportURL
    }
}

/// Lightweight entry for the menu bar's recent captures submenu (HI-6).
public struct RecentCapture: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var kind: CaptureKind
    public var title: String
    public var createdAt: Date
    public var thumbnailURL: URL?
    public var exportURL: URL?
    public var isUnavailable: Bool
}

/// Everything an editor needs to re-open a screenshot with live annotations (ED-3).
public struct LibraryScreenshot: Sendable {
    public let id: UUID
    /// Un-annotated original pixels.
    public let original: CGImage
    /// Pixels per point; annotations are in capture-local points.
    public let scale: CGFloat
    public let annotations: AnnotationDocument
    /// Crop applied on top of the original, in capture-local points.
    public let cropRect: CGRect?
    public let exportURL: URL?
    public let sourceAppName: String?
}

public enum LibrarySort: String, CaseIterable, Sendable, Identifiable {
    case newest
    case oldest
    case largest

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .largest: "Largest First"
        }
    }
}

/// Search/filter parameters for `CaptureLibrary.search`.
public struct LibraryQuery: Hashable, Sendable {
    public var text: String
    public var kind: CaptureKind?
    public var dateRange: Range<Date>?
    /// Only items in this library folder.
    public var folderID: UUID?
    /// Only items with this tag.
    public var tag: String?
    public var sort: LibrarySort
    public var limit: Int?

    public init(
        text: String = "",
        kind: CaptureKind? = nil,
        dateRange: Range<Date>? = nil,
        folderID: UUID? = nil,
        tag: String? = nil,
        sort: LibrarySort = .newest,
        limit: Int? = nil
    ) {
        self.text = text
        self.kind = kind
        self.dateRange = dateRange
        self.folderID = folderID
        self.tag = tag
        self.sort = sort
        self.limit = limit
    }
}

/// A folder in the library window (HI-9). It groups captures in the library
/// only; files on disk stay where they are.
public struct LibraryFolder: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var itemCount: Int

    /// Name for a new folder that doesn't clash with `existing`
    /// ("New Folder", "New Folder 2", …).
    public static func untitledName(existing: [String]) -> String {
        let base = "New Folder"
        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}

/// A tag and how many captures carry it (HI-8).
public struct LibraryTag: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var itemCount: Int

    /// Longest name kept for tags, folders, and capture names.
    public static let maxNameLength = 120

    /// `raw` trimmed, on one line, and capped; nil when nothing is left.
    /// Used for tag, folder, and capture names.
    public static func normalizedName(_ raw: String) -> String? {
        let oneLine = raw.components(separatedBy: .newlines).joined(separator: " ")
        let trimmed = oneLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Tags are unique ignoring case and accents ("Design" is "design").
    public static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
