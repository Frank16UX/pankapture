import AppCore
import AVFoundation
import Foundation

/// Speech-to-text services the user can bring a key for (PRD AI-5). Off by
/// default: unlike everything else in smart editing, these receive the
/// microphone **audio**. Their gain over the on-device recognizer is a
/// verbatim transcript that keeps fillers and stutters (ElevenLabs keeps
/// them by default; Whisper mostly drops them but is cheap). OpenRouter
/// reaches several of them, Scribe included, with one key.
public enum CloudTranscriptionService: String, Codable, CaseIterable, Sendable, Identifiable {
    case elevenLabs
    case openAI
    case groq
    case openRouter

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .groq: "Groq"
        case .openRouter: "OpenRouter"
        }
    }

    /// The model used when none is chosen.
    public var defaultModel: String {
        switch self {
        case .elevenLabs: "scribe_v2"
        case .openAI: "whisper-1"
        case .groq: "whisper-large-v3-turbo"
        case .openRouter: "elevenlabs/scribe-v2"
        }
    }

    var endpoint: URL {
        switch self {
        case .elevenLabs: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        case .openAI: URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        case .groq: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
        }
    }

    /// Environment variable `make eval` reads the key from.
    public var keyEnvironmentVariable: String {
        switch self {
        case .elevenLabs: "ELEVENLABS_API_KEY"
        case .openAI: "OPENAI_API_KEY"
        case .groq: "GROQ_API_KEY"
        case .openRouter: "OPENROUTER_API_KEY"
        }
    }

    /// Whether `model` keeps "um", "uh", and stutters in the transcript
    /// (checked on a probe clip, 2026-10-27).
    public func isVerbatim(model: String) -> Bool {
        switch self {
        case .elevenLabs: true
        case .openAI, .groq: false
        case .openRouter: model.hasPrefix("elevenlabs/") || model.hasPrefix("assemblyai/")
        }
    }
}

/// What a cloud transcription needs: the service, its model, and the key.
public struct CloudTranscription: Sendable {
    public var service: CloudTranscriptionService
    public var model: String
    public var apiKey: String

    public init(service: CloudTranscriptionService, model: String? = nil, apiKey: String) {
        self.service = service
        self.model = model.flatMap { $0.isEmpty ? nil : $0 } ?? service.defaultModel
        self.apiKey = apiKey
    }

    /// "ElevenLabs scribe_v2", for the transcript's engine and the log.
    public var displayName: String { "\(service.name) \(model)" }
}

