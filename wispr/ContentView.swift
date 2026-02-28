//
//  ContentView.swift
//  wispr
//
//  Created by Stormacq, Sebastien on 26/02/2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Wispr")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Voice dictation, on-device")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 300, minHeight: 200)
        .padding(32)
    }
}

#Preview {
    ContentView()
}
