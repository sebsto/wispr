//
//  VocabularyCorrectorTests.swift
//  wispr
//
//  Unit tests for VocabularyCorrector utility.
//
//  VocabularyCorrector fixes proper nouns / tool names that the ASR model
//  mis-transcribes ("nova ria", "novarya" → "Novaria") by matching transcription
//  tokens against a user-provided vocabulary using a phonetic key plus a
//  normalized edit-distance threshold. "Novaria" is a fictitious placeholder name
//  used to exercise phonetic matching without referencing any real product.
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

@Suite("VocabularyCorrector Tests")
struct VocabularyCorrectorTests {

    // MARK: - Test Case Types

    /// Input/expected pair for parameterized correct() tests, sharing a vocabulary.
    struct CorrectCase: Sendable, CustomTestStringConvertible {
        let input: String
        let expected: String
        var testDescription: String { "\"\(input)\" → \"\(expected)\"" }
    }

    static nonisolated let novariaVocabulary = ["Novaria"]

    // MARK: - Case Normalization (word already recognized, wrong spelling/case)

    static nonisolated let caseCases: [CorrectCase] = [
        CorrectCase(input: "I use novaria daily", expected: "I use Novaria daily"),
        CorrectCase(input: "I use NOVARIA daily", expected: "I use Novaria daily"),
        CorrectCase(input: "I use Novaria daily", expected: "I use Novaria daily"),
    ]

    @Test("Normalizes casing of an already-recognized vocabulary word", arguments: caseCases)
    func caseNormalization(_ c: CorrectCase) {
        #expect(VocabularyCorrector.correct(c.input, vocabulary: Self.novariaVocabulary) == c.expected)
    }

    // MARK: - Phonetic Match (single token)

    static nonisolated let phoneticSingleCases: [CorrectCase] = [
        CorrectCase(input: "I use novarya daily", expected: "I use Novaria daily"),
        CorrectCase(input: "I use novarïa daily", expected: "I use Novaria daily"),
    ]

    @Test("Corrects a single mis-transcribed token phonetically", arguments: phoneticSingleCases)
    func phoneticSingle(_ c: CorrectCase) {
        #expect(VocabularyCorrector.correct(c.input, vocabulary: Self.novariaVocabulary) == c.expected)
    }

    // MARK: - Phonetic Match (multi-token / word split by the model)

    static nonisolated let phoneticMultiCases: [CorrectCase] = [
        CorrectCase(input: "I use nova ria daily", expected: "I use Novaria daily"),
        CorrectCase(input: "I use nova rya daily", expected: "I use Novaria daily"),
    ]

    @Test("Corrects a vocabulary word the model split into several tokens", arguments: phoneticMultiCases)
    func phoneticMulti(_ c: CorrectCase) {
        #expect(VocabularyCorrector.correct(c.input, vocabulary: Self.novariaVocabulary) == c.expected)
    }

    // MARK: - Punctuation Preservation

    @Test("Preserves punctuation adjacent to a corrected word")
    func preservesPunctuation() {
        #expect(VocabularyCorrector.correct("We chose novaria.", vocabulary: Self.novariaVocabulary) == "We chose Novaria.")
        #expect(VocabularyCorrector.correct("novaria, right?", vocabulary: Self.novariaVocabulary) == "Novaria, right?")
    }

    // MARK: - Adjacent Word Preservation (regression)

    /// A strong single-word match must not let a weaker multi-word window
    /// swallow an innocent neighbouring word ("on kubernetes" must keep "on").
    @Test("Does not absorb a short neighbouring word into a strong match")
    func preservesNeighbouringWord() {
        let vocab = ["Kubernetes"]
        #expect(VocabularyCorrector.correct("we deployed on kubernetes", vocabulary: vocab) == "we deployed on Kubernetes")
    }

