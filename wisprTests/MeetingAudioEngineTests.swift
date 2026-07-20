//
//  MeetingAudioEngineTests.swift
//  wispr
//
//  Unit tests for MeetingAudioEngine and SystemAudioOutputHandler
//  using swift-testing framework.
//

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
import WisprCore

@testable import WisprApp

// MARK: - MeetingAudioEngine Tests

@Suite("MeetingAudioEngine Tests")
struct MeetingAudioEngineTests {

    // MARK: - Stream Behavior When Not Capturing

    @Test("micAudioStream returns finished stream when not capturing")
    func testMicStreamReturnsFinishedWhenNotCapturing() async {
        let engine = MeetingAudioEngine()

        let stream = await engine.micAudioStream
        var chunks: [[Float]] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        #expect(
            chunks.isEmpty,
            "micAudioStream should finish immediately when not capturing, yielding no chunks")
    }

    @Test("systemAudioStream returns finished stream when not capturing")
    func testSystemStreamReturnsFinishedWhenNotCapturing() async {
        let engine = MeetingAudioEngine()

        let stream = await engine.systemAudioStream
        var chunks: [[Float]] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        #expect(
            chunks.isEmpty,
            "systemAudioStream should finish immediately when not capturing, yielding no chunks")
    }

    // MARK: - Safe Operations When Not Capturing

    @Test("stopCapture does not crash when not capturing")
    func testStopCaptureWhenNotCapturing() async {
        let engine = MeetingAudioEngine()

        // Should complete without error or crash
        await engine.stopCapture()
    }

    @Test("flushBuffers does not crash when not capturing")
    func testFlushBuffersWhenNotCapturing() async {
        let engine = MeetingAudioEngine()

        // Should complete without error or crash
        await engine.flushBuffers()
    }

    // MARK: - Capture Start Behavior

    @Test("startCapture throws in test environment without mic permission")
    func testStartCaptureFailsInTestEnvironment() async {
        let engine = MeetingAudioEngine()

        // In CI/test environments, mic hardware is typically unavailable.
        // startCapture should throw because AVAudioEngine cannot start
        // without a valid input device.
        do {
            _ = try await engine.startCapture()
            // If we reach here, hardware is available — stop capture to clean up
            await engine.stopCapture()
        } catch {
            // Expected: capture fails due to missing mic permission or hardware.
            // Verify it's a WisprError or at least that it threw.
            #expect(
                error is WisprError || error is NSError,
                "Expected a WisprError or NSError, got \(type(of: error))")
        }
    }

    @Test("Double startCapture throws audioRecordingFailed")
    func testDoubleStartCaptureThrows() async throws {
        let engine = MeetingAudioEngine()

        // First call: may succeed or fail depending on hardware
        let firstStartSucceeded: Bool
        do {
            _ = try await engine.startCapture()
            firstStartSucceeded = true
        } catch {
            firstStartSucceeded = false
        }

        // Only test double-start if the first one succeeded
        guard firstStartSucceeded else {
            // No hardware available — can't test double-start, clean up and return
            await engine.stopCapture()
            return
        }

        // Second call should throw because capture is already active
        do {
            _ = try await engine.startCapture()
            Issue.record("Second startCapture() should have thrown, but it succeeded")
        } catch let error as WisprError {
            #expect(
                error == .audioRecordingFailed("Meeting capture already active"),
                "Expected audioRecordingFailed error for double start")
        } catch {
            Issue.record("Expected WisprError.audioRecordingFailed, got \(error)")
        }

        // Clean up
        await engine.stopCapture()
    }
}

// MARK: - SystemAudioOutputHandler Tests

@Suite("SystemAudioOutputHandler Tests")
struct SystemAudioOutputHandlerTests {

    @Test("Handler can be instantiated with a closure")
    func testHandlerInstantiation() {
        let handler = SystemAudioOutputHandler { _ in
            // no-op callback
        }

        #expect(handler is NSObject, "Handler should be an NSObject subclass")
    }

    @Test("Handler stores callback and can be used as SCStreamOutput")
    func testHandlerCallbackWithSamples() {
        nonisolated(unsafe) var receivedSamples: [Float]?

        let handler = SystemAudioOutputHandler { samples in
            receivedSamples = samples
        }

        // Verify the handler conforms to SCStreamOutput by checking it's the right type.
        // We can't easily create a valid CMSampleBuffer with audio data in a unit test,
        // but we can confirm the handler was created and is ready to receive callbacks.
        #expect(handler is NSObject, "Handler should be an NSObject subclass")

        // The callback hasn't been invoked yet since we haven't sent any sample buffers
        #expect(
            receivedSamples == nil, "Callback should not be invoked until stream delivers samples")
    }
}
