import Foundation
import Transcription

/// Word lists the rules use, per language. Entries are bare words
/// (`TranscriptWord.bare`): lowercased, no surrounding punctuation.
struct Lexicon: Sendable {
    /// Always fillers (PRD AE-4).
    var fillers: Set<String>
    /// Fillers only when a pause or punctuation follows ("este," vs "este video").
    var setApartFillers: [[String]]
    /// Fillers only when set apart on both sides, and off by default.
    var ambiguousFillers: [[String]]
    /// Words people repeat on purpose ("very, very", "no, no, no").
    var emphasisWords: Set<String>
    /// "wait", "sorry", "perdón": may mark a correction or a restart.
    var interjections: [[String]]
    /// Introduce a replacement for the words right before ("I meant", "digo").
    var corrections: [[String]]
    /// Corrections that are also everyday phrases ("I mean", "quiero decir"):
    /// they only count next to an interjection or when the replacement
    /// echoes the abandoned words.
    var ambiguousCorrections: [[String]]
    /// Throw away the sentence so far ("let me start over").
    var restarts: [[String]]
    /// Openers that often begin a new section ("now", "next", "ahora").
    var transitions: [[String]]

    static func `for`(_ language: TranscriptLanguage) -> Lexicon {
        switch language {
        case .english: english
        case .spanish: spanish
        }
    }

    static let english = Lexicon(
        fillers: ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm", "mm", "mmm", "mhm"],
        setApartFillers: [["ah"]],
        ambiguousFillers: [["like"], ["you", "know"], ["basically"], ["kind", "of"], ["sort", "of"], ["so"], ["well"]],
        emphasisWords: ["very", "really", "so", "no", "yes", "yeah", "never", "much", "more", "way", "too", "super",
                        "okay", "ok", "bye", "please", "go", "ha", "hey", "now", "again"],
        interjections: [["no", "wait"], ["oh", "wait"], ["wait"], ["sorry"], ["oops"], ["whoops"], ["actually", "no"]],
        corrections: [["i", "meant"], ["or", "rather"], ["make", "that"], ["correction"]],
        ambiguousCorrections: [["i", "mean"]],
        restarts: [["let", "me", "start", "over"], ["let", "me", "start", "again"], ["let", "me", "try", "that", "again"],
                   ["let", "me", "try", "again"], ["let", "me", "rephrase", "that"], ["let", "me", "rephrase"],
                   ["let", "me", "say", "that", "again"], ["start", "over"], ["scratch", "that"], ["take", "two"]],
        transitions: [["moving", "on"], ["next", "up"], ["all", "right"], ["now"], ["next"], ["so"], ["okay"], ["ok"],
                      ["alright"], ["let's"], ["first"], ["second"], ["third"], ["finally"], ["lastly"], ["then"], ["great"]]
    )

    static let spanish = Lexicon(
        fillers: ["eh", "ehh", "ehm", "em", "emm", "mm", "mmm", "hmm", "mhm"],
        setApartFillers: [["o", "sea"], ["este"], ["pues"], ["ah"]],
        ambiguousFillers: [["bueno"], ["digamos"], ["tipo"]],
        emphasisWords: ["muy", "no", "sí", "si", "nunca", "más", "mucho", "ya", "bien", "claro", "súper", "ok", "okey",
                        "vale", "nada", "todo", "chao", "adiós", "dale"],
        interjections: [["no", "espera"], ["espera"], ["esperen"], ["perdón"], ["perdona"], ["disculpa"], ["disculpen"],
                        ["ups"], ["ay", "no"]],
        corrections: [["quise", "decir"], ["mejor", "dicho"], ["o", "más", "bien"], ["corrijo"]],
        ambiguousCorrections: [["digo"], ["quiero", "decir"]],
        restarts: [["vuelvo", "a", "empezar"], ["empiezo", "de", "nuevo"], ["empiezo", "otra", "vez"],
                   ["lo", "digo", "de", "nuevo"], ["lo", "repito"], ["déjame", "repetir"], ["déjenme", "repetir"],
                   ["me", "equivoqué"], ["me", "confundí"]],
        transitions: [["a", "continuación"], ["por", "último"], ["muy", "bien"], ["ahora"], ["bueno"], ["entonces"],
                      ["vamos"], ["pasemos"], ["siguiente"], ["primero"], ["segundo"], ["tercero"], ["finalmente"],
                      ["listo"], ["ok"], ["okey"], ["perfecto"], ["después"]]
    )
}
