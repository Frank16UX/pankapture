import AppCore
import Foundation
import Testing
import Transcription
@testable import AutoEdit

/// A transcript from a script: words are 0.3 s long with 0.05 s between them;
/// a token like `|1.5` adds that much silence after the previous word.
func makeTranscript(_ script: String, language: TranscriptLanguage = .english) -> Transcript {
    var words: [TranscriptWord] = []
    var time = 0.0
    for token in script.split(separator: " ") {
        if token.hasPrefix("|"), let pause = Double(token.dropFirst()) {
            time += pause
            continue
        }
        words.append(TranscriptWord(text: String(token), start: time, end: time + 0.3))
        time += 0.35
    }
    return Transcript(language: language, localeIdentifier: language == .english ? "en-US" : "es-MX", engine: "test", words: words)
}

private func mistakes(_ script: String, language: TranscriptLanguage = .english) -> [Suggestion] {
    RuleBasedEditor.suggestions(for: makeTranscript(script, language: language)).filter(\.kind.isMistake)
}

private func fillers(_ script: String, language: TranscriptLanguage = .english) -> [Suggestion] {
    RuleBasedEditor.suggestions(for: makeTranscript(script, language: language)).filter { $0.kind == .filler }
}

@Suite("Transcript words")
struct TranscriptWordTests {
    @Test func bareFormDropsPunctuationAndCase() {
        #expect(TranscriptWord(text: "April.", start: 0, end: 1).bare == "april")
        #expect(TranscriptWord(text: "¿Qué?", start: 0, end: 1).bare == "qué")
        #expect(TranscriptWord(text: "Let’s", start: 0, end: 1).bare == "let's")
    }

    @Test func sentenceAndClauseEndings() {
        #expect(TranscriptWord(text: "done.", start: 0, end: 1).endsSentence)
        #expect(TranscriptWord(text: "really?\"", start: 0, end: 1).endsSentence)
        #expect(TranscriptWord(text: "wait,", start: 0, end: 1).endsClause)
        #expect(!TranscriptWord(text: "wait,", start: 0, end: 1).endsSentence)
        #expect(!TranscriptWord(text: "menu", start: 0, end: 1).endsClause)
    }

    @Test func languageFromLocale() {
        #expect(TranscriptLanguage(locale: Locale(identifier: "es-CR")) == .spanish)
        #expect(TranscriptLanguage(locale: Locale(identifier: "en-GB")) == .english)
        #expect(TranscriptLanguage(locale: Locale(identifier: "fr-FR")) == nil)
    }
}

@Suite("Rules: fillers")
struct FillerRuleTests {
    @Test func plainFillersAreConfident() {
        let found = fillers("So um we open the menu. Uh, done.")
        #expect(found.map(\.words) == [1...1, 6...6])
        #expect(found.allSatisfy { $0.confidence >= 0.9 && $0.isEnabledByDefault })
    }

    @Test func spanishEsteCountsOnlyWhenSetApart() {
        let found = fillers("Y este, |0.4 vamos a ver este video.", language: .spanish)
        #expect(found.map(\.words) == [1...1])
    }

    @Test func multiWordFiller() {
        let found = fillers("Es fácil, o sea, |0.3 abrimos el menú.", language: .spanish)
        #expect(found.map(\.words) == [2...3])
    }

    @Test func ambiguousFillersStartSwitchedOff() {
        let found = fillers("It's, like, |0.3 really fast.")
        #expect(found.map(\.words) == [1...1])
        #expect(found.first?.isEnabledByDefault == false)
        #expect(fillers("I like this app.").isEmpty)
    }
}

@Suite("Rules: repeats and stutters")
struct RepeatRuleTests {
    @Test func repeatedPhraseKeepsTheLastCopy() {
        let found = mistakes("Let me, let me open the settings.")
        #expect(found.count == 1)
        #expect(found.first?.kind == .repeat)
        #expect(found.first?.words == 0...1)
        // Removes up to where the second copy starts.
        let transcript = makeTranscript("Let me, let me open the settings.")
        #expect(found.first?.range.end == transcript.words[2].start)
    }

    @Test func singleWordStutter() {
        let found = mistakes("Open the the menu.")
        #expect(found.map(\.kind) == [.stutter])
        #expect(found.first?.words == 1...1)
    }

    @Test func emphasisIsNotAMistake() {
        #expect(mistakes("This is very, very important.").isEmpty)
        #expect(mistakes("No, no, no lo hagan así.", language: .spanish).isEmpty)
    }
}

