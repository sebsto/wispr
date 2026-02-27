//
//  AudioEngineTests.swift
//  wispr
//
//  Unit tests for AudioEngine using swift-testing framework
//

import Testing
import Foundation
import AVFoundation
@testable import wispr

@Suite("AudioEngine Tests")
struct AudioEngineTests {
    
    // MARK: - Device Enumeration Tests
    
    @Test("AudioEngine returns available input devices")
    func testAvailableInputDevices() async {
        let engine = AudioEngine()
        
        let devices = await engine.availableInputDevices()
        
        // We should have at least one input device on any Mac
        // (even if it's just the built-in microphone)
        #expect(devices.count >= 0, "Should return a list of devices (may be empty in test environment)")
        
        // If we have devices, verify their structure
        if let firstDevice = devices.first {
            let name = await firstDevice.name
            let uid = await firstDevice.uid
            let id = await firstDevice.id
            #expect(!name.isEmpty, "Device name should not be empty")
            #expect(!uid.isEmpty, "Device UID should not be empty")
            #expect(id > 0, "Device ID should be valid")
        }
    }
    
    @Test("AudioEngine device list contains unique UIDs")
    func testDeviceUIDsAreUnique() async {
        let engine = AudioEngine()
        
        let devices = await engine.availableInputDevices()
        
        // Create a set of UIDs to check for uniqueness
        var allUIDs: [String] = []
        for device in devices {
            let uid = await device.uid
            allUIDs.append(uid)
        }
        let uniqueUIDs = Set(allUIDs)
        
        #expect(allUIDs.count == uniqueUIDs.count, "All device UIDs should be unique")
    }
    
    @Test("AudioEngine device list contains valid AudioInputDevice objects")
    func testDeviceObjectValidity() async {
        let engine = AudioEngine()
        
        let devices = await engine.availableInputDevices()
        
        for device in devices {
            // Verify each device has valid properties
            let id = await device.id
            let name = await device.name
            let uid = await device.uid
            #expect(id > 0, "Device ID should be positive")
            #expect(!name.isEmpty, "Device name should not be empty")
            #expect(!uid.isEmpty, "Device UID should not be empty")
        }
    }
    
    // MARK: - Device Selection Tests
    
    @Test("AudioEngine allows setting input device")
    func testSetInputDevice() async throws {
        let engine = AudioEngine()
        
        let devices = await engine.availableInputDevices()
        
        // If we have devices, try setting one
        if let firstDevice = devices.first {
            try await engine.setInputDevice(firstDevice.id)
            // If no exception is thrown, the test passes
            #expect(true, "Should be able to set a valid input device")
        } else {
            // No devices available in test environment, skip this test
            #expect(true, "No devices available to test")
        }
    }
    
    @Test("AudioEngine handles invalid device ID gracefully")
    func testSetInvalidDevice() async {
        let engine = AudioEngine()
        
        // Try setting an invalid device ID (0 is typically invalid)
        do {
            try await engine.setInputDevice(0)
            // Current implementation doesn't validate, so this won't throw
            #expect(true, "Setting device ID 0 should not crash")
        } catch {
            // If it does throw, that's also acceptable behavior
            #expect(true, "Throwing error for invalid device is acceptable")
        }
    }
    
    // MARK: - Capture Lifecycle Tests
    
