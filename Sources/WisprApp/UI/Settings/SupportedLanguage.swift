//
//  SupportedLanguage.swift
//  wispr
//

/// Languages supported by Whisper models for transcription.
struct SupportedLanguage: Identifiable, Hashable, Sendable {
    let id: String   // ISO 639-1 code
    let name: String // Display name

    static let all: [SupportedLanguage] = [
        SupportedLanguage(id: "en", name: "English"),
        SupportedLanguage(id: "es", name: "Spanish"),
        SupportedLanguage(id: "fr", name: "French"),
        SupportedLanguage(id: "de", name: "German"),
        SupportedLanguage(id: "it", name: "Italian"),
        SupportedLanguage(id: "pt", name: "Portuguese"),
        SupportedLanguage(id: "nl", name: "Dutch"),
        SupportedLanguage(id: "ja", name: "Japanese"),
        SupportedLanguage(id: "ko", name: "Korean"),
        SupportedLanguage(id: "zh", name: "Chinese"),
        SupportedLanguage(id: "ru", name: "Russian"),
        SupportedLanguage(id: "ar", name: "Arabic"),
        SupportedLanguage(id: "hi", name: "Hindi"),
    ]
}
