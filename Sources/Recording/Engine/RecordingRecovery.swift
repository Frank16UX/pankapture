import AppCore
import AVFoundation
import Foundation

/// A recording left in the in-progress folder by a crash or power loss.
public struct PendingRecording: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var movieURL: URL
    /// `nil` if the manifest was lost; recovery then falls back to the current
    /// save folder and the file's creation date.
    public var manifest: RecordingManifest?
    public var fileSize: Int64
    /// When the recording started (manifest) or the file was created.
    public var date: Date
}

/// Finds and restores interrupted recordings (REC-9). Call `pending()` once at
/// launch, before any new recording starts, and offer to recover or discard.
///
/// Recordings are written as fragmented MP4 (a fragment every 2 s), so a file
/// cut off mid-write is still readable up to its last complete fragment.
/// Recovery remuxes it (passthrough, no re-encode) into a normal MP4 in the
/// save folder, writes a sidecar, and deletes the in-progress files.
public struct RecordingRecovery: Sendable {
    public var directory: URL
    public var fallbackDestination: @Sendable () -> URL
    public var namer: CaptureFileNamer
    /// Writes the sidecar for a recovered movie (injectable for tests).
    public var saveSidecar: @Sendable (RecordingSidecar, URL) throws -> Void

    public init(
        directory: URL = AppPaths.recordingsInProgress,
        namer: CaptureFileNamer = CaptureFileNamer(),
        fallbackDestination: @escaping @Sendable () -> URL = { Preferences.saveDirectory() },
        saveSidecar: @escaping @Sendable (RecordingSidecar, URL) throws -> Void = { try $0.save(for: $1) }
    ) {
        self.directory = directory
        self.namer = namer
        self.fallbackDestination = fallbackDestination
        self.saveSidecar = saveSidecar
    }

    /// Interrupted recordings, oldest first. `excluding` lets a caller skip a
    /// recording that's live right now (`ScreenRecorder.activeRecordingID`).
    public func pending(excluding activeIDs: Set<UUID> = []) -> [PendingRecording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [PendingRecording] = []
        for url in entries where url.pathExtension.lowercased() == "mp4" {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !activeIDs.contains(id) else { continue }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            let manifest = try? RecordingManifest.read(from: RecordingManifest.manifestURL(for: id, in: directory))
            result.append(PendingRecording(
                id: id,
                movieURL: url,
                manifest: manifest,
                fileSize: Int64(values?.fileSize ?? 0),
                date: manifest?.startDate ?? values?.creationDate ?? .distantPast
            ))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Manifests whose movie never got a single frame. Safe to delete at launch.
    public func orphanedManifests(excluding activeIDs: Set<UUID> = []) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension == "json",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !activeIDs.contains(id) else { return false }
            return !FileManager.default.fileExists(atPath: RecordingManifest.movieURL(for: id, in: directory).path)
        }
    }

    /// Restores `recording` into its destination folder and returns the new URL.
    @discardableResult
    public func recover(_ recording: PendingRecording) async throws -> URL {
        let source = AVURLAsset(url: recording.movieURL)
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            duration = try await source.load(.duration)
            videoTracks = try await source.loadTracks(withMediaType: .video)
        } catch {
            throw RecordingError.recoveryFailed(error.localizedDescription)
        }
        guard duration.seconds > 0, let videoTrack = videoTracks.first else {
            throw RecordingError.recoveryFailed("The file contains no video.")
        }

        let destinationDirectory = recording.manifest?.destinationDirectory ?? fallbackDestination()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = namer.uniqueURL(in: destinationDirectory, for: recording.date, fileExtension: "mp4")

        // Passthrough remux turns the fragmented file into a regular MP4 with a
        // complete index. If the exporter refuses the file, a plain move still
        // gives the user a playable (fragmented) movie.
        do {
            guard let export = AVAssetExportSession(asset: source, presetName: AVAssetExportPresetPassthrough) else {
                throw RecordingError.recoveryFailed("Export unavailable")
            }
            try await export.export(to: destination, as: .mp4)
        } catch {
            Log.recording.notice("Passthrough remux failed (\(error.localizedDescription, privacy: .public)); moving the fragmented file instead")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: recording.movieURL, to: destination)
        }

        do {
            try await AudioMixdown.addMixedTrack(to: destination)
        } catch {
            Log.recording.error("Audio mixdown failed; keeping separate tracks: \(error.localizedDescription, privacy: .public)")
        }

        // Verify before deleting anything else.
        let restored = AVURLAsset(url: destination)
        let restoredDuration = try await restored.load(.duration)
        guard restoredDuration.seconds > 0 else {
            throw RecordingError.recoveryFailed("The recovered file is empty.")
        }

        let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
        let sidecar = RecordingSidecar(videoSize: naturalSize, duration: restoredDuration.seconds, clicks: [])
        do { try saveSidecar(sidecar, destination) } catch {
            Log.recording.error("Sidecar save failed: \(error.localizedDescription, privacy: .public)")
        }

        discard(recording)
        Log.recording.info("Recovered \(destination.lastPathComponent, privacy: .public) (\(restoredDuration.seconds, format: .fixed(precision: 1)) s)")
        return destination
    }

    /// Deletes the in-progress movie and manifest.
    public func discard(_ recording: PendingRecording) {
        let fm = FileManager.default
        try? fm.removeItem(at: recording.movieURL)
        try? fm.removeItem(at: RecordingManifest.manifestURL(for: recording.id, in: directory))
    }

    public func removeOrphanedManifests() {
        for url in orphanedManifests() { try? FileManager.default.removeItem(at: url) }
    }
}