@Suite("Rules: retakes and false starts")
struct RetakeRuleTests {
    @Test func correctionWithCueRemovesTheAbandonedWordsAndTheCue() {
        let found = mistakes("The numbers for April. Wait, sorry, I meant May.")
        #expect(found.count == 1)
        #expect(found.first?.kind == .retake)
        #expect(found.first?.words == 3...7)
        #expect(found.first?.isEnabledByDefault == true)
    }

    @Test func spanishCorrectionEchoesTheReplacedPhrase() {
        let found = mistakes("Las cifras del martes, digo, del miércoles.", language: .spanish)
        #expect(found.first?.kind == .retake)
        #expect(found.first?.words == 2...4)
    }

    @Test func everydayIMeanIsNotACorrection() {
        #expect(mistakes("It's great, I mean, it works well.").isEmpty)
        #expect(mistakes("Yo digo que funciona.", language: .spanish).isEmpty)
    }

    @Test func restartCueDropsTheSentenceSoFar() {
        let found = mistakes("So what we are going to do is |0.3 let me start over. We will open the menu.")
        #expect(found.first?.kind == .falseStart)
        #expect(found.first?.words == 0...11)
    }

    @Test func apologyThatIsntARestartStays() {
        #expect(mistakes("Sorry about the noise. Let's continue.").isEmpty)
        #expect(mistakes("I'll click Save. Sorry, the button moved. Click Save again.").isEmpty)
    }

    @Test func abandonedSentenceRestartedInFull() {
        let found = mistakes("So what we. |0.4 So what we will do is open it.")
        #expect(found.first?.kind == .falseStart)
        #expect(found.first?.words == 0...2)
    }

    @Test func sentenceRedoneWithItsLastWordChanged() {
        let found = mistakes("We release in April. We release in May.")
        #expect(found.first?.kind == .retake)
        #expect(found.first?.words == 0...3)
    }

    @Test func parallelSentencesAreNotRetakes() {
        #expect(mistakes("We need to install it. We need to configure it.").isEmpty)
        #expect(mistakes("Click the button. Click the menu to open it.").isEmpty)
        // Short parallel imperatives are only a switched-off suggestion.
        #expect(mistakes("Open the menu. Open the file.").allSatisfy { !$0.isEnabledByDefault })
    }

    @Test func identicalSentencesStartSwitchedOff() {
        let found = mistakes("Click save. Click save.")
        #expect(found.count == 1)
        #expect(found.first?.isEnabledByDefault == false)
    }

    @Test func fillersInsideAMistakeAreDropped() {
        let all = RuleBasedEditor.suggestions(for: makeTranscript("The numbers for um April. Wait, sorry, I meant May."))
        #expect(all.map(\.kind) == [.filler, .retake])
        #expect(all.first?.words == 3...3)
    }
}

@Suite("Rules: pause intent")
struct PauseRuleTests {
    private func kind(_ script: String, after word: Int, duration: Double, activity: ScreenActivity = .none) -> PauseKind {
        let transcript = makeTranscript(script)
        let start = transcript.words[word].end
        let pause = Pause(id: 0, range: TimeRange(start: start, end: start + duration), afterWord: word, activity: activity)
        return RuleBasedEditor.classify([pause], transcript: transcript)[0].kind
    }

    @Test func screenActivityMakesAnAction() {
        #expect(kind("Open the menu now", after: 2, duration: 1, activity: ScreenActivity(clicks: 1)) == .action)
        #expect(kind("Open the menu now", after: 2, duration: 1, activity: ScreenActivity(changedFraction: 0.05)) == .action)
    }

    @Test func longBreakAfterASentenceIsASection() {
        #expect(kind("That's the dashboard. The next part", after: 2, duration: 2.6) == .section)
        #expect(kind("That's the dashboard. Now settings", after: 2, duration: 1.6) == .section)
        #expect(kind("That's the dashboard. The settings", after: 2, duration: 1.6) == .sentence)
    }

    @Test func midSentenceSilenceIsAHesitation() {
        #expect(kind("We open the menu", after: 1, duration: 0.8) == .hesitation)
        #expect(kind("We open, the menu", after: 1, duration: 0.8) == .sentence)
    }

    @Test func unknownActivityIsKept() {
        let unknown = ScreenActivity(changedFraction: nil)
        #expect(unknown.isActive)
        #expect(unknown.summary == "unknown")
        #expect(kind("Open the menu now", after: 2, duration: 1, activity: unknown) == .action)
    }

    @Test func cursorWigglesAreStill() {
        #expect(!ScreenActivity(changedFraction: 0.001).isActive)
        #expect(ScreenActivity(clicks: 2, changedFraction: 0.01).summary == "2 clicks, changing")
        #expect(ScreenActivity.none.summary == "still")
    }
}
