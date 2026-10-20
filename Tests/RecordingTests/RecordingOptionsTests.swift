import AppCore
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Recording

@Suite("RecordingOptions")
struct RecordingOptionsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "pankapture.tests.\(UUID().uuidString)")!
    }

    @Test func freshDefaultsLoadBuiltInValues() {
        #expect(RecordingOptions.load(from: makeDefaults()) == RecordingOptions())
    }

    @Test func registeredDefaultsMatchBuiltInValues() {
        let defaults = makeDefaults()
        Preferences.registerDefaults(in: defaults)
        #expect(RecordingOptions.load(from: defaults) == RecordingOptions())
    }

    @Test func roundTripsEveryField() {
        let defaults = makeDefaults()
        var options = RecordingOptions()
        options.capturesSystemAudio = false
        options.capturesMicrophone = true
        options.microphoneDeviceID = "mic-1"
        options.showsCamera = true
        options.cameraDeviceID = "cam-9"
        options.cameraShape = .roundedRectangle
        options.cameraMirrored = false
        options.cameraSize = 320
        options.framesPerSecond = 30
        options.codec = .hevc
        options.quality = .high
        options.countdown = 5
        options.showsCursor = false
        options.highlightsClicks = true
        options.clickColor = .blue
        options.clickSize = 60
        options.showsKeystrokes = true
        options.keystrokesShowAllKeys = true
        options.hidesDesktopIcons = true
        options.outputKind = .gif
        options.save(to: defaults)

        #expect(RecordingOptions.load(from: defaults) == options)
        #expect(defaults.string(forKey: PreferenceKey.recordingCodec) == "hevc")
    }

    @Test func nilDeviceIsStoredAsEmptyStringAndLoadsAsNil() {
        let defaults = makeDefaults()
        var options = RecordingOptions()
        options.microphoneDeviceID = nil
        options.save(to: defaults)
        #expect(defaults.string(forKey: PreferenceKey.recordingMicrophoneDeviceID) == "")
        #expect(RecordingOptions.load(from: defaults).microphoneDeviceID == nil)
    }

    @Test func invalidStoredValuesFallBack() {
        let defaults = makeDefaults()
        defaults.set("vp9", forKey: PreferenceKey.recordingCodec)
        defaults.set(10_000.0, forKey: PreferenceKey.recordingCameraSize)
        let options = RecordingOptions.load(from: defaults)
        #expect(options.codec == .h264)
        #expect(options.cameraSize == RecordingOptions.cameraSizeRange.upperBound)
    }

    @Test func configurationCarriesOptionsAndOverlays() {
        var options = RecordingOptions()
        options.capturesMicrophone = true
        options.microphoneDeviceID = "mic"
        options.framesPerSecond = 30
        options.countdown = 0
        options.hidesDesktopIcons = true
        let config = options.makeConfiguration(source: .display(7), overlayWindowIDs: [11, 12])
        #expect(config.source == .display(7))
        #expect(config.capturesMicrophone && config.capturesSystemAudio)
        #expect(config.microphoneDeviceID == "mic")
        #expect(config.framesPerSecond == 30)
        #expect(config.countdown == 0)
        #expect(config.hidesDesktopIcons)
        #expect(config.includedOverlayWindowIDs == [11, 12])
    }

    @Test func gifModeDropsAudio() {
        var options = RecordingOptions()
        options.capturesMicrophone = true
        options.outputKind = .gif
        let config = options.makeConfiguration(source: .window(3))
        #expect(!config.capturesSystemAudio && !config.capturesMicrophone)
    }

    @Test func outOfRangeValuesAreSanitized() {
        var options = RecordingOptions()
        options.framesPerSecond = 24
        options.countdown = 7
        let config = options.makeConfiguration(source: .display(1))
        #expect(config.framesPerSecond == 60)
        #expect(config.countdown == 0)
    }
}

@Suite("RecordingManifest")
struct RecordingManifestTests {
    @Test func encodesAndDecodesEverySourceKind() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pk-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sources: [RecordingConfiguration.Source] = [
            .display(69_733_248),
            .window(4242),
            .area(displayID: 2, rect: CGRect(x: 10.5, y: 20, width: 640, height: 360)),
        ]
        for source in sources {
            let manifest = RecordingManifest(
                startDate: Date(timeIntervalSince1970: 1_792_419_225),
                configuration: RecordingConfiguration(
                    source: source, framesPerSecond: 30, codec: .hevc, quality: .low,
                    capturesSystemAudio: false, capturesMicrophone: true, microphoneDeviceID: "mic",
                    showsCursor: false, hidesDesktopIcons: true, countdown: 5, includedOverlayWindowIDs: [9]
                ),
                destinationDirectory: URL(fileURLWithPath: "/tmp/Saved", isDirectory: true)
            )
            try manifest.write(in: directory)
            let read = try RecordingManifest.read(from: RecordingManifest.manifestURL(for: manifest.id, in: directory))
            #expect(read == manifest)
        }
    }
}

