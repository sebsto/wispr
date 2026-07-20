//
//  MeetingDiarizer.swift
//  wispr
//
//  Actor wrapping FluidAudio's SortformerDiarizer for real-time speaker
//  diarization on the system-audio ("Others") track.
//
//  Only the system-audio track is diarized. The mic track keeps the "You"
//  label. Diarization is gated by SettingsStore.meetingDiarizationEnabled
//  and requires a one-time Sortformer model download (~30 MB).
//

import FluidAudio
import Foundation
import WisprCore
import os

/// Actor that wraps `SortformerDiarizer` and exposes a simple ingest/query API
/// for attributing transcription chunks to individual remote speakers.
///
/// Speaker slot indices from Sortformer (0-based, up to 4) are mapped to
/// **monotonically assigned** per-meeting indices so that the first speaker
/// heard always becomes index 0 ("Speaker 1"), the second becomes index 1
/// ("Speaker 2"), and so on regardless of which Sortformer slot they occupy.
///
/// Cold-start: Sortformer needs a few hundred ms of audio before its timeline
/// is populated. `dominantSpeaker(in:)` returns `nil` for the first chunk or
/// two; callers should treat `nil` as "unknown" and render as plain "Others".
actor MeetingDiarizer {

    // MARK: - Internal segment cache

    /// A resolved speaker segment (fully internal, Sendable value type).
    private struct Segment {
        let assignedIndex: Int
        let startTime: Float
        let endTime: Float
    }

    // MARK: - State

    /// Sortformer configuration. `.balancedV2` uses the v2 weights with a large
    /// FIFO (188) for better quality at the same ~1s latency as the fast config,
    /// and handles overlapping/high-speaker-count audio better than v2.1.
    private static let config: SortformerConfig = .balancedV2

    private let sortformer = SortformerDiarizer(config: MeetingDiarizer.config)
    private var isInitialized = false

    /// Accumulated finalized speaker segments from all processed chunks.
    private var finalizedSegments: [Segment] = []
    /// Latest tentative segments (replaced on each process() call).
    private var tentativeSegments: [Segment] = []

    /// Meeting-relative start time of the first ingested chunk. Sortformer's
    /// internal timeline begins at 0 when it receives its first audio, so we
    /// add this offset to align segment times with the engine's meeting clock
    /// (the diarizer may start mid-meeting once its model finishes warming up).
    private var baseTime: TimeInterval?

    /// Sortformer slot → per-meeting monotonic index (0-based).
    private var slotToAssigned: [Int: Int] = [:]
    private var nextAssigned: Int = 0

    // MARK: - Public Interface

    /// Downloads/loads the Sortformer CoreML model and initializes the diarizer.
    ///
    /// Safe to call multiple times — returns immediately if already initialized.
    /// Throws if the model download or compilation fails.
    func warmUp() async throws {
        guard !isInitialized else { return }

        Log.diarizer.info("MeetingDiarizer — loading Sortformer model")
        let models = try await SortformerModels.loadFromHuggingFace(
            config: Self.config,
            cacheDirectory: ModelPaths.sortformer
        )
        sortformer.initialize(models: models)
        isInitialized = true
        Log.diarizer.info("MeetingDiarizer — Sortformer initialized")
    }

    /// Feeds a system-audio chunk into the diarizer.
    ///
    /// The `startTime` is used for logging only; the diarizer computes its own
    /// timeline from the sample count. Errors are logged and swallowed so that
    /// a diarizer failure never interrupts transcription.
    func ingest(_ samples: [Float], at startTime: TimeInterval) {
        guard isInitialized else { return }
        if baseTime == nil { baseTime = startTime }
        let offset = Float(baseTime ?? 0)
        do {
            sortformer.addAudio(samples)
            if let update = try sortformer.process() {
                // Accumulate newly finalized segments (shifted to meeting time)
                for seg in update.finalizedSegments {
                    let idx = assignedIndex(for: seg.speakerIndex)
                    finalizedSegments.append(
                        Segment(
                            assignedIndex: idx,
                            startTime: seg.startTime + offset,
                            endTime: seg.endTime + offset)
                    )
                }
                // Replace tentative segments with the latest snapshot
                tentativeSegments = update.tentativeSegments.map { seg in
                    Segment(
                        assignedIndex: assignedIndex(for: seg.speakerIndex),
                        startTime: seg.startTime + offset,
                        endTime: seg.endTime + offset
                    )
                }
            }
        } catch {
            Log.diarizer.warning(
                "MeetingDiarizer — ingest error at t=\(String(format: "%.2f", startTime))s: \(error.localizedDescription)"
            )
        }
    }

    /// Returns the 0-based assigned index of the speaker who dominated the
    /// given time window, or `nil` if no speaker data is available yet.
    ///
    /// Finalized segments are queried first; tentative segments serve as
    /// a best-effort fallback for the most recent window.
    func dominantSpeaker(in window: ClosedRange<TimeInterval>) -> Int? {
        guard isInitialized else { return nil }
        let wStart = Float(window.lowerBound)
        let wEnd = Float(window.upperBound)

        // Search finalized first, then tentative
        for source in [finalizedSegments, tentativeSegments] {
            var totals: [Int: Float] = [:]
            for seg in source {
                let s = max(seg.startTime, wStart)
                let e = min(seg.endTime, wEnd)
                if e > s { totals[seg.assignedIndex, default: 0] += (e - s) }
            }
            if let best = totals.max(by: { $0.value < $1.value }) {
                return best.key
            }
        }
        return nil
    }

    /// Resets all internal diarization state for a new meeting session.
    func reset() {
        sortformer.reset()
        finalizedSegments.removeAll()
        tentativeSegments.removeAll()
        slotToAssigned.removeAll()
        nextAssigned = 0
        baseTime = nil
        Log.diarizer.debug("MeetingDiarizer — reset")
    }

    // MARK: - Private

    /// Returns the per-meeting monotonic index for a Sortformer slot, creating
    /// a new assignment if the slot hasn't been seen before this session.
    private func assignedIndex(for slot: Int) -> Int {
        if let existing = slotToAssigned[slot] { return existing }
        let idx = nextAssigned
        slotToAssigned[slot] = idx
        nextAssigned += 1
        return idx
    }
}
