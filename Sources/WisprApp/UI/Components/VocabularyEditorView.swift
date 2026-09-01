//
//  VocabularyEditorView.swift
//  wispr
//
//  A compact editor for the custom vocabulary list: correctly spelled proper
//  nouns (client names, product names) that transcription should be biased
//  toward. Supports adding a new word and removing existing ones.
//

import SwiftUI

/// Editor for the custom vocabulary word list bound to `SettingsStore.customVocabulary`.
struct VocabularyEditorView: View {
    @Binding var vocabulary: [String]
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Add-a-word row.
            HStack(spacing: 6) {
                TextField("Add a word (e.g. kubectl)", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                    .accessibilityLabel("New vocabulary word")

                Button(action: addWord) {
                    Image(systemName: SFSymbols.addCircle)
                }
                .buttonStyle(.borderless)
                .disabled(trimmedNewWord.isEmpty)
                .accessibilityLabel("Add word")
            }

            // Existing words.
            if vocabulary.isEmpty {
                Text("No words yet. Add client or product names that are often mis-transcribed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vocabulary, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            remove(word)
                        } label: {
                            Image(systemName: SFSymbols.removeCircle)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(word)")
                    }
                }
            }
        }
    }

    private var trimmedNewWord: String {
        newWord.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adds the typed word if it is non-empty and not already present
    /// (case-insensitive), then clears the field.
    private func addWord() {
        let word = trimmedNewWord
        guard !word.isEmpty else { return }
        guard !vocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else {
            newWord = ""
            return
        }
        vocabulary.append(word)
        newWord = ""
    }

    private func remove(at index: Int) {
        guard vocabulary.indices.contains(index) else { return }
        vocabulary.remove(at: index)
    }

    private func remove(_ word: String) {
        guard let index = vocabulary.firstIndex(of: word) else { return }
        remove(at: index)
    }
}
