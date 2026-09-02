//
//  VocabularyCorrector.swift
//  wispr
//
//  Corrects proper nouns / client names that the ASR model mis-transcribes by
//  matching transcription tokens against a user-provided vocabulary.
//
//  The model often gets domain-specific proper nouns and tool names wrong
//  ("kubectl" becomes "cube cuttle" or "cubectel"; "PyTorch" the wrong case).
//  This utility scans the transcription for runs of 1–3 words whose *sound*
//  matches a vocabulary entry and rewrites them to the canonical spelling.
//
//  Matching is engine-agnostic (runs on Whisper and Parakeet output alike) and
//  purely lexical: a lightweight phonetic key plus a normalized edit-distance
//  threshold. The threshold is deliberately high so that only genuine
//  sound-alikes are replaced and ordinary words are left untouched.
//
//  A word may be pronounced differently depending on language — e.g. "PyTorch"
//  said the French way ("pitorche") vs the English way ("païtorche") — and the
//  model transcribes each phonetically. To cover this, every word is folded once
//  per candidate language (the user's transcription language plus English, since
//  tech proper nouns are usually English) and a match on ANY language wins.
//  Both the transcription window and the vocabulary entry are folded with the
//  SAME language rules before comparison, so the comparison stays consistent.
//

import Foundation

enum VocabularyCorrector {

    /// Minimum phonetic similarity (1 - normalized Levenshtein) required to
    /// replace a window with a vocabulary entry. High to avoid false positives —
    /// vocabulary entries are proper nouns, so we only want near-exact sound-alikes.
    private static let similarityThreshold = 0.8

    /// Largest number of consecutive transcription words considered as a single
    /// candidate. The model frequently splits an unknown proper noun into several
    /// tokens ("data ecou"), so we must look at multi-word windows.
    private static let maxWindow = 3

    /// Minimum phonetic-key length for fuzzy matching. On 1–2 character keys the
    /// normalized edit distance is effectively binary, so the similarity threshold
    /// cannot discriminate ("Go" → key "g" would match any word folding to "g").
    /// Shorter keys only match when both keys are identical AND the original
    /// words are equal case-insensitively.
    private static let minKeyLengthForFuzzyMatch = 3

    /// A vocabulary entry paired with its phonetic key per candidate language.
    private struct Entry {
        let canonical: String
        /// Folded key keyed by language pass (see `phoneticKeys(for:languages:)`).
        let keysByLanguage: [String: String]
    }

    /// A potential replacement: a run of `len` tokens starting at `start` that
    /// matches `canonical` with the given phonetic `score`.
    private struct Candidate {
        let start: Int
        let len: Int
        let canonical: String
        let score: Double
    }

    /// Rewrites runs of words in `text` that phonetically match a `vocabulary`
    /// entry to that entry's canonical spelling.
    ///
    /// - Parameters:
    ///   - text: Raw transcription text.
    ///   - vocabulary: Correctly spelled words to bias toward (e.g. client names).
    ///   - languageCode: The user's transcription language (ISO code like "fr",
    ///     "it"), or nil for auto-detect. Matching is attempted in this language
    ///     and in English; a match on either wins.
    /// - Returns: The text with matched runs replaced by their canonical spelling.
    static func correct(_ text: String, vocabulary: [String], languageCode: String? = nil) -> String {
        guard !text.isEmpty else { return text }

        let languages = candidateLanguages(for: languageCode)

        let entries: [Entry] = vocabulary.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let keys = phoneticKeys(for: trimmed, languages: languages)
            guard !keys.isEmpty else { return nil }
            return Entry(canonical: trimmed, keysByLanguage: keys)
        }
        guard !entries.isEmpty else { return text }

        // Split into whitespace-separated tokens, remembering the exact separators
        // so the reconstructed string preserves original spacing/newlines.
        let (tokens, separators) = tokenize(text)
        guard !tokens.isEmpty else { return text }

        let chosen = selectReplacements(for: tokens, entries: entries, languages: languages)

        // Rebuild the string inline, keyed by original token index, so the
        // captured separators (spacing/newlines) always stay aligned even when a
        // window collapses several tokens into one replacement.
        // separators[0] is any leading whitespace; separators[i+1] follows tokens[i].
        var out = separators.first ?? ""
        var i = 0
        while i < tokens.count {
            var consumed = 1
            var piece = tokens[i]

            if let candidate = chosen[i] {
                let window = Array(tokens[i..<(i + candidate.len)])
                // Reattach the leading/trailing punctuation of the window so
                // "kubectl." stays "kubectl." and "kubectl," stays "kubectl,".
                let (leading, _) = affixes(of: window.first!)
                let (_, trailing) = affixes(of: window.last!)
                piece = leading + candidate.canonical + trailing
                consumed = candidate.len
            }

            out += piece
            // Append the separator that followed the LAST token of this window,
            // discarding any separators consumed inside the collapsed window.
            let sepIndex = i + consumed
            if sepIndex < separators.count {
                out += separators[sepIndex]
            }
            i += consumed
        }

