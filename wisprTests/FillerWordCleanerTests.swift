//
//  FillerWordCleanerTests.swift
//  wispr
//
//  Unit tests for FillerWordCleaner utility.
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

@Suite("FillerWordCleaner Tests")
struct FillerWordCleanerTests {

    // MARK: - Test Case Types

    /// Input/expected pair for parameterized clean() tests.
    struct CleanCase: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { "\"\(input)\" → \"\(expected)\"" }
    }

    // MARK: - Filler Removal (English)

    static nonisolated let englishFillerCases: [CleanCase] = [
        CleanCase(input: "I um think so", expected: "I think so"),
        CleanCase(input: "uh I think so", expected: "I think so"),
        CleanCase(input: "ah that's right", expected: "that's right"),
        CleanCase(input: "I er need help", expected: "I need help"),
        CleanCase(input: "erm let me think", expected: "let me think"),
        CleanCase(input: "hmm interesting", expected: "interesting"),
        CleanCase(input: "hm okay", expected: "okay"),
        CleanCase(input: "mhm I agree", expected: "I agree"),
        CleanCase(input: "uh-huh that works", expected: "that works"),
        CleanCase(input: "uh–huh that works", expected: "that works"), // en dash
        CleanCase(input: "oh I see", expected: "I see"),
        CleanCase(input: "eh not sure", expected: "not sure"),
    ]

    @Test("Removes English filler words", arguments: englishFillerCases)
    func englishFillerRemoval(_ c: CleanCase) {
        #expect(FillerWordCleaner.clean(c.input) == c.expected)
    }

    // MARK: - Filler Removal (French)

    static nonisolated let frenchFillerCases: [CleanCase] = [
        CleanCase(input: "je euh pense que oui", expected: "je pense que oui"),
        CleanCase(input: "heu attends", expected: "attends"),
        CleanCase(input: "c'est bien hein", expected: "c'est bien"),
        CleanCase(input: "bah oui c'est ça", expected: "oui c'est ça"),
        CleanCase(input: "ben je sais pas", expected: "je sais pas"),
        CleanCase(input: "beh voilà", expected: "voilà"),
        CleanCase(input: "pfff c'est compliqué", expected: "c'est compliqué"),
        CleanCase(input: "pfffff vraiment", expected: "vraiment"),
        CleanCase(input: "mouais peut-être", expected: "peut-être"),
        CleanCase(input: "oh je vois", expected: "je vois"),
        CleanCase(input: "eh bien sûr", expected: "bien sûr"),
    ]

    @Test("Removes French filler words", arguments: frenchFillerCases)
    func frenchFillerRemoval(_ c: CleanCase) {
        #expect(FillerWordCleaner.clean(c.input) == c.expected)
    }

    // MARK: - Multiple & Mixed Fillers

    static nonisolated let multiFillerCases: [CleanCase] = [
        CleanCase(input: "um I uh think er it works", expected: "I think it works"),
        CleanCase(input: "euh je heu pense que bah oui", expected: "je pense que oui"),
        CleanCase(input: "um euh I think heu so", expected: "I think so"),
        CleanCase(input: "UM I think UH so", expected: "I think so"),
        CleanCase(input: "Um yeah Uh-Huh", expected: "yeah"),
    ]

    @Test("Removes multiple and mixed-language fillers", arguments: multiFillerCases)
    func multiFillerRemoval(_ c: CleanCase) {
        #expect(FillerWordCleaner.clean(c.input) == c.expected)
    }

    // MARK: - Word Boundary Safety

    static nonisolated let wordBoundaryCases: [CleanCase] = [
        CleanCase(input: "umbrella", expected: "umbrella"),
        CleanCase(input: "hummer", expected: "hummer"),
        CleanCase(input: "errand", expected: "errand"),
        CleanCase(input: "thermal", expected: "thermal"),
        CleanCase(input: "benne", expected: "benne"),
        CleanCase(input: "bahut", expected: "bahut"),
        CleanCase(input: "heure", expected: "heure"),
    ]

    @Test("Does not remove filler patterns inside real words", arguments: wordBoundaryCases)
    func wordBoundarySafety(_ c: CleanCase) {
        #expect(FillerWordCleaner.clean(c.input) == c.expected)
    }

    // MARK: - Punctuation Cleanup

    static nonisolated let punctuationCases: [CleanCase] = [
        CleanCase(input: "Well, um, I think so", expected: "Well, I think so"),
        CleanCase(input: "um, I think so", expected: "I think so"),
        CleanCase(input: "first; uh; second", expected: "first; second"),
        CleanCase(input: "Bon, euh, je pense", expected: "Bon, je pense"),
    ]

    @Test("Cleans up punctuation around fillers", arguments: punctuationCases)
    func punctuationCleanup(_ c: CleanCase) {
        #expect(FillerWordCleaner.clean(c.input) == c.expected)
    }

    // MARK: - Edge Cases (kept as individual tests)

    @Test("Returns empty string for empty input")
    func emptyInput() {
        #expect(FillerWordCleaner.clean("") == "")
    }

    @Test("Returns empty string when input is only English fillers")
    func onlyEnglishFillers() {
        #expect(FillerWordCleaner.clean("um uh er") == "")
    }

    @Test("Returns empty string when input is only French fillers")
    func onlyFrenchFillers() {
        #expect(FillerWordCleaner.clean("euh heu bah") == "")
    }

    @Test("Returns text unchanged when no fillers present")
    func noFillers() {
        #expect(FillerWordCleaner.clean("Hello world") == "Hello world")
    }

    @Test("Collapses extra spaces left after removal")
    func collapsesSpaces() {
        #expect(FillerWordCleaner.clean("I  um  think  uh  so") == "I think so")
    }

    @Test("Trims leading and trailing whitespace")
    func trimsWhitespace() {
        #expect(FillerWordCleaner.clean("um hello") == "hello")
        #expect(FillerWordCleaner.clean("hello um") == "hello")
    }

    @Test("Preserves non-English text")
    func nonEnglishText() {
        #expect(FillerWordCleaner.clean("こんにちは um 世界") == "こんにちは 世界")
    }

    @Test("Handles emoji in text")
    func emojiText() {
        #expect(FillerWordCleaner.clean("🎤 um hello 🌍") == "🎤 hello 🌍")
    }
}
