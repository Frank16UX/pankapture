import AIProviders
import AppCore
import Foundation
import Synchronization
import Testing
import Transcription
@testable import AutoEdit

/// Answers queued per test; serves `URLSession` requests without a network.
final class MockURLProtocol: URLProtocol {
    static let responses = Mutex<[(status: Int, body: String)]>([])
    static let requestCount = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount.withLock { $0 += 1 }
        let next: (status: Int, body: String) = Self.responses.withLock { $0.isEmpty ? (500, "{}") : $0.removeFirst() }
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(next.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// An OpenAI-style answer whose content is `content`.
    static func answer(_ content: String) -> (Int, String) {
        let escaped = JSONValue.string(content).serialized()
        return (200, #"{"choices":[{"message":{"content":\#(escaped)},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":10}}"#)
    }
}

/// "The numbers for April. Wait, sorry, I meant May." then a 2 s pause, more
/// words, and a 0.4 s pause the model doesn't judge.
private func sampleInput() -> AutoEditInput {
    let transcript = makeTranscript("The numbers for April. Wait, sorry, I meant May. |2 Now let's open |0.4 the settings.")
    let first = transcript.words[8].end
    let second = transcript.words[11].end
    let pauses = [
        Pause(id: 0, range: TimeRange(start: first, end: first + 2), afterWord: 8, kind: .sentence),
        Pause(id: 1, range: TimeRange(start: second, end: second + 0.4), afterWord: 11, kind: .hesitation),
    ]
    let rules = RuleBasedEditor.suggestions(for: transcript)
    return AutoEditInput(transcript: transcript, pauses: pauses, ruleSuggestions: rules, duration: 10)
}

@Suite("Model pass")
struct ModelPassTests {
    @Test func promptNumbersWordsAndMarksJudgedPauses() {
        let prompt = ModelPass.userPrompt(for: sampleInput())
        #expect(prompt.hasPrefix("Language: English\n"))
        #expect(prompt.contains("[3]April.\n[4]Wait,"))
        #expect(prompt.contains("[8]May. ⟨p0 2.0s screen: still⟩\n[9]Now"))
        #expect(!prompt.contains("⟨p1"))
        #expect(ModelPass.judgedPauses(sampleInput()).map(\.id) == [0])
    }

    @Test func interpretsAValidAnswer() throws {
        let answer = #"{"cuts":[{"reason":"corrected month","kind":"retake","from":3,"to":7}],"pauses":[{"id":0,"kind":"section"}]}"#
        let result = try ModelPass.interpret(answer, input: sampleInput())
        #expect(result.suggestions.map(\.words) == [3...7])
        #expect(result.suggestions.first?.source == .model)
        #expect(result.suggestions.first?.reason == "corrected month")
        #expect(result.pauseKinds == [0: .section])
        #expect(result.warnings.isEmpty)
    }

    @Test func dropsBadItemsWithWarnings() throws {
        let answer = #"""
        {"cuts":[{"reason":"a","kind":"retake","from":3,"to":7},{"reason":"overlap","kind":"repeat","from":5,"to":6},
        {"reason":"far","kind":"repeat","from":40,"to":41},{"reason":"odd","kind":"filler","from":0,"to":0}],
        "pauses":[{"id":9,"kind":"section"},{"id":0,"kind":"pondering"}]}
        """#
        let result = try ModelPass.interpret(answer, input: sampleInput())
        #expect(result.suggestions.map(\.words) == [3...7])
        #expect(result.pauseKinds.isEmpty)
        #expect(result.warnings.count == 6)
    }

    @Test func rejectsUnreadableAnswers() {
        #expect(throws: ModelPass.Failure.self) { try ModelPass.interpret("not json", input: sampleInput()) }
        #expect(throws: ModelPass.Failure.self) { try ModelPass.interpret(#"{"cuts":[]}"#, input: sampleInput()) }
    }

    @Test func rejectsAnswersThatRemoveTooMuch() {
        let answer = #"{"cuts":[{"reason":"all","kind":"retake","from":0,"to":12}],"pauses":[]}"#
        #expect {
            try ModelPass.interpret(answer, input: sampleInput())
        } throws: { error in
            guard case ModelPass.Failure.removesTooMuch = error else { return false }
            return true
        }
    }

    @Test func combineKeepsFillersAndConfidentRules() throws {
        var input = sampleInput()
        let um = Suggestion(kind: .filler, range: TimeRange(start: 9, end: 9.2), words: nil, confidence: 0.95, reason: "um", source: .rules)
        let weak = Suggestion(kind: .repeat, range: TimeRange(start: 0, end: 0.5), words: 0...0, confidence: 0.45, reason: "weak", source: .rules)
        input.ruleSuggestions += [um, weak]
        let answer = #"{"cuts":[{"reason":"model","kind":"retake","from":3,"to":7}],"pauses":[{"id":0,"kind":"section"}]}"#
        let interpretation = try ModelPass.interpret(answer, input: input)
        let report = ModelPassReport(provider: "Test", model: "m", latency: 1, usage: TokenUsage(), warnings: [],
                                     rawContent: answer, firstTryValid: true, attempts: 1)
        let analysis = ModelPass.combine(input, interpretation, report: report)
        // The model's retake replaces the rules' copy of it; the weak rule goes; the filler stays.
        #expect(analysis.suggestions.map(\.source) == [.model, .rules])
        #expect(analysis.suggestions.map(\.kind) == [.retake, .filler])
        #expect(analysis.pauses.map(\.kind) == [.section, .hesitation])
        #expect(analysis.pauses.map(\.kindSource) == [.model, .rules])
    }
}

@Suite("Model pass over HTTP", .serialized)
struct ModelPassNetworkTests {
    private let configuration = ProviderConfiguration(preset: .lmStudio)

    @Test func retriesOnceAfterAnUnusableAnswer() async throws {
        MockURLProtocol.responses.withLock {
            $0 = [MockURLProtocol.answer("I think the cuts are…"),
                  MockURLProtocol.answer(#"{"cuts":[],"pauses":[{"id":0,"kind":"emphasis"}]}"#)]
        }
        let outcome = try await ModelPass.run(sampleInput(), configuration: configuration, apiKey: nil,
                                              client: LanguageModelClient(session: MockURLProtocol.session()))
        #expect(outcome.error == nil)
        #expect(outcome.report.attempts == 2)
        #expect(!outcome.report.firstTryValid)
        #expect(outcome.report.usage == TokenUsage(input: 200, output: 20))
        #expect(outcome.analysis.pauses.first?.kind == .emphasis)
    }

    @Test func fallsBackToTheRulesWhenTheProviderFails() async throws {
        MockURLProtocol.responses.withLock { $0 = [(503, #"{"error":{"message":"overloaded"}}"#)] }
        let input = sampleInput()
        let outcome = try await ModelPass.run(input, configuration: configuration, apiKey: nil,
                                              client: LanguageModelClient(session: MockURLProtocol.session()))
        #expect(outcome.error?.contains("overloaded") == true)
        #expect(outcome.report.attempts == 1)
        #expect(outcome.analysis.suggestions == input.ruleSuggestions)
        #expect(outcome.analysis.pauses == input.pauses)
    }
}