@Suite("RecordingRecovery discovery")
struct RecordingRecoveryDiscoveryTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pk-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func emptyOrMissingDirectoryHasNothingPending() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("pk-none-\(UUID().uuidString)")
        #expect(RecordingRecovery(directory: missing).pending().isEmpty)
        let empty = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(RecordingRecovery(directory: empty).pending().isEmpty)
    }

    @Test func findsMoviesWithAndWithoutManifestsOldestFirst() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let newer = RecordingManifest(
            startDate: Date(timeIntervalSince1970: 2_000),
            configuration: RecordingConfiguration(source: .display(1)),
            destinationDirectory: directory
        )
        let older = RecordingManifest(
            startDate: Date(timeIntervalSince1970: 1_000),
            configuration: RecordingConfiguration(source: .window(2)),
            destinationDirectory: directory
        )
        for manifest in [newer, older] {
            try manifest.write(in: directory)
            try Data([0, 1, 2]).write(to: RecordingManifest.movieURL(for: manifest.id, in: directory))
        }
        let orphanMovie = UUID()
        try Data([0]).write(to: RecordingManifest.movieURL(for: orphanMovie, in: directory))
        // Unrelated files are ignored.
        try Data().write(to: directory.appendingPathComponent("notes.txt"))
        try Data().write(to: directory.appendingPathComponent("not-a-uuid.mp4"))

        let recovery = RecordingRecovery(directory: directory)
        let pending = recovery.pending()
        #expect(pending.count == 3)
        // The orphan has no manifest, so it's dated by file creation (now): newest.
        #expect(pending.map(\.id) == [older.id, newer.id, orphanMovie])
        #expect(pending.first { $0.id == older.id }?.manifest == older)
        #expect(pending.first { $0.id == orphanMovie }?.manifest == nil)
        #expect(pending.first { $0.id == newer.id }?.fileSize == 3)

        // The live recording is skipped.
        #expect(recovery.pending(excluding: [newer.id]).count == 2)
    }

    @Test func discardRemovesMovieAndManifest() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = RecordingManifest(configuration: RecordingConfiguration(source: .display(1)), destinationDirectory: directory)
        try manifest.write(in: directory)
        try Data([1]).write(to: RecordingManifest.movieURL(for: manifest.id, in: directory))

        let recovery = RecordingRecovery(directory: directory)
        recovery.discard(try #require(recovery.pending().first))
        #expect(recovery.pending().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: RecordingManifest.manifestURL(for: manifest.id, in: directory).path))
    }

    @Test func manifestsWithoutMoviesAreOrphans() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = RecordingManifest(configuration: RecordingConfiguration(source: .display(1)), destinationDirectory: directory)
        try manifest.write(in: directory)

        let recovery = RecordingRecovery(directory: directory)
        #expect(recovery.pending().isEmpty)
        #expect(recovery.orphanedManifests().count == 1)
        #expect(recovery.orphanedManifests(excluding: [manifest.id]).isEmpty)
        recovery.removeOrphanedManifests()
        #expect(recovery.orphanedManifests().isEmpty)
    }

    @Test func recoveringGarbageFailsWithoutDeletingIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = RecordingManifest(configuration: RecordingConfiguration(source: .display(1)), destinationDirectory: directory)
        try manifest.write(in: directory)
        try Data(repeating: 7, count: 64).write(to: RecordingManifest.movieURL(for: manifest.id, in: directory))

        let recovery = RecordingRecovery(directory: directory, saveSidecar: { _, _ in })
        let pending = try #require(recovery.pending().first)
        await #expect(throws: RecordingError.self) { try await recovery.recover(pending) }
        #expect(recovery.pending().count == 1)
    }
}

@Suite("KeystrokeFormatter")
struct KeystrokeFormatterTests {
    @Test func shortcutsAlwaysShow() {
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_C), modifiers: [.command], characters: "c", showAllKeys: false) == .combo("⌘C"))
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_4), modifiers: [.command, .shift], characters: "$", showAllKeys: false) == .combo("⇧⌘4"))
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_Tab), modifiers: [.control], characters: "\t", showAllKeys: false) == .combo("⌃⇥"))
    }

    @Test func plainKeysHiddenUnlessAllKeys() {
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_A), modifiers: [], characters: "a", showAllKeys: false) == nil)
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift], characters: "A", showAllKeys: false) == nil)
    }

    @Test func allKeysTypesCharactersAndNamesSpecialKeys() {
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift], characters: "A", showAllKeys: true) == .typed("A"))
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_Space), modifiers: [], characters: " ", showAllKeys: true) == .typed(" "))
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_Return), modifiers: [], characters: "\r", showAllKeys: true) == .combo("↩"))
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_LeftArrow), modifiers: [.shift], characters: "\u{F702}", showAllKeys: true) == .combo("⇧←"))
    }

    @Test func unknownKeysFallBackToTheirCharacter() {
        #expect(KeystrokeFormatter.entry(keyCode: UInt16(kVK_ANSI_Slash), modifiers: [.command], characters: "/", showAllKeys: false) == .combo("⌘/"))
    }
}

@Suite("RecordingHUD")
struct RecordingHUDTests {
    @Test func timerFormat() {
        #expect(RecordingHUD.format(0) == "0:00")
        #expect(RecordingHUD.format(65.9) == "1:05")
        #expect(RecordingHUD.format(3_725) == "1:02:05")
    }
}