    /// At equal score the shorter window wins, so a neighbouring word is never
    /// swallowed even when the longer window would also match the vocabulary.
    @Test("Does not swallow a real neighbouring word at equal score")
    func prefersShorterWindowOnTie() {
        // "PyTorch qui": both "païtorc" and "païtorc qui" score 1.0 for PyTorch,
        // but the shorter window must win so "qui" survives.
        #expect(
            VocabularyCorrector.correct("usiamo païtorc qui", vocabulary: ["PyTorch"], languageCode: "it")
                == "usiamo PyTorch qui"
        )
    }

    // MARK: - Multilingual Pronunciation

    /// A word may be pronounced the user-language way or the English way; both
    /// should match. "PyTorch" said the French way ("pitorche") and the English
    /// way ("païtorche") both map to the canonical spelling for a French user.
    static nonisolated let pytorchCases: [CorrectCase] = [
        CorrectCase(input: "we use pitorche here", expected: "we use PyTorch here"),   // FR pronunciation
        CorrectCase(input: "we use païtorche here", expected: "we use PyTorch here"),  // EN pronunciation
        CorrectCase(input: "we use pytorch here", expected: "we use PyTorch here"),    // near-exact
    ]

    @Test("Matches both user-language and English pronunciations", arguments: pytorchCases)
    func multilingualPronunciation(_ c: CorrectCase) {
        #expect(VocabularyCorrector.correct(c.input, vocabulary: ["PyTorch"], languageCode: "fr") == c.expected)
    }

    /// The user's language is honored generically, not hardcoded to French.
    /// An Italian user should still match the English pronunciation of a tech name.
    @Test("Honors an arbitrary user language plus English (Italian)")
    func italianUserPlusEnglish() {
        #expect(VocabularyCorrector.correct("usiamo païtorc qui", vocabulary: ["PyTorch"], languageCode: "it") == "usiamo PyTorch qui")
    }

    /// A regional code like "en-US" is normalized to its base language.
    @Test("Normalizes a regional language code")
    func regionalLanguageCode() {
        #expect(VocabularyCorrector.correct("we use païtorche here", vocabulary: ["PyTorch"], languageCode: "en-US") == "we use PyTorch here")
    }

    // MARK: - No False Positives

    static nonisolated let noMatchCases: [CorrectCase] = [
        CorrectCase(input: "Hello world", expected: "Hello world"),
        CorrectCase(input: "I like data science", expected: "I like data science"),
        CorrectCase(input: "the database is ready", expected: "the database is ready"),
    ]

    @Test("Leaves unrelated words untouched", arguments: noMatchCases)
    func noFalsePositives(_ c: CorrectCase) {
        #expect(VocabularyCorrector.correct(c.input, vocabulary: Self.novariaVocabulary) == c.expected)
    }

    // MARK: - Multiple Vocabulary Entries

    @Test("Corrects the closest of several vocabulary entries")
    func multipleVocabularyEntries() {
        let vocab = ["Novaria", "Kubernetes", "Anthropic"]
        #expect(VocabularyCorrector.correct("I use novaria and kubernetes", vocabulary: vocab) == "I use Novaria and Kubernetes")
    }

    // MARK: - Edge Cases

    @Test("Returns text unchanged when vocabulary is empty")
    func emptyVocabulary() {
        #expect(VocabularyCorrector.correct("I use novaria daily", vocabulary: []) == "I use novaria daily")
    }

    @Test("Returns empty string for empty input")
    func emptyInput() {
        #expect(VocabularyCorrector.correct("", vocabulary: Self.novariaVocabulary) == "")
    }

    @Test("Ignores empty and whitespace-only vocabulary entries")
    func ignoresBlankVocabularyEntries() {
        #expect(VocabularyCorrector.correct("Hello world", vocabulary: ["", "   "]) == "Hello world")
    }

    @Test("Corrects a word at the start of the text")
    func matchAtStart() {
        #expect(VocabularyCorrector.correct("novaria is great", vocabulary: Self.novariaVocabulary) == "Novaria is great")
    }

    @Test("Corrects a word at the end of the text")
    func matchAtEnd() {
        #expect(VocabularyCorrector.correct("we love novaria", vocabulary: Self.novariaVocabulary) == "we love Novaria")
    }

    // MARK: - Short Words (fuzzy matching disabled below the key-length floor)

    /// Very short vocabulary words ("Go") produce 1–2 character phonetic keys on
    /// which the similarity threshold cannot discriminate. Fuzzy matching is
    /// disabled for them: only an exact case-insensitive spelling still corrects.
    @Test("Short word: fixes casing on exact spelling but never fuzzy-matches")
    func shortWordExactOnly() {
        let vocab = ["Go"]
        // Exact spelling, wrong case → corrected.
        #expect(VocabularyCorrector.correct("I write go daily", vocabulary: vocab) == "I write Go daily")
        // Sound-alike words must NOT be swallowed by a 1-character key.
        #expect(VocabularyCorrector.correct("le gars est là", vocabulary: vocab) == "le gars est là")
        #expect(VocabularyCorrector.correct("gay pride", vocabulary: vocab) == "gay pride")
    }

    @Test("Short multi-word entries compare normalized canonical spelling")
    func shortMultiWordExactMatch() {
        #expect(VocabularyCorrector.correct("we chose a b", vocabulary: ["A B"]) == "we chose A B")
    }

    @Test("Folds eau before its component digraphs")
    func eauDigraphOrder() {
        #expect(VocabularyCorrector.phoneticKey("Bordeaux", language: "en") == "bordox")
    }
}
