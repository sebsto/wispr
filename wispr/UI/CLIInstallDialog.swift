//
//  CLIInstallDialog.swift
//  wispr
//
//  Dialog showing the shell command to install the wispr CLI tool
//  to /usr/local/bin/ via a symlink.
//

import SwiftUI

struct CLIInstallDialogView: View {
    let appBundlePath: String
    let symlinkPath: String
    var onDismiss: (() -> Void)?

    @State private var copied = false

    private var cliSourcePath: String {
        "\(appBundlePath)/Contents/Resources/bin/wispr-cli"
    }

    private var installCommand: String {
        "sudo ln -sf \"\(cliSourcePath)\" \(symlinkPath)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Install Command Line Tool", systemImage: SFSymbols.terminal)
                .font(.headline)

            Text("Run this command in Terminal to make **wispr** available from any shell session:")
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                    copied = true
                } label: {
                    Label(
                        copied ? "Copied!" : "Copy Command",
                        systemImage: copied ? SFSymbols.checkmarkPlain : SFSymbols.copy
                    )
                }
                .controlSize(.large)

                Spacer()

                Button("Done") { onDismiss?() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
