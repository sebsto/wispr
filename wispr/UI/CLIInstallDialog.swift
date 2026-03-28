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
    @Environment(\.dismiss) private var dismiss

    private var cliSourcePath: String {
        "\(appBundlePath)/Contents/Resources/bin/wispr-cli"
    }

    private var installCommand: String {
        "ln -sf \"\(cliSourcePath)\" /usr/local/bin/wispr"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install Command Line Tool")
                .font(.headline)

            Text("Run this command in Terminal to make `wispr` available from any shell session:")

            GroupBox {
                Text(installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            HStack {
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding()
        .frame(width: 500)
    }
}
