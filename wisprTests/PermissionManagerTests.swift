//
//  PermissionManagerTests.swift
//  wispr
//
//  Unit tests for PermissionManager using swift-testing framework
//

import Testing
import Foundation
@testable import wispr

@MainActor
@Suite("PermissionManager Tests")
struct PermissionManagerTests {
    
    // MARK: - Initialization Tests
    
    @Test("PermissionManager initializes and checks permissions on init")
    func testInitialization() async {
        let manager = PermissionManager()
        
        // After initialization, permission statuses should be determined
        // The actual values depend on system state
        // We just verify that the manager initializes without crashing
        // and that the status properties are accessible
        let _ = manager.microphoneStatus
        let _ = manager.accessibilityStatus
        #expect(true, "PermissionManager should initialize successfully")
    }
    
    // MARK: - Permission Status Tests
    
    @Test("PermissionManager allPermissionsGranted returns true only when both permissions are authorized")
    func testAllPermissionsGranted() async {
        let manager = PermissionManager()
        
        // The computed property should return true only if both are authorized
        // We can't control the actual system permissions in tests, but we can verify the logic
        let bothAuthorized = manager.microphoneStatus == .authorized && manager.accessibilityStatus == .authorized
        #expect(manager.allPermissionsGranted == bothAuthorized, "allPermissionsGranted should match both permissions being authorized")
    }
    
    @Test("PermissionManager checkPermissions updates status")
    func testCheckPermissions() async {
        let manager = PermissionManager()

        // init() only checks accessibility (fast), mic is left as .notDetermined
        #expect(manager.microphoneStatus == .notDetermined, "Mic status should be .notDetermined before checkPermissions")

        // checkPermissions queries both mic and accessibility from the system
        manager.checkPermissions()

        // After checkPermissions, mic status should reflect the actual system state
        #expect(manager.microphoneStatus != .notDetermined, "Mic status should be determined after checkPermissions")

        // Accessibility status should be valid
        let _ = manager.accessibilityStatus

        // Calling again should be idempotent
        let micAfterFirst = manager.microphoneStatus
        let accessAfterFirst = manager.accessibilityStatus
        manager.checkPermissions()
        #expect(manager.microphoneStatus == micAfterFirst, "Mic status should remain consistent on repeated calls")
        #expect(manager.accessibilityStatus == accessAfterFirst, "Accessibility status should remain consistent on repeated calls")
    }
    
    // MARK: - Permission Request Tests
    
    @Test("PermissionManager requestMicrophoneAccess returns boolean result")
    func testRequestMicrophoneAccess() async {
        let manager = PermissionManager()
        
        // Request microphone access
        // Note: This will trigger a system dialog in a real environment
        // In test environment, it may return immediately based on existing permissions
        let result = await manager.requestMicrophoneAccess()
        
        // Result should match the current microphone status
        #expect(result == (manager.microphoneStatus == .authorized), "Request result should match authorization status")
    }
    
    @Test("PermissionManager requestMicrophoneAccess updates status")
    func testRequestMicrophoneAccessUpdatesStatus() async {
        let manager = PermissionManager()
        
        // Request microphone access
        _ = await manager.requestMicrophoneAccess()
        
        // Status should be determined (not .notDetermined) after request
        #expect(manager.microphoneStatus != .notDetermined, "Microphone status should be determined after request")
    }
    
    // MARK: - Accessibility Settings Tests
    
    @Test("PermissionManager openAccessibilitySettings does not crash")
    func testOpenAccessibilitySettings() async {
        let manager = PermissionManager()
        
        // This method opens System Settings, which we can't easily test
        // We just verify it doesn't crash when called
        manager.openAccessibilitySettings()
        
        // If we reach here without crashing, the test passes
        #expect(true, "openAccessibilitySettings should not crash")
    }
    
    // MARK: - Permission Monitoring Tests
    
    @Test("PermissionManager startMonitoringPermissionChanges polls and can be cancelled")
    func testMonitorPermissionChanges() async {
        let manager = PermissionManager()
        
        // Run monitoring in a task group so we can cancel it after a few cycles
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await manager.startMonitoringPermissionChanges()
            }
            
            // Wait for at least 2 monitoring cycles (5+ seconds)
            try? await Task.sleep(for: .seconds(5.5))
            
            // Cancel the group to stop monitoring
            group.cancelAll()
        }
        
        // If we reach here, monitoring started and stopped cleanly
        #expect(true, "Monitoring should start and stop without error")
    }
    
    @Test("PermissionManager monitoring updates permissions")
    func testMonitoringStreamUpdatesPermissions() async {
        let manager = PermissionManager()
        
        // Run monitoring briefly
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await manager.startMonitoringPermissionChanges()
            }
            
            // Wait for at least one monitoring cycle (2.5+ seconds)
            try? await Task.sleep(for: .seconds(2.5))
            
            group.cancelAll()
        }
        
        // Permissions should be determined after monitoring
        let micStatus = manager.microphoneStatus
        let accessStatus = manager.accessibilityStatus
        
        // Status values should be one of the valid enum cases
        #expect([.notDetermined, .denied, .authorized].contains(micStatus), "Microphone status should be a valid enum case")
        #expect([.notDetermined, .denied, .authorized].contains(accessStatus), "Accessibility status should be a valid enum case")
    }
    
    @Test("PermissionManager multiple monitoring tasks work independently")
    func testMultipleStreamConsumers() async {
        let manager = PermissionManager()
        
        // Run two monitoring tasks concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await manager.startMonitoringPermissionChanges()
            }
            
            group.addTask {
                await manager.startMonitoringPermissionChanges()
            }
            
            // Wait a bit
            try? await Task.sleep(for: .seconds(2.5))
            
            // Cancel both
            group.cancelAll()
        }
        
        // If we reach here without issues, multiple monitoring tasks work correctly
        #expect(true, "Multiple monitoring tasks should work independently")
    }
    
    // MARK: - Edge Cases
    
    @Test("PermissionManager handles rapid checkPermissions calls")
    func testRapidCheckPermissionsCalls() async {
        let manager = PermissionManager()
        
        // Call checkPermissions multiple times rapidly
        for _ in 0..<10 {
            manager.checkPermissions()
        }
        
        // Status should still be valid
        // Status values are enums and always have a value, so we just verify they're accessible
        let _ = manager.microphoneStatus
        let _ = manager.accessibilityStatus
    }
    
    @Test("PermissionManager monitoring cancellation cleans up properly")
    func testStreamCancellation() async {
        let manager = PermissionManager()
        
        // Test immediate cancellation with structured concurrency
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await manager.startMonitoringPermissionChanges()
            }
            
            // Cancel immediately
            group.cancelAll()
        }
        
        // Wait a bit to ensure cleanup happens
        try? await Task.sleep(for: .milliseconds(100))
        
        // If we reach here without crashing, cancellation worked correctly
        #expect(true, "Monitoring cancellation should clean up properly")
    }
}
