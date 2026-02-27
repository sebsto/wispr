//
//  AudioInputDevice.swift
//  wispr
//
//  Created by Kiro
//

import Foundation
import CoreAudio

/// Represents an audio input device
struct AudioInputDevice: Identifiable, Sendable, Codable, Equatable {
    let id: UInt32  // AudioDeviceID
    let name: String
    let uid: String
}