public enum CloudTranscriber {
    public enum Failure: LocalizedError, Equatable {
        case http(status: Int, message: String)
        case invalidResponse(String)
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case let .http(status, _) where status == 401 || status == 403:
                "The transcription service rejected the API key (\(status)). It may be mistyped, expired, or revoked: save a new one in Settings ▸ AI."
            case let .http(status, message): "The transcription service answered \(status): \(message)"
            case .invalidResponse(let detail): "The transcription couldn't be read: \(detail)"
            case .tooLarge(let megabytes): "The audio is \(megabytes) MB, more than the service accepts (25 MB)."
            }
        }
    }

    /// Whisper endpoints reject uploads over 25 MB (about 70 minutes at the upload bitrate).
    static let maximumUploadBytes = 25 * 1_000_000

    /// Transcribes `audioURL` (any file `AVAudioFile` reads) with `cloud`.
    /// The audio is compressed to AAC before upload; word times are offset by
    /// `timeOffset`, like the on-device engine's.
    public static func transcribe(
        audioFileAt audioURL: URL,
        language: TranscriptLanguage,
        cloud: CloudTranscription,
        timeOffset: Double = 0,
        session: URLSession = .shared
    ) async throws -> Transcript {
        let upload = FileManager.default.temporaryDirectory.appendingPathComponent("pankapture-upload-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: upload) }
        try compress(audioURL, to: upload)
        let audio = try Data(contentsOf: upload)
        guard audio.count <= maximumUploadBytes else { throw Failure.tooLarge(audio.count / 1_000_000) }

        let request = urlRequest(cloud, language: language, audio: audio)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.http(status: http.statusCode, message: errorMessage(in: data))
        }
        let words = try parse(data, service: cloud.service).map { word in
            TranscriptWord(text: word.text, start: word.start + timeOffset, end: word.end + timeOffset, confidence: word.confidence)
        }
        Log.editor.info("Cloud transcription (\(cloud.displayName, privacy: .public)): \(words.count) words")
        return Transcript(language: language, localeIdentifier: language.rawValue, engine: cloud.displayName, words: words)
    }

    /// 16 kHz mono AAC at 48 kbps: small enough to upload, plenty for speech.
    static func compress(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ]
        let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384) else {
            throw Failure.invalidResponse("audio format")
        }
        let converter = input.processingFormat == mono ? nil : AVAudioConverter(from: input.processingFormat, to: mono)
        while input.framePosition < input.length {
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            if let converter {
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * mono.sampleRate / input.processingFormat.sampleRate) + 1
                guard let converted = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: capacity) else { break }
                var fed = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if fed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    status.pointee = .haveData
                    return buffer
                }
                if let error { throw error }
                try output.write(from: converted)
            } else {
                try output.write(from: buffer)
            }
        }
    }

    // MARK: Requests

    static func urlRequest(_ cloud: CloudTranscription, language: TranscriptLanguage, audio: Data) -> URLRequest {
        var form = MultipartForm()
        switch cloud.service {
        case .elevenLabs:
            form.add("model_id", cloud.model)
            form.add("language_code", language.rawValue)
            form.add("timestamps_granularity", "word")
            form.add("tag_audio_events", "false")
            form.add("diarize", "false")
        case .openAI, .groq, .openRouter:
            form.add("model", cloud.model)
            form.add("language", language.rawValue)
            form.add("response_format", "verbose_json")
            form.add("timestamp_granularities[]", "word")
        }
        form.addFile("file", filename: "audio.m4a", contentType: "audio/mp4", data: audio)

        var request = URLRequest(url: cloud.service.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type")
        switch cloud.service {
        case .elevenLabs: request.setValue(cloud.apiKey, forHTTPHeaderField: "xi-api-key")
        case .openAI, .groq, .openRouter: request.setValue("Bearer \(cloud.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.finish()
        return request
    }

    // MARK: Responses

    struct ParsedWord: Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Double?
    }

    static func parse(_ data: Data, service: CloudTranscriptionService) throws -> [ParsedWord] {
        switch service {
        case .elevenLabs:
            struct Response: Decodable {
                struct Word: Decodable {
                    var text: String
                    var start: Double?
                    var end: Double?
                    var type: String?
                    var logprob: Double?
                }
                var words: [Word]
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
                throw Failure.invalidResponse("no words in the answer")
            }
            return response.words.compactMap { word in
                guard word.type == nil || word.type == "word", let start = word.start, let end = word.end else { return nil }
                let text = word.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return ParsedWord(text: text, start: start, end: end, confidence: word.logprob.map { exp($0) })
            }
        case .openAI, .groq, .openRouter:
            // OpenRouter answers in this shape for every model it routes to.
            struct Response: Decodable {
                struct Word: Decodable {
                    var word: String
                    var start: Double
                    var end: Double
                    var confidence: Double?
                }
                var text: String?
                var words: [Word]?
            }
            guard let response = try? JSONDecoder().decode(Response.self, from: data), let words = response.words else {
                throw Failure.invalidResponse("no word timestamps in the answer")
            }
            let parsed = words.map { ParsedWord(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end, confidence: $0.confidence) }
            return punctuate(parsed.filter { !$0.text.isEmpty }, from: response.text ?? "")
        }
    }

    /// Whisper's word list has no punctuation; its full text does. Takes each
    /// word's punctuated form from the text, matching in order.
    static func punctuate(_ words: [ParsedWord], from text: String) -> [ParsedWord] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = words
        var cursor = 0
        for index in result.indices {
            let bare = TranscriptWord.bare(result[index].text)
            for lookahead in cursor..<min(tokens.count, cursor + 4) where TranscriptWord.bare(tokens[lookahead]) == bare {
                result[index].text = tokens[lookahead]
                cursor = lookahead + 1
                break
            }
        }
        return result
    }

    static func errorMessage(in data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String { return message }
            if let detail = object["detail"] as? String { return detail }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no details" : text
    }
}

/// A `multipart/form-data` body.
struct MultipartForm {
    let boundary = "pankapture-\(UUID().uuidString)"
    private var body = Data()

    mutating func add(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finish() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
