//
//  WispError.swift
//  wispr
//
//  Error types for the Wisp voice dictation application.
//

import Foundation

/// Comprehensive error type for all Wisp operations.
/// Conforms to Error, Sendable (for Swift 6 concurrency), and Equatable.
enum WispError: Error, Sendable, Equatable {
    // MARK: - Permissions
    
    /// Microphone permission has been denied by the user.
    case microphonePermissionDenied
    
    /// Accessibility permission has been denied by the user.
    case accessibilityPermissionDenied
    
    // MARK: - Audio
    
    /// No audio input device is available on the system.
    case noAudioDeviceAvailable
    
    /// The selected audio input device was disconnected during operation.
    case audioDeviceDisconnected
    
    /// Audio recording failed with a specific error message.
    case audioRecordingFailed(String)
    
    // MARK: - Transcription
    
    /// Failed to load the Whisper model with a specific error message.
    case modelLoadFailed(String)
    
    /// The requested Whisper model has not been downloaded.
    case modelNotDownloaded
    
    /// Transcription failed with a specific error message.
    case transcriptionFailed(String)
    
    /// Transcription completed but produced no text output.
    case emptyTranscription
    
    // MARK: - Text Insertion
    
    /// Text insertion failed with a specific error message.
    case textInsertionFailed(String)
    
    // MARK: - Hotkey
    
    /// The configured hotkey conflicts with a system or application shortcut.
    case hotkeyConflict(String)
    
    /// Failed to register the global hotkey.
    case hotkeyRegistrationFailed
    
    // MARK: - Model Management
    
    /// Model download failed with a specific error message.
    case modelDownloadFailed(String)
    
    /// Model validation failed after download with a specific error message.
    case modelValidationFailed(String)
    
    /// Model deletion failed with a specific error message.
    case modelDeletionFailed(String)
    
    /// No Whisper models are available (all deleted or none downloaded).
    case noModelsAvailable
}
