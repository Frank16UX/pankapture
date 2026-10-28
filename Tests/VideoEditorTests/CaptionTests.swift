import AppCore
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
import Transcription
@testable import VideoEditor

/// Words 0.4 s long, 0.1 s apart, starting at 1 s; `|1.0` adds a pause.
private func words(_ script: String) -> [TranscriptWord] {
    var result: [TranscriptWord] = []
    var time = 1.0
    for token in script.split(separator: " ") {
        if token.hasPrefix("|"), let pause = Double(token.dropFirst()) {
            time += pause
            continue
        }
        result.append(TranscriptWord(text: String(token), start: time, end: time + 0.4))
        time += 0.5
    }
    return result
}

@Suite("Captions")
struct CaptionTests {
    @Test func cuesBreakAtSentencesAndPauses() {
        let cues = CaptionBuilder.cues(words: words("Hello everyone. This is the settings page |1.0 and here is the menu."),
                                       timeline: Timeline(sourceDuration: 20))
        #expect(cues.map(\.text) == ["Hello everyone.", "This is the settings page", "and here is the menu."])
        #expect(cues[0].output.start == 1.0)
        // Every cue stays up at least 0.8 s, and never into the next one.
        #expect(cues.allSatisfy { $0.output.duration >= 0.8 - 1e-9 })
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.output.end <= $1.output.start })
    }

    @Test func removedWordsDisappearAndCutsSplitCues() {
        // "Wait sorry" (words 2–3) is cut: the cue splits and skips them.
        let script = words("the numbers wait sorry for May")
        let timeline = Timeline(sourceDuration: 20, cuts: [TimeRange(start: script[2].start, end: script[4].start)])
        let cues = CaptionBuilder.cues(words: script, timeline: timeline)
        #expect(cues.map(\.text) == ["the numbers", "for May"])
        // Output time: everything after the cut moved 1 s earlier.
        #expect(abs(cues[1].output.start - (script[4].start - 1.0)) < 1e-9)
    }

    @Test func closeCuesNeverOverlap() {
        // Two sentences 0.05 s apart (fast speech, or a 4× speed-up): the
        // 0.1 s floor mustn't push the first into the second.
        let script = [TranscriptWord(text: "Hi.", start: 1.0, end: 1.02), TranscriptWord(text: "Yes.", start: 1.05, end: 1.07)]
        let cues = CaptionBuilder.cues(words: script, timeline: Timeline(sourceDuration: 5))
        #expect(cues.count == 2)
        #expect(cues[0].output.end <= cues[1].output.start)
        #expect(CaptionTrack(cues: cues, style: .box, position: .bottom, size: .medium).cue(at: 1.06)?.text == "Yes.")
    }

    @Test func portraitCaptionsFitTheirBitmap() throws {
        // A full-width line at the large size, on a portrait canvas: the font
        // shrinks so no glyph is cut at the bitmap's edges.
        let line = String(repeating: "W", count: 32)
        let image = try #require(CaptionRasterizer.rasterize(lines: [line], style: .outline, size: .large,
                                                             canvas: CGSize(width: 1080, height: 1920)))
        #expect(CGFloat(image.width) <= (1080 * 0.92).rounded(.up))
        let bytes = try #require(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow
        let edgeAlpha = (0..<image.height).reduce(0) { sum, y in
            sum + Int(bytes[y * row + 3]) + Int(bytes[y * row + (image.width - 1) * 4 + 3])
        }
        #expect(edgeAlpha == 0)
    }

    @Test func longCuesWrapIntoTwoBalancedLines() {
        let lines = CaptionBuilder.wrap("Today we will look at the numbers for the second quarter".split(separator: " ").map(String.init),
                                        maxLineLength: 42)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.count <= 42 })
        #expect(abs(lines[0].count - lines[1].count) <= 10)
        #expect(CaptionBuilder.wrap(["Short", "line."], maxLineLength: 42) == ["Short line."])
    }

    @Test func cuesStayUnderTwoLines() {
        let long = words(Array(repeating: "information", count: 30).joined(separator: " "))
        let cues = CaptionBuilder.cues(words: long, timeline: Timeline(sourceDuration: 40))
        #expect(cues.count > 3)
        #expect(cues.allSatisfy { $0.lines.count <= 2 && $0.output.duration <= CaptionBuilder.maximumDuration + 0.3 })
    }

    @Test func srtAndVTT() {
        let cues = [CaptionCue(output: TimeRange(start: 1.5, end: 3.25), lines: ["Hello", "there"]),
                    CaptionCue(output: TimeRange(start: 3661.001, end: 3662), lines: ["Bye."])]
        #expect(CaptionBuilder.srt(cues) == "1\n00:00:01,500 --> 00:00:03,250\nHello\nthere\n\n2\n01:01:01,001 --> 01:01:02,000\nBye.\n")
        #expect(CaptionBuilder.vtt(cues).hasPrefix("WEBVTT\n\n00:00:01.500 --> 00:00:03.250\nHello\nthere\n"))
    }

    @Test func trackFindsTheCueOnScreen() {
        let track = CaptionTrack(cues: [CaptionCue(output: TimeRange(start: 1, end: 2), lines: ["a"]),
                                        CaptionCue(output: TimeRange(start: 3, end: 4), lines: ["b"])],
                                 style: .box, position: .bottom, size: .medium)
        #expect(track.cue(at: 1.5)?.text == "a")
        #expect(track.cue(at: 2.5) == nil)
        #expect(track.cue(at: 3)?.text == "b")
        #expect(track.cue(at: 4) == nil)
    }

    @Test func planDrawsCaptionsOnlyWhenOnWithATranscript() {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 20)
        project.transcript = Transcript(language: .english, localeIdentifier: "en-US", engine: "test", words: words("Hello there."))
        #expect(RenderPlan(project: project, sourceSize: CGSize(width: 1920, height: 1080)).captions == nil)
        project.captions = CaptionSettings()
        let plan = RenderPlan(project: project, sourceSize: CGSize(width: 1920, height: 1080))
        #expect(plan.captions?.cues.count == 1)
        #expect(plan.needsCustomCompositor)
        #expect(!project.isUnedited)
    }

    @Test func rasterizesEveryStyle() throws {
        for style in CaptionSettings.Style.allCases {
            let image = try #require(CaptionRasterizer.rasterize(lines: ["Hello there", "second line"], style: style, size: .medium,
                                                                 canvas: CGSize(width: 1920, height: 1080)))
            #expect(image.width > 200 && image.width < 1920)
            #expect(image.height > 100)
        }
        let track = CaptionTrack(cues: [], style: .box, position: .top, size: .large)
        let placed = try #require(CaptionRasterizer.shared.image(for: CaptionCue(output: TimeRange(start: 0, end: 1), lines: ["Top"]),
                                                                track: track, canvas: CGSize(width: 1280, height: 720)))
        #expect(placed.extent.maxY < 720 && placed.extent.minY > 360)
    }

    @Test func framesShowTheCaption() throws {
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 20)
        project.transcript = Transcript(language: .english, localeIdentifier: "en-US", engine: "test",
                                        words: words("Here are the numbers for May, right on target."))
        for style in CaptionSettings.Style.allCases {
            project.captions = CaptionSettings(style: style)
            let plan = RenderPlan(project: project, sourceSize: CGSize(width: 1280, height: 720))
            let track = try #require(plan.captions)
            let cue = try #require(track.cue(at: 2))
            let caption = CaptionRasterizer.shared.image(for: cue, track: track, canvas: plan.renderSize)
            let source = CIImage(color: CIColor(red: 0.2, green: 0.45, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
            let frame = FrameRenderer(plan: plan).render(source: source, outputTime: 2, caption: caption)
            let context = CIContext()
            let image = try #require(context.createCGImage(frame, from: frame.extent))
            // The caption area differs from the plain blue above it.
            let bytes = try #require(image.dataProvider?.data as Data?)
            let row = image.bytesPerRow
            let captionPixel = bytes[(image.height - 60) * row + (image.width / 2) * 4]
            let plainPixel = bytes[(image.height / 2) * row + (image.width / 2) * 4]
            if style != .outline { #expect(captionPixel != plainPixel) }
            if let folder = ProcessInfo.processInfo.environment["PK_SNAPSHOT_DIR"],
               let destination = CGImageDestinationCreateWithURL(
                   URL(fileURLWithPath: folder).appendingPathComponent("caption-\(style.rawValue).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    @Test func captionsFileBesideTheExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = VideoEditProject(sourceURL: URL(fileURLWithPath: "/tmp/x.mp4"), sourceDuration: 20)
        project.transcript = Transcript(language: .english, localeIdentifier: "en-US", engine: "test", words: words("Hello there."))
        project.captions = CaptionSettings(fileFormat: .srt)
        let video = directory.appendingPathComponent("Export.mp4")
        VideoEditorModel.writeCaptionsFile(for: project, nextTo: video)
        let srt = try String(contentsOf: directory.appendingPathComponent("Export.srt"), encoding: .utf8)
        #expect(srt.hasPrefix("1\n00:00:01,000 --> "))
        #expect(srt.contains("Hello there."))
    }
}
