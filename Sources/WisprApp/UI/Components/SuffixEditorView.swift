//
//  SuffixEditorView.swift
//  wispr
//
//  A compact editor for the auto-suffix string that renders whitespace
//  characters visually so the user can see exactly what will be appended.
//

import SwiftUI

extension String {
    /// This string with whitespace drawn as visible glyphs: space → `␣`,
    /// newline → `↵`, tab → `⇥`; `∅` when empty. Other characters are kept.
    var visibleWhitespace: String {
        var result = ""
        for char in self {
            switch char {
            case " ":  result.append("␣")
            case "\n": result.append("↵")
            case "\r": result.append("↵")
            case "\t": result.append("⇥")
            default:   result.append(char)
            }
        }
        return result.isEmpty ? "∅" : result
    }
}

/// Displays the current suffix with visible whitespace glyphs and offers
/// a picker of common presets plus a custom-edit option.
struct SuffixEditorView: View {
    @Binding var suffixText: String
    @State private var isEditing = false

    /// Common suffix presets. The raw value is the actual suffix string.
    private static let presets: [(label: String, value: String)] = [
        (" ",  " "),
        (". ", ". "),
        (".",  "."),
        (", ", ", "),
        ("? ", "? "),
        ("! ", "! "),
    ]

    var body: some View {
        HStack(spacing: 6) {
            // Visual representation of the current suffix
            Text(suffixText.visibleWhitespace)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Current suffix: \(accessibilityDescription(for: suffixText))")

            Menu {
                Section("Common") {
                    ForEach(Self.presets, id: \.value) { preset in
                        Button {
                            suffixText = preset.value
                        } label: {
                            HStack {
                                Text(preset.label.visibleWhitespace)
                                    .font(.system(.body, design: .monospaced))
                                if suffixText == preset.value {
                                    Image(systemName: SFSymbols.checkmarkPlain)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Custom…") {
                        isEditing = true
                    }
                }
            } label: {
                Image(systemName: SFSymbols.chevronUpDown)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Change suffix")
            .accessibilityHint("Opens a menu to pick a common suffix or enter a custom one")
        }
        .popover(isPresented: $isEditing) {
            SuffixCustomEditor(suffixText: $suffixText)
        }
    }

    /// Produces a spoken description for VoiceOver.
    private func accessibilityDescription(for text: String) -> String {
        var parts: [String] = []
        for char in text {
            switch char {
            case " ":  parts.append("space")
            case "\n": parts.append("newline")
            case "\r": parts.append("newline")
            case "\t": parts.append("tab")
            default:   parts.append(String(char))
            }
        }
        return parts.isEmpty ? "empty" : parts.joined(separator: ", ")
    }
}

/// A small popover for typing a custom suffix with a live preview.
private struct SuffixCustomEditor: View {
    @Binding var suffixText: String
    @Environment(\.dismiss) private var dismiss
    /// Seeded from the current suffix so the first frame already shows it.
    @State private var draft: String

    init(suffixText: Binding<String>) {
        _suffixText = suffixText
        _draft = State(initialValue: suffixText.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom Suffix")
                .font(.headline)

            TextField("Type your suffix", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            HStack(spacing: 4) {
                Text("Preview:")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Text(previewString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    suffixText = draft
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 240)
    }

    private var previewString: String {
        draft.visibleWhitespace
    }
}
