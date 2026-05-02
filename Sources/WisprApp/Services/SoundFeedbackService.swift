//
//  SoundFeedbackService.swift
//  wispr
//
//  Plays short audio cues for recording state transitions.
//  Uses bundled sound files so playback is independent of system sounds.
//

import WisprCore
import AVFoundation
import os

@MainActor
final class SoundFeedbackService {

    enum Sound: String {
        case recordingStarted = "RecordingStarted"
        case recordingStopped = "RecordingStopped"
    }

    private let settingsStore: SettingsStore
    private var players: [Sound: AVAudioPlayer] = [:]

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func play(_ sound: Sound) {
        guard settingsStore.soundFeedbackEnabled else { return }

        if let player = players[sound] {
            player.stop()
            player.currentTime = 0
            player.play()
            return
        }

        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "aiff") else {
            Log.stateManager.warning("Sound file '\(sound.rawValue).aiff' not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            players[sound] = player
            player.play()
        } catch {
            Log.stateManager.warning("Failed to play sound '\(sound.rawValue)': \(error.localizedDescription)")
        }
    }
}
