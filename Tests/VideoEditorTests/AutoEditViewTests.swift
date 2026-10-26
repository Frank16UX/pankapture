import AppCore
import AppKit
import AutoEdit
import Foundation
import SwiftUI
import Testing
import Transcription
@testable import VideoEditor

/// Renders the auto-edit inspector and timeline lane offscreen with a loaded
/// recording, so the views are exercised without a window on screen. Set
/// `PK_SNAPSHOT_DIR` to also write the images there for a look.
@MainActor
@Suite("Auto-edit views")
struct AutoEditViewTests {
    @Test func inspectorAndTimelineRender() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 20, audioAmplitudes: [0, 0.3]), in: directory)
        let model = VideoEditorModel(url: movie, store: ProjectStore(directory: directory.appendingPathComponent("Edits")))
        await model.load()
        #expect(model.media != nil)

        let filler = Suggestion(kind: .filler, range: TimeRange(start: 5, end: 5.4), words: 9...9, confidence: 0.95,
                                reason: "Filler word “um”", source: .rules)
        let retake = Suggestion(kind: .retake, range: TimeRange(start: 12, end: 14), words: 20...24, confidence: 0.8,
                                reason: "Corrected: “April.” → “May.”", source: .model)
        let layer = AutoEditLayer(
            language: .english,
            pauses: [
                .init(pause: Pause(id: 0, range: TimeRange(start: 2, end: 4.5), afterWord: 4, kind: .section, kindSource: .model)),
                .init(pause: Pause(id: 1, range: TimeRange(start: 8, end: 9), afterWord: 15, kind: .hesitation)),
                .init(pause: Pause(id: 2, range: TimeRange(start: 16, end: 18), afterWord: 30, activity: ScreenActivity(clicks: 2), kind: .action)),
            ],
            removals: [
                AutoEditLayer.Removal(suggestion: filler, text: "um", isEnabled: true),
                AutoEditLayer.Removal(suggestion: retake, text: "April. Wait, sorry, I meant", isEnabled: true),
            ],
            judgedBy: "LM Studio qwen3.5-9b"
        )
        model.edit { $0.autoEdit = layer }
        model.selectedAutoItem = .removal(retake.id)
        #expect(model.project.effectiveCuts.count == 4)
        #expect(model.outputDuration < 20)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let inspector = try render(InspectorView(model: model), size: CGSize(width: 300, height: 1100),
                                       appearance: appearance, name: "inspector")
            #expect(Self.distinctColors(inspector) > 20)
            let timeline = try render(TimelineView(model: model).padding(16), size: CGSize(width: 900, height: 260),
                                      appearance: appearance, name: "timeline")
            #expect(Self.distinctColors(timeline) > 20)
        }
        model.close()
    }

    @Test func cutEdgesStopAtTheNeighbouringCut() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 20), in: directory)
        let model = VideoEditorModel(url: movie, store: ProjectStore(directory: directory.appendingPathComponent("Edits")))
        await model.load()
        let first = TimeRange(start: 10, end: 12)
        let second = TimeRange(start: 13, end: 15)
        model.edit { $0.cuts = [first, second] }
        model.selectedCut = first
        model.moveCutEdge(first, start: false, to: 14)
        #expect(model.project.cuts.count == 2)
        #expect(abs((model.project.cuts.first?.end ?? 0) - 12.98) < 1e-9)
        #expect(model.project.cuts.last == second)
        #expect(model.selectedCut == model.project.cuts.first)

        // Selecting a cut deselects auto-edit's item, so ⌫ acts on the cut.
        model.selectedAutoItem = .pause(0)
        model.selectedCut = second
        #expect(model.selectedAutoItem == nil)
        model.close()
    }

    @Test func transcriptEditing() async throws {
        let directory = try TestMovie.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestMovie.make(TestMovie.Spec(duration: 10), in: directory)
        let model = VideoEditorModel(url: movie, store: ProjectStore(directory: directory.appendingPathComponent("Edits")))
        await model.load()
        let words = ["Hello", "everyone.", "The", "numbers", "for", "April.", "Wait,", "sorry,", "I", "meant", "May."]
            .enumerated().map { TranscriptWord(text: $1, start: Double($0) * 0.6 + 0.5, end: Double($0) * 0.6 + 0.9) }
        model.edit { $0.transcript = Transcript(language: .english, localeIdentifier: "en-US", engine: Transcript.onDeviceEngine, words: words) }

        #expect(model.wordIndex(atSource: 0.2) == nil)
        #expect(model.wordIndex(atSource: 3.6) == 5)
        #expect(model.wordStates().allSatisfy { $0 == .kept })

        // Cutting "April. … meant" removes them; cutting again restores them.
        model.cutWords(5...9)
        #expect(model.project.cuts.count == 1)
        #expect(model.wordStates()[5...9].allSatisfy { $0 == .cut })
        #expect(model.wordStates()[10] == .kept)
        model.cutWords(5...9)
        #expect(model.project.cuts.isEmpty)

        // Corrections keep the span and share it out by length.
        model.correctWords(0...1, to: "Hi there, everybody.")
        let corrected = try #require(model.transcript?.words)
        #expect(corrected.prefix(3).map(\.text) == ["Hi", "there,", "everybody."])
        #expect(corrected.count == words.count + 1)
        #expect(corrected[0].start == words[0].start)
        #expect(abs(corrected[2].end - words[1].end) < 1e-9)
        model.undo()
        #expect(model.transcript?.words == words)

        model.transcriptSelection = 2...3
        let panel = try render(TranscriptPanel(model: model), size: CGSize(width: 340, height: 420), appearance: .aqua, name: "transcript")
        #expect(Self.distinctColors(panel) > 3)
        model.close()
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance.Name, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI apply state and the filmstrip load.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["PK_SNAPSHOT_DIR"],
           let png = rep.representation(using: .png, properties: [:]) {
            let suffix = appearance == .darkAqua ? "dark" : "light"
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("auto-edit-\(name)-\(suffix).png"))
        }
        return rep
    }

    /// A blank render has one or two colors; a real one has many.
    private static func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = UInt32(color.redComponent * 255), g = UInt32(color.greenComponent * 255), b = UInt32(color.blueComponent * 255)
                colors.insert(r << 16 | g << 8 | b)
                if colors.count > 64 { return colors.count }
            }
        }
        return colors.count
    }
}
