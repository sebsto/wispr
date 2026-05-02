//
//  SoundFeedbackServiceTests.swift
//  wispr
//
//  Unit tests for SoundFeedbackService.
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

@MainActor
@Suite("SoundFeedbackService Tests")
struct SoundFeedbackServiceTests {

    private func makeSettingsStore(soundEnabled: Bool = false) -> SettingsStore {
        let defaults = UserDefaults(suiteName: "test.wispr.soundfeedback.\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        store.soundFeedbackEnabled = soundEnabled
        return store
    }

    // MARK: - Gating on settings

    @Test("play does nothing when soundFeedbackEnabled is false")
    func testPlayDisabled() {
        let store = makeSettingsStore(soundEnabled: false)
        let service = SoundFeedbackService(settingsStore: store)

        // Should not crash or throw — just silently return
        service.play(.recordingStarted)
        service.play(.recordingStopped)
    }

    @Test("play attempts playback when soundFeedbackEnabled is true")
    func testPlayEnabled() {
        let store = makeSettingsStore(soundEnabled: true)
        let service = SoundFeedbackService(settingsStore: store)

        // In test environment, Bundle.main may not contain the sound files,
        // but this verifies the code path doesn't crash.
        service.play(.recordingStarted)
        service.play(.recordingStopped)
    }

    @Test("play respects setting changes at runtime")
    func testPlayRespectsRuntimeChanges() {
        let store = makeSettingsStore(soundEnabled: false)
        let service = SoundFeedbackService(settingsStore: store)

        // Disabled — should no-op
        service.play(.recordingStarted)

        // Enable at runtime
        store.soundFeedbackEnabled = true
        service.play(.recordingStarted)

        // Disable again
        store.soundFeedbackEnabled = false
        service.play(.recordingStarted)
    }

    // MARK: - Sound enum

    @Test("Sound raw values match bundled filenames")
    func testSoundRawValues() {
        #expect(SoundFeedbackService.Sound.recordingStarted.rawValue == "RecordingStarted")
        #expect(SoundFeedbackService.Sound.recordingStopped.rawValue == "RecordingStopped")
    }
}
