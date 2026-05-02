//
//  SuffixEditorView.swift
//  wispr
//
//  A compact editor for the auto-suffix string that renders whitespace
//  characters visually so the user can see exactly what will be appended.
//

import SwiftUI

/// Renders whitespace as visible glyphs: space → `␣`, newline → `↵`, tab → `⇥`.
/// Non-whitespace characters pass through unchanged.
private func visibleWhitespace(for text: String) -> String {
    var result = ""
    for char in text {
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
            Text(visibleWhitespace(for: suffixText))
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
                                Text(visibleWhitespace(for: preset.label))
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
            SuffixCustomEditor(suffixText: $suffixText, isPresented: $isEditing)
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
    @Binding var isPresented: Bool
    @State private var draft: String = ""

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
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    suffixText = draft
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 240)
        .onAppear { draft = suffixText }
    }

    private var previewString: String {
        visibleWhitespace(for: draft)
    }
}
