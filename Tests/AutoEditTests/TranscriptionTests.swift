import AppCore
import AVFoundation
import Foundation
import Testing
@testable import AutoEdit
@testable import Transcription

@Suite("Cloud transcription")
struct CloudTranscriberTests {
    @Test func elevenLabsKeepsWordsAndDropsSpacing() throws {
        let json = #"""
        {"language_code":"es","text":"Hola, eh, todos.","words":[
          {"text":"Hola,","start":0.0,"end":0.4,"type":"word","logprob":-0.1},
          {"text":" ","start":0.4,"end":0.5,"type":"spacing"},
          {"text":"eh,","start":0.5,"end":0.8,"type":"word","logprob":-0.5},
          {"text":"(laughs)","start":0.8,"end":1.0,"type":"audio_event"},
          {"text":"todos.","start":1.0,"end":1.4,"type":"word"}]}
        """#
        let words = try CloudTranscriber.parse(Data(json.utf8), service: .elevenLabs)
        #expect(words.map(\.text) == ["Hola,", "eh,", "todos."])
        #expect(words[1].start == 0.5)
        #expect(abs((words[0].confidence ?? 0) - exp(-0.1)) < 1e-9)
    }

    @Test func whisperWordsGetTheirPunctuationBack() throws {
        let json = #"""
        {"text":" The numbers for April. Wait, sorry, I meant May.","words":[
          {"word":"The","start":0,"end":0.2},{"word":"numbers","start":0.2,"end":0.6},{"word":"for","start":0.6,"end":0.8},
          {"word":"April","start":0.8,"end":1.2},{"word":"Wait","start":1.4,"end":1.6},{"word":"sorry","start":1.6,"end":1.9},
          {"word":"I","start":1.9,"end":2.0},{"word":"meant","start":2.0,"end":2.2},{"word":"May","start":2.2,"end":2.5}]}
        """#
        let words = try CloudTranscriber.parse(Data(json.utf8), service: .openAI)
        #expect(words.map(\.text) == ["The", "numbers", "for", "April.", "Wait,", "sorry,", "I", "meant", "May."])
        #expect(throws: CloudTranscriber.Failure.self) { try CloudTranscriber.parse(Data(#"{"text":"hi"}"#.utf8), service: .groq) }
    }

    @Test func requestsCarryTheServiceFields() throws {
        let eleven = CloudTranscriber.urlRequest(service: .elevenLabs, language: .spanish, apiKey: "xi", audio: Data([1, 2, 3]))
        #expect(eleven.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(eleven.value(forHTTPHeaderField: "xi-api-key") == "xi")
        let elevenBody = String(decoding: eleven.httpBody ?? Data(), as: UTF8.self)
        #expect(elevenBody.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
        #expect(elevenBody.contains("name=\"language_code\"\r\n\r\nes"))
        #expect(elevenBody.contains("name=\"timestamps_granularity\"\r\n\r\nword"))

        let groq = CloudTranscriber.urlRequest(service: .groq, language: .english, apiKey: "gsk", audio: Data([1]))
        #expect(groq.value(forHTTPHeaderField: "Authorization") == "Bearer gsk")
        let groqBody = String(decoding: groq.httpBody ?? Data(), as: UTF8.self)
        #expect(groqBody.contains("name=\"timestamp_granularities[]\"\r\n\r\nword"))
        #expect(groqBody.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(groqBody.contains("filename=\"audio.m4a\""))
        #expect(groq.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func compressesToSmallAAC() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AutoEditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = try await TestAudioMovie.make(in: directory, duration: 3, tracks: [("Microphone", { _ in 0.4 })])
        let audio = try await MicrophoneAudio.extract(from: movie, to: directory.appendingPathComponent("mic.caf"))
        let upload = directory.appendingPathComponent("upload.m4a")
        try CloudTranscriber.compress(audio.url, to: upload)
        let file = try AVAudioFile(forReading: upload)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - 3) < 0.2)
        let bytes = try FileManager.default.attributesOfItem(atPath: upload.path)[.size] as? Int ?? 0
        #expect(bytes > 0 && bytes < 40_000)
    }
}

@Suite("Rules: stutters from audio")
struct StretchedWordTests {
    @Test func aLongWordWithABreakInsideIsSuggested() {
        // Twelve ordinary words, then "vamos" stretched to 1.6 s over a repeat.
        var words = (0..<12).map { TranscriptWord(text: "palabra", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4) }
        words.append(TranscriptWord(text: "vamos", start: 6.0, end: 7.6))
        words.append(TranscriptWord(text: "ahora.", start: 7.7, end: 8.1))
        let transcript = Transcript(language: .spanish, localeIdentifier: "es-MX", engine: "test", words: words)
        // Speech inside each word, silence between words, and a 0.4 s break
        // inside the long one.
        var levels = [Float](repeating: -70, count: 820)
        for word in words {
            for frame in Int(word.start * 100)..<Int(word.end * 100) { levels[frame] = -20 }
        }
        for frame in 680..<720 { levels[frame] = -70 }
        let envelope = LoudnessEnvelope(startTime: 0, levels: levels)

        let found = RuleBasedEditor.stretchedWords(RuleBasedEditor.Context(transcript), envelope: envelope)
        #expect(found.count == 1)
        #expect(found.first?.words == 12...12)
        #expect(abs((found.first?.range.end ?? 0) - 7.2) < 0.011)
        #expect(found.first?.isEnabledByDefault == false)
    }

    @Test func ordinaryWordsAreLeftAlone() {
        let words = (0..<15).map { TranscriptWord(text: "word", start: Double($0) * 0.5, end: Double($0) * 0.5 + 0.4) }
        let transcript = Transcript(language: .english, localeIdentifier: "en-US", engine: "test", words: words)
        let envelope = LoudnessEnvelope(startTime: 0, levels: [Float](repeating: -20, count: 800))
        #expect(RuleBasedEditor.stretchedWords(RuleBasedEditor.Context(transcript), envelope: envelope).isEmpty)
    }
}