        return out
    }

    // MARK: - Replacement Selection

    /// Finds the best set of non-overlapping token runs to replace.
    ///
    /// Every window of 1…`maxWindow` tokens is scored against the vocabulary.
    /// Candidates are then chosen greedily by descending score so a strong match
    /// wins over a weaker overlapping one — e.g. "kubernetes" (exact) beats
    /// "on kubernetes" (near), keeping the "on". Ties prefer the *shorter* window
    /// so an innocent neighbouring word is never swallowed ("PyTorch qui" keeps
    /// "qui" rather than absorbing it into the match).
    ///
    /// - Returns: A map from a token's start index to the winning candidate.
    private static func selectReplacements(for tokens: [String], entries: [Entry], languages: [String]) -> [Int: Candidate] {
        // 1. Collect every scoring window.
        var candidates: [Candidate] = []
        for start in 0..<tokens.count {
            let maxLen = min(maxWindow, tokens.count - start)
            for len in 1...maxLen {
                let window = Array(tokens[start..<(start + len)])
                guard let (canonical, score) = bestMatch(for: window, in: entries, languages: languages) else { continue }
                candidates.append(Candidate(start: start, len: len, canonical: canonical, score: score))
            }
        }

        // 2. Sort by score desc; tie → shorter window, then earlier position.
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.len != b.len { return a.len < b.len }
            return a.start < b.start
        }

        // 3. Greedily accept non-overlapping candidates.
        var taken = [Bool](repeating: false, count: tokens.count)
        var chosen: [Int: Candidate] = [:]
        for candidate in candidates {
            let range = candidate.start..<(candidate.start + candidate.len)
            if range.contains(where: { taken[$0] }) { continue }
            range.forEach { taken[$0] = true }
            chosen[candidate.start] = candidate
        }
        return chosen
    }

    // MARK: - Matching

    /// Returns the best vocabulary match for a window of tokens along with its
    /// similarity score, or nil if none clears the similarity threshold.
    ///
    /// For each candidate language, the window and the vocabulary entry are folded
    /// with the same language rules and compared; the highest score across all
    /// languages wins. This lets one vocabulary word match multiple pronunciations
    /// (e.g. "PyTorch" said the French or English way).
    private static func bestMatch(for window: [String], in entries: [Entry], languages: [String]) -> (canonical: String, score: Double)? {
        // Join the alphanumeric cores of the window (drops punctuation and the
        // spaces between split tokens): ["data", "ecou."] → "dataecou".
        let joined = window.map { alphanumericCore(of: $0) }.joined()
        guard !joined.isEmpty else { return nil }

        // Precompute the window's key per language once.
        let windowKeys = phoneticKeys(for: joined, languages: languages)
        guard !windowKeys.isEmpty else { return nil }

        var best: (canonical: String, score: Double)?
        for entry in entries {
            var entryScore = 0.0
            for language in languages {
                guard let wk = windowKeys[language], let ek = entry.keysByLanguage[language] else { continue }
                // Keys too short for the threshold to discriminate: only accept a
                // case-insensitive spelling match (still fixes casing, e.g. "go" → "Go").
                if ek.count < minKeyLengthForFuzzyMatch || wk.count < minKeyLengthForFuzzyMatch {
                    if joined.caseInsensitiveCompare(alphanumericCore(of: entry.canonical)) == .orderedSame {
                        entryScore = 1
                    }
                    continue
                }
                entryScore = max(entryScore, similarity(wk, ek))
            }
            if entryScore >= similarityThreshold, entryScore > (best?.score ?? 0) {
                best = (entry.canonical, entryScore)
            }
        }
        return best
    }

    // MARK: - Languages

    /// The languages to try when matching: the user's transcription language
    /// (if known) plus English, deduplicated and order-preserving. English is
    /// always included because most tech proper nouns are English and may be
    /// pronounced the English way regardless of the dictation language.
    private static func candidateLanguages(for languageCode: String?) -> [String] {
        var languages: [String] = []
        if let code = languageCode?.lowercased(), !code.isEmpty {
            // Normalize e.g. "en-US" → "en".
            languages.append(String(code.prefix(2)))
        }
        if !languages.contains("en") { languages.append("en") }
        return languages
    }

    // MARK: - Phonetic Key

    /// Computes the phonetic key of `word` for each candidate language.
    /// - Returns: A map `language → key`, skipping languages that fold to empty.
    private static func phoneticKeys(for word: String, languages: [String]) -> [String: String] {
        var keys: [String: String] = [:]
        for language in languages {
            let key = phoneticKey(word, language: language)
            if !key.isEmpty { keys[language] = key }
        }
        return keys
    }

    /// Collapses a word to a coarse phonetic key so different spellings of the
    /// same sound converge. Heuristic — not a full phonemizer, but enough that
    /// "novaria", "novarya" and "nova ria" map to nearby keys.
    /// Language-specific pronunciation rules run first, then a common fold.
    static func phoneticKey(_ word: String, language: String) -> String {
        commonFold(languagePrefold(language, word))
    }

    /// Applies language-specific pronunciation rules before the common fold.
    /// Extensible: add cases for other languages as needed. An unknown language
    /// falls through to the common fold only (a safe, neutral default).
    private static func languagePrefold(_ language: String, _ word: String) -> String {
        var s = word.lowercased()
        switch language {
        case "fr":
            s = s.replacingOccurrences(of: "ill", with: "y")   // French "-ille-" ≈ /j/
        case "en":
            s = s.replacingOccurrences(of: "y", with: "ai")    // "py", "my" → /aɪ/
            s = s.replacingOccurrences(of: "igh", with: "ai")  // "light"
            s = s.replacingOccurrences(of: "oa", with: "o")    // "board"
        default:
            break
        }
        return s
    }

    /// Language-neutral fold: strip diacritics, keep letters, collapse common
    /// digraphs and single-letter sounds, dedupe doubled letters, drop a trailing
    /// schwa-ish vowel that models often add or drop.
    private static func commonFold(_ word: String) -> String {
        // Lowercase and strip diacritics: "dataïkou" → "dataikou".
        var s = word.folding(options: .diacriticInsensitive, locale: nil).lowercased()

        // Keep letters only.
        s = String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) })
        guard !s.isEmpty else { return "" }

        // Digraph / sound-alike folding (order matters).
        let digraphs: [(String, String)] = [
            // "eau" must precede its shorter components so it is consumed as
            // one sound (rather than becoming "i" + "o" via "ea" then "au").
            ("eau", "o"),
            ("ph", "f"),
            ("qu", "k"),
            ("ck", "k"),
            ("ch", "k"),
            ("ou", "u"),
            ("oo", "u"),
            ("ee", "i"),
            ("ea", "i"),
            ("ai", "e"),
            ("ei", "e"),
            ("au", "o"),
        ]
        for (from, to) in digraphs {
            s = s.replacingOccurrences(of: from, with: to)
        }

        // Single-letter sound folding: c/q/k → k, y → i, w → v, z → s.
        var folded = ""
        for ch in s {
            switch ch {
            case "c", "q": folded.append("k")
            case "y": folded.append("i")
            case "w": folded.append("v")
            case "z": folded.append("s")
            default: folded.append(ch)
            }
        }

        // Collapse doubled letters: "datta" → "data".
        var deduped = ""
        var last: Character?
        for ch in folded {
            if ch != last { deduped.append(ch) }
            last = ch
        }

        // Drop a trailing schwa-ish vowel that speakers/models often add or
        // drop ("novaria" vs "novariou" → both end effectively the same).
        if let lastChar = deduped.last, "aeiou".contains(lastChar), deduped.count > 1 {
            deduped.removeLast()
        }

        return deduped
    }

    // MARK: - Similarity

    /// Normalized similarity in [0, 1]: 1 - editDistance / maxLength.
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1 }
        let dist = levenshtein(Array(a), Array(b))
        return 1 - Double(dist) / Double(maxLen)
    }

    /// Classic Levenshtein edit distance (two-row DP). Small inputs only.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    // MARK: - Tokenization

    /// Splits text into non-whitespace tokens and the whitespace runs between
    /// them, so the rebuild in `correct(_:vocabulary:languageCode:)` can restore
    /// the exact original spacing.
    private static func tokenize(_ text: String) -> (tokens: [String], separators: [String]) {
        var tokens: [String] = []
        var separators: [String] = []
        var currentToken = ""
        var currentSep = ""
        var inToken = false

        for ch in text {
            if ch.isWhitespace {
                if inToken {
                    tokens.append(currentToken)
                    currentToken = ""
                    inToken = false
                    currentSep = ""
                }
                currentSep.append(ch)
            } else {
                if !inToken {
                    // Leading whitespace before the first token becomes separators[0].
                    separators.append(currentSep)
                    currentSep = ""
                    inToken = true
                }
                currentToken.append(ch)
            }
        }
        if inToken {
            tokens.append(currentToken)
            separators.append(currentSep)  // trailing whitespace (usually empty)
        } else if !currentSep.isEmpty {
            separators.append(currentSep)
        }
        return (tokens, separators)
    }

    // MARK: - Affixes

    /// Splits a token into (leadingPunctuation, core, trailingPunctuation).
    private static func affixes(of token: String) -> (leading: String, trailing: String) {
        let chars = Array(token)
        var start = 0
        var end = chars.count
        while start < end, !chars[start].isLetter, !chars[start].isNumber { start += 1 }
        while end > start, !chars[end - 1].isLetter, !chars[end - 1].isNumber { end -= 1 }
        let leading = String(chars[0..<start])
        let trailing = String(chars[end..<chars.count])
        return (leading, trailing)
    }

    /// The alphanumeric content of a token or vocabulary entry. This also
    /// removes separators within a multi-word canonical entry, allowing an
    /// exact short-key match such as "a b" → "A B".
    private static func alphanumericCore(of text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
