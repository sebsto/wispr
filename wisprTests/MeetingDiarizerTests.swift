//
//  MeetingDiarizerTests.swift
//  wisprTests
//
//  Unit tests for MeetingDiarizer's safe pre-initialization contract.
//
//  Note: Exercising real diarization quality requires loading the ~30 MB
//  Sortformer CoreML model and feeding multi-speaker audio, which is covered
//  by the manual end-to-end verification plan in
//  `.kiro/specs/meeting-speaker-diarization/design.md` rather than unit tests.
//  These tests verify the actor is safe to call before (or without) warmUp().
//

import Foundation
import Testing

@testable import WisprApp

@Suite("MeetingDiarizer Tests")
struct MeetingDiarizerTests {

    @Test("dominantSpeaker returns nil before warmUp")
    func testDominantSpeakerNilBeforeWarmUp() async {
        let diarizer = MeetingDiarizer()
        let result = await diarizer.dominantSpeaker(in: 0.0...5.0)
        #expect(result == nil)
    }

    @Test("ingest before warmUp is a safe no-op")
    func testIngestBeforeWarmUpIsNoOp() async {
        let diarizer = MeetingDiarizer()
        let samples = [Float](repeating: 0.1, count: 16_000)

        // Should not crash or throw — ingest guards on isInitialized.
        await diarizer.ingest(samples, at: 0.0)

        // Still no speaker data available.
        let result = await diarizer.dominantSpeaker(in: 0.0...1.0)
        #expect(result == nil)
    }

    @Test("reset before warmUp is a safe no-op")
    func testResetBeforeWarmUpIsNoOp() async {
        let diarizer = MeetingDiarizer()

        // Should not crash on a fresh, uninitialized diarizer.
        await diarizer.reset()

        let result = await diarizer.dominantSpeaker(in: 0.0...5.0)
        #expect(result == nil)
    }

    @Test("dominantSpeaker handles zero-width window before warmUp")
    func testDominantSpeakerZeroWidthWindow() async {
        let diarizer = MeetingDiarizer()
        let result = await diarizer.dominantSpeaker(in: 2.5...2.5)
        #expect(result == nil)
    }
}
