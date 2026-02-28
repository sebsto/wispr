import Foundation
import AVFAudio
import ApplicationServices
import AppKit

/// Manages microphone and accessibility permissions for the Wisp application.
/// This class checks permission status, requests permissions, and monitors changes.
@MainActor
@Observable
final class PermissionManager {
    // MARK: - Published State
    
    /// Current status of microphone permission
    var microphoneStatus: PermissionStatus = .notDetermined
    
    /// Current status of accessibility permission
    var accessibilityStatus: PermissionStatus = .notDetermined
    
    /// Computed property indicating if all required permissions are granted
    var allPermissionsGranted: Bool {
        microphoneStatus == .authorized && accessibilityStatus == .authorized
    }
    
    // MARK: - Initialization

    init() {
        // Only check accessibility synchronously (fast, no hardware access).
        // Microphone status is left as .notDetermined and picked up by
        // startMonitoringPermissionChanges() within ~2 seconds. This avoids
        // calling AVAudioApplication.shared.recordPermission during bootstrap,
        // which blocks the main thread when the audio subsystem hasn't been
        // initialized (e.g. permission not yet granted).
        checkAccessibilityPermission()
    }

    // MARK: - Permission Checking

    /// Checks the current status of all required permissions.
    func checkPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
    }

    private func checkMicrophonePermission() {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .undetermined:
            microphoneStatus = .notDetermined
        case .denied:
            microphoneStatus = .denied
        case .granted:
            microphoneStatus = .authorized
        @unknown default:
            microphoneStatus = .notDetermined
        }
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus = trusted ? .authorized : .denied
    }
    
    // MARK: - Permission Requests
    
    /// Requests microphone access from the user
    /// - Returns: True if permission was granted, false otherwise
    @discardableResult
    func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
        checkMicrophonePermission()
        return microphoneStatus == .authorized
    }
    
    /// Opens System Settings to the Accessibility privacy pane
    /// This is required because accessibility permission cannot be requested programmatically
    func openAccessibilitySettings() {
        // Open System Settings to Privacy & Security > Accessibility
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
    
    // MARK: - Permission Monitoring
    
    /// Polls for permission changes every 2 seconds.
    /// Call this from a structured task context (e.g., a task group or .task modifier).
    /// Yields Void each time permissions are re-checked.
    func startMonitoringPermissionChanges() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            checkPermissions()
        }
    }
}
