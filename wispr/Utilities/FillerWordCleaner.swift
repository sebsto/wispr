//
//  FillerWordCleaner.swift
//  wispr
//
//  Removes common filler words from transcribed text.
//  Supports English and French fillers.
//

import Foundation

enum FillerWordCleaner {

    // Core filler alternation. uh-huh MUST come before uh so the longer
    // match is attempted first (Swift Regex uses left-to-right alternation).
    // Similarly erm before er.
    //
    // English: um, uh, ah, oh, eh, er, erm, hmm, hm, mhm, uh-huh
    // French:  euh, heu, hein, bah, ben, beh, pfff+, mouais
    private static let filler =
        #"uh[\-\u2010\u2011\u2012\u2013\u2014]huh|um|uh|ah|oh|eh|erm|er|hmm|hm|mhm|euh|heu|hein|bah|ben|beh|pf{2,}|mouais"#

    /// Matches a filler between two punctuation marks, consuming only the
    /// leading separator so the trailing one stays for the next token.
    /// e.g. in "Well, um, I" matches ", um" (leaving ", I").
    private static let fillerBetweenPunct: Regex<AnyRegexOutput> = {
        try! Regex(
            #"[,;:]\s*\b(?:"# + filler + #")\b\s*(?=[,;:])"#
        ).ignoresCase()
    }()

    /// Matches a bare filler word with optional surrounding whitespace and
    /// an optional trailing punctuation mark (for cases like "um, I think").
    private static let fillerBare: Regex<AnyRegexOutput> = {
        try! Regex(
            #"\s*\b(?:"# + filler + #")\b[,;:]?\s*"#
        ).ignoresCase()
    }()

    /// Collapse runs of two or more spaces.
    private static let multiSpace: Regex<Substring> = {
        try! Regex(#" {2,}"#)
    }()

    /// Removes filler words from the given text and collapses leftover whitespace.
    ///
    /// Uses two passes:
    /// 1. Remove fillers sitting between punctuation (e.g. ", um,") — consumes
    ///    the leading separator, keeps the trailing one via lookahead.
    /// 2. Remove remaining bare fillers with surrounding whitespace.
    ///
    /// - Parameter text: Raw transcription text.
    /// - Returns: Cleaned text with filler words removed.
    static func clean(_ text: String) -> String {
        // Pass 1: fillers between punctuation — replace with empty to avoid orphaned separators
        let pass1 = text.replacing(fillerBetweenPunct, with: "")
        // Pass 2: remaining bare fillers
        let pass2 = pass1.replacing(fillerBare, with: " ")
        let collapsed = pass2.replacing(multiSpace, with: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