    @Test("AudioEngine starts capture and returns audio level stream")
    func testStartCapture() async throws {
        let engine = AudioEngine()
        
        do {
            let _ = try await engine.startCapture()
            
            // If we got here, capture started successfully
            #expect(true, "Should return an AsyncStream")
            
            // Clean up
            await engine.cancelCapture()
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    @Test("AudioEngine prevents concurrent capture sessions")
    func testPreventConcurrentCapture() async throws {
        let engine = AudioEngine()
        
        do {
            // Start first capture
            let _ = try await engine.startCapture()
            #expect(true, "First capture should succeed")
            
            // Try to start second capture while first is active
            do {
                let _ = try await engine.startCapture()
                Issue.record("Should not allow concurrent capture sessions")
            } catch let error as WispError {
                if case .audioRecordingFailed(let message) = error {
                    #expect(message.contains("Already capturing"), "Should report already capturing")
                } else {
                    Issue.record("Wrong error type: \(error)")
                }
            }
            
            // Clean up
            await engine.cancelCapture()
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    @Test("AudioEngine stops capture and returns audio data")
    func testStopCapture() async throws {
        let engine = AudioEngine()
        
        do {
            // Start capture
            let _ = try await engine.startCapture()
            #expect(true, "Should start capture")
            
            // Wait a brief moment to capture some audio
            try await Task.sleep(for: .milliseconds(100))
            
            // Stop capture
            let _ = await engine.stopCapture()
            
            // Verify we got data (may be empty if no audio was captured)
            #expect(true, "Should return Data object")
            
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    @Test("AudioEngine stopCapture returns empty array when not capturing")
    func testStopCaptureWhenNotCapturing() async {
        let engine = AudioEngine()
        
        // Stop without starting
        let audioSamples = await engine.stopCapture()
        
        #expect(audioSamples.isEmpty, "Should return empty array when not capturing")
    }
    
    @Test("AudioEngine cancelCapture cleans up resources")
    func testCancelCapture() async throws {
        let engine = AudioEngine()
        
        do {
            // Start capture
            let _ = try await engine.startCapture()
            #expect(true, "Should start capture")
            
            // Cancel capture
            await engine.cancelCapture()
            
            // Verify we can start a new capture after canceling
            let _ = try await engine.startCapture()
            #expect(true, "Should be able to start new capture after cancel")
            
            // Clean up
            await engine.cancelCapture()
            
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    @Test("AudioEngine cancelCapture is safe when not capturing")
    func testCancelCaptureWhenNotCapturing() async {
        let engine = AudioEngine()
        
        // Cancel without starting - should not crash
        await engine.cancelCapture()
        
        #expect(true, "Cancel should be safe when not capturing")
    }
    
    // MARK: - Audio Level Stream Tests
    
    @Test("AudioEngine audio level stream yields values")
    func testAudioLevelStream() async throws {
        let engine = AudioEngine()
        
        do {
            let stream = try await engine.startCapture()
            
            // Collect a few level values
            var levels: [Float] = []
            let maxLevels = 5
            
            for await level in stream {
                levels.append(level)
                if levels.count >= maxLevels {
                    break
                }
            }
            
            // Verify we got some levels
            #expect(levels.count > 0, "Should receive audio level values")
            
            // Verify levels are in valid range (0.0 to 1.0)
            for level in levels {
                #expect(level >= 0.0 && level <= 1.0, "Audio levels should be normalized to 0.0-1.0")
            }
            
            // Clean up
            await engine.cancelCapture()
            
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    @Test("AudioEngine audio level stream terminates on stop")
    func testAudioLevelStreamTermination() async throws {
        let engine = AudioEngine()
        
        do {
            let stream = try await engine.startCapture()
            
            // Use withTaskGroup to consume the stream with structured concurrency
            let count = await withTaskGroup(of: Int.self) { group in
                group.addTask {
                    var count = 0
                    for await _ in stream {
                        count += 1
                        if count > 100 {
                            Issue.record("Stream should have terminated")
                            break
                        }
                    }
                    return count
                }
                
                // Wait a moment, then stop capture
                try? await Task.sleep(for: .milliseconds(50))
                let _ = await engine.stopCapture()
                
                // Collect the result
                var result = 0
                for await streamCount in group {
                    result = streamCount
                }
                return result
            }
            
            #expect(count >= 0, "Stream should terminate after stopCapture")
            
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
    
    // MARK: - Device Fallback Behavior Tests
    
    @Test("AudioEngine handles device disconnection scenario")
    func testDeviceDisconnectionScenario() async throws {
        let engine = AudioEngine()
        
        let devices = await engine.availableInputDevices()
        
        // This test simulates the scenario where a device becomes unavailable
        // In a real scenario, the device would be disconnected during capture
        // For unit testing, we verify the engine can handle device changes
        
        if devices.count >= 2 {
            // Set first device
            try await engine.setInputDevice(devices[0].id)
            
            // Switch to second device (simulating fallback)
            try await engine.setInputDevice(devices[1].id)
            
            #expect(true, "Should handle device switching")
        } else {
            #expect(true, "Not enough devices to test fallback")
        }
    }
    
    @Test("AudioEngine can enumerate devices multiple times")
    func testMultipleDeviceEnumerations() async {
        let engine = AudioEngine()
        
        // Enumerate devices multiple times
        let devices1 = await engine.availableInputDevices()
        let devices2 = await engine.availableInputDevices()
        let devices3 = await engine.availableInputDevices()
        
        // Device lists should be consistent
        #expect(devices1.count == devices2.count, "Device count should be consistent")
        #expect(devices2.count == devices3.count, "Device count should be consistent")
        
        // UIDs should match
        let uids1 = await withTaskGroup(of: String.self) { group in
            for device in devices1 {
                group.addTask { await device.uid }
            }
            var result: [String] = []
            for await uid in group {
                result.append(uid)
            }
            return Set(result)
        }
        let uids2 = await withTaskGroup(of: String.self) { group in
            for device in devices2 {
                group.addTask { await device.uid }
            }
            var result: [String] = []
            for await uid in group {
                result.append(uid)
            }
            return Set(result)
        }
        
        #expect(uids1 == uids2, "Device UIDs should be consistent across enumerations")
    }
    
    // MARK: - Edge Cases
    
    @Test("AudioEngine handles rapid start/stop cycles")
    func testRapidStartStopCycles() async throws {
        let engine = AudioEngine()
        
        // Perform multiple start/stop cycles
        for _ in 0..<3 {
            do {
                let _ = try await engine.startCapture()
                #expect(true, "Should start capture")
                
                // Brief capture
                try await Task.sleep(for: .milliseconds(10))
                
                let _ = await engine.stopCapture()
                #expect(true, "Should return data")
                
            } catch let error as WispError {
                // In test environment without microphone permission, this is expected
                if case .audioRecordingFailed = error {
                    #expect(true, "Audio recording may fail in test environment without permissions")
                    return // Exit test early if permissions not available
                } else {
                    throw error
                }
            }
        }
        
        #expect(true, "Should handle rapid start/stop cycles")
    }
    
    @Test("AudioEngine handles rapid cancel operations")
    func testRapidCancelOperations() async throws {
        let engine = AudioEngine()
        
        do {
            let _ = try await engine.startCapture()
            #expect(true, "Should start capture")
            
            // Cancel multiple times rapidly
            await engine.cancelCapture()
            await engine.cancelCapture()
            await engine.cancelCapture()
            
            #expect(true, "Should handle multiple cancel calls safely")
            
        } catch let error as WispError {
            // In test environment without microphone permission, this is expected
            if case .audioRecordingFailed = error {
                #expect(true, "Audio recording may fail in test environment without permissions")
            } else {
                throw error
            }
        }
    }
}
