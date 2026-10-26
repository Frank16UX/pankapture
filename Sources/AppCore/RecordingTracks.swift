import AVFoundation

/// Which recorded source an audio track carries (REC-4).
public enum AudioRole: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
}

/// How readers (the video editor, auto-edit) recognize the tracks the recorder
/// writes (`RecordingWriter.TrackName`, ADR-16, ADR-22, ADR-25).
public enum RecordingTracks {
    /// Title of the recorder's mixed track (system + mic), lowercased. Readers skip it.
    public static let mixName = "mix"
    /// Title of the recorder's webcam track, lowercased.
    public static let cameraName = "camera"

    /// Audio track roles from track names when present ("…mic…" / "…system…");
    /// otherwise by order (first = system, second = microphone, REC-4) with
    /// neutral labels, since the order is only a convention.
    public static func resolveRoles(names: [String?]) -> [(role: AudioRole, label: String)] {
        var result: [(role: AudioRole, label: String)?] = Array(repeating: nil, count: names.count)
        for (index, name) in names.enumerated() {
            guard let name = name?.lowercased() else { continue }
            if name.contains("mic") || name.contains("voice") {
                result[index] = (.microphone, "Microphone")
            } else if name.contains("system") {
                result[index] = (.system, "System Audio")
            }
        }
        var free = AudioRole.allCases.filter { role in !result.contains { $0?.role == role } }
        for index in result.indices where result[index] == nil {
            let role = free.isEmpty ? AudioRole.system : free.removeFirst()
            result[index] = (role, names.count == 1 ? "Audio" : "Audio \(index + 1)")
        }
        return result.map { $0 ?? (.system, "Audio") }
    }

    /// The track's title, if the file has one.
    public static func name(of track: AVAssetTrack) async -> String? {
        guard let items = try? await track.load(.metadata) else { return nil }
        let identifiers: Set<AVMetadataIdentifier> = [
            .quickTimeUserDataTrackName, .commonIdentifierTitle, .quickTimeMetadataDisplayName,
        ]
        for item in items {
            // MP4 stores the recorder's titles as ISO user data (`uiso/titl`),
            // which only matches by common key.
            guard item.commonKey == .commonKeyTitle || item.identifier.map(identifiers.contains) == true else { continue }
            if let value = try? await item.load(.stringValue), !value.isEmpty { return value }
        }
        return nil
    }
}
