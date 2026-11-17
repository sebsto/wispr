//
//  TerminalProgressReporterTests.swift
//  wisprTests
//
//  Tests for the CLI's progress rendering and state machine.
//
//  These cover the parts that were previously only checked by eye against a
//  terminal: duration formatting boundaries, style resolution from the flags,
//  and the reporter's phase/position bookkeeping — including the stale-event
//  race where a decode report arriving after the phase switch would pin the
//  transcription bar at 100%.
//

import Testing
import Foundation
@testable import WisprCLI
import WisprCore

// MARK: - Duration formatting

@Suite("Duration formatting")
struct DurationFormatTests {

    @Test("Sub-minute durations get one decimal place")
    func subMinute() {
        // Values chosen away from the one-decimal rounding boundary: 0.85 is not
        // exactly representable as a Double (its nearest value is slightly
        // below), so "%.1f" yields 0.8 there — a property of the literal, not of
        // this function.
        #expect(formatDuration(0.86) == "0.9s")
        #expect(formatDuration(9.04) == "9.0s")
        #expect(formatDuration(22.56) == "22.6s")
        #expect(formatDuration(59.9) == "59.9s")
    }

    @Test("Minute-to-hour durations read as minutes and seconds")
    func minutes() {
        #expect(formatDuration(60) == "1m 0s")
        #expect(formatDuration(262) == "4m 22s")
        #expect(formatDuration(3599) == "59m 59s")
    }

    @Test("Durations of an hour or more read as a clock")
    func hours() {
        #expect(formatDuration(3600) == "1:00:00")
        #expect(formatDuration(5025) == "1:23:45")
    }

    @Test("Non-finite and negative durations produce a placeholder, not garbage")
    func invalidDurations() {
        #expect(formatDuration(-1) == "—")
        #expect(formatDuration(.nan) == "—")
        #expect(formatDuration(.infinity) == "—")
    }

    @Test("Clock positions are mm:ss below an hour and h:mm:ss above")
    func clockFormat() {
        #expect(formatClock(0) == "00:00")
        #expect(formatClock(54) == "00:54")
        #expect(formatClock(1163) == "19:23")
        #expect(formatClock(2261) == "37:41")
        #expect(formatClock(3600) == "1:00:00")
        #expect(formatClock(5025) == "1:23:45")
    }

    @Test("Invalid clock positions produce a placeholder")
    func invalidClock() {
        #expect(formatClock(-5) == "--:--")
        #expect(formatClock(.nan) == "--:--")
    }

    @Test("Duration.seconds converts without losing the fractional part")
    func durationSeconds() {
        #expect(abs(Duration.milliseconds(1500).seconds - 1.5) < 0.0001)
        #expect(abs(Duration.seconds(22).seconds - 22.0) < 0.0001)
        #expect(abs(Duration.milliseconds(100).seconds - 0.1) < 0.0001)
    }
}

// MARK: - Style resolution

@Suite("Progress style resolution")
struct ProgressStyleTests {

    /// A descriptor that is definitely not a terminal, so the non-TTY branches
    /// can be exercised without a pty.
    private var nonTTY: ProgressOutput { ProgressOutput(fd: -1) }

    @Test("--quiet silences progress whatever else was asked for")
    func quietWins() {
        for preference in ProgressPreference.allCases {
            let style = WisprCLI.progressStyle(
                preference: preference, quiet: true, verbose: true, output: nonTTY
            )
            #expect(style == .silent, "preference \(preference) should still be silent under --quiet")
        }
    }

    @Test("--progress never silences progress")
    func neverIsSilent() {
        let style = WisprCLI.progressStyle(
            preference: .never, quiet: false, verbose: true, output: nonTTY
        )
        #expect(style == .silent)
    }

    @Test("A non-TTY stays silent by default so redirected stderr is not filled")
    func nonTTYDefaultsToSilent() {
        let style = WisprCLI.progressStyle(
            preference: .auto, quiet: false, verbose: false, output: nonTTY
        )
        #expect(style == .silent)
    }

    @Test("A non-TTY emits plain lines when verbose")
    func nonTTYVerboseUsesPlainLines() {
        let style = WisprCLI.progressStyle(
            preference: .auto, quiet: false, verbose: true, output: nonTTY
        )
        #expect(style == .plainLines)
    }

    @Test("A non-TTY emits plain lines when progress is explicitly requested")
    func nonTTYAlwaysUsesPlainLines() {
        let style = WisprCLI.progressStyle(
            preference: .always, quiet: false, verbose: false, output: nonTTY
        )
        #expect(style == .plainLines)
    }
}

// MARK: - SDK log suppression

@Suite("SDK log suppression")
struct SDKLogSuppressionTests {

    @Test("Default runs suppress third-party SDK logging")
    func defaultSuppresses() {
        #expect(WisprCLI.shouldSuppressSDKLogs(verbose: false, quiet: false))
    }

    @Test("--verbose opts into SDK logging")
    func verboseShowsLogs() {
        #expect(!WisprCLI.shouldSuppressSDKLogs(verbose: true, quiet: false))
    }

    @Test("--quiet suppresses SDK logging even alongside --verbose")
    func quietBeatsVerbose() {
        // A flag that promises to suppress all stderr output has to win over one
        // that merely asks for more of it. Regression: `--quiet --verbose` used
        // to emit 20 lines of FluidAudio INFO logging.
        #expect(WisprCLI.shouldSuppressSDKLogs(verbose: true, quiet: true))
        #expect(WisprCLI.shouldSuppressSDKLogs(verbose: false, quiet: true))
    }
}

// MARK: - Preference parsing

@Suite("Progress preference parsing")
struct ProgressPreferenceTests {

    @Test("Every case round-trips through its raw value")
    func rawValues() {
        #expect(ProgressPreference(rawValue: "auto") == .auto)
        #expect(ProgressPreference(rawValue: "always") == .always)
        #expect(ProgressPreference(rawValue: "never") == .never)
    }

    @Test("An unknown value does not parse, so a typo falls back rather than silently disabling")
    func unknownValue() {
        #expect(ProgressPreference(rawValue: "sometimes") == nil)
        #expect(ProgressPreference(rawValue: "") == nil)
    }

    @Test("All cases are offered to the help text")
    func allValueStrings() {
        #expect(Set(ProgressPreference.allValueStrings) == ["auto", "always", "never"])
    }
}

// MARK: - Reporter state machine

@Suite("TerminalProgressReporter state", .serialized)
struct ProgressReporterStateTests {

    /// Silent style keeps the tests free of terminal writes; the state machine
    /// under test runs identically.
    private func makeReporter() -> TerminalProgressReporter {
        TerminalProgressReporter(
            output: ProgressOutput(fd: -1),
            style: .silent,
            verbose: false,
            logsEnabled: false
        )
    }

    @Test("Position advances with reported progress")
    func positionAdvances() async {
        let reporter = makeReporter()
        await reporter.begin(.transcribing, total: 100)

        await reporter.ingestForTesting(processedSeconds: 25)
        #expect(await reporter.fractionForTesting == 0.25)

        await reporter.ingestForTesting(processedSeconds: 60)
        #expect(await reporter.fractionForTesting == 0.60)
    }

    @Test("Position never moves backwards")
    func positionIsMonotonic() async {
        let reporter = makeReporter()
        await reporter.begin(.transcribing, total: 100)

        await reporter.ingestForTesting(processedSeconds: 50)
        // A report behind the current position is ignored.
        await reporter.ingestForTesting(processedSeconds: 30)
        #expect(await reporter.fractionForTesting == 0.50)
    }

    @Test("Position is clamped to the total so overshoot cannot exceed 100%")
    func positionIsClamped() async {
        let reporter = makeReporter()
        await reporter.begin(.transcribing, total: 100)

        await reporter.ingestForTesting(processedSeconds: 250)
        #expect(await reporter.fractionForTesting == 1.0)
    }

    @Test("Fraction is nil before any report, so no bar is drawn from nothing")
    func fractionNilBeforeFirstReport() async {
        let reporter = makeReporter()
        await reporter.begin(.transcribing, total: 100)
        #expect(await reporter.fractionForTesting == nil)
    }

    @Test("An indeterminate phase has no fraction however much is reported")
    func indeterminatePhaseHasNoFraction() async {
        let reporter = makeReporter()
        await reporter.begin(.loadingModel("large-v3"), total: nil)

        await reporter.ingestForTesting(processedSeconds: 10)
        #expect(await reporter.fractionForTesting == nil)
    }

    @Test("Beginning a phase resets the position from the previous one")
    func beginResetsPosition() async {
        let reporter = makeReporter()
        await reporter.begin(.decoding, total: 100)
        await reporter.ingestForTesting(processedSeconds: 100)
        #expect(await reporter.fractionForTesting == 1.0)

        await reporter.begin(.transcribing, total: 100)
        #expect(await reporter.fractionForTesting == nil)
    }

    /// Regression test for the stale-event race.
    ///
    /// Event intake is asynchronous, so the decoder's final report — a position
    /// equal to the entire audio length — can be delivered after the
    /// transcription phase has already begun. Untagged, it was accepted as a
    /// transcription position and pinned the bar at 100%, after which the
    /// monotonic clamp rejected every real engine update for the rest of the run.
    @Test("A report left over from the previous phase is discarded")
    func staleEventFromPreviousPhaseIsDropped() async {
        let reporter = makeReporter()

        await reporter.begin(.decoding, total: 2261)
        let decodeGeneration = await reporter.generationForTesting

        await reporter.begin(.transcribing, total: 2261)

        // The decoder's last event, arriving late and tagged with the phase it
        // came from.
        await reporter.ingestForTesting(
            processedSeconds: 2261,
            generation: decodeGeneration
        )
        #expect(
            await reporter.fractionForTesting == nil,
            "a decode-phase event must not set the transcription position"
        )

        // Real engine progress is still accepted afterwards.
        await reporter.ingestForTesting(processedSeconds: 54)
        let fraction = await reporter.fractionForTesting
        #expect(fraction != nil)
        #expect(abs((fraction ?? 0) - 54.0 / 2261.0) < 0.0001)
    }

    @Test("Each phase gets a distinct generation")
    func generationsAreDistinct() async {
        let reporter = makeReporter()
        await reporter.begin(.decoding, total: 10)
        let first = await reporter.generationForTesting
        await reporter.begin(.transcribing, total: 10)
        let second = await reporter.generationForTesting
        #expect(second != first)
    }

    @Test("No handlers are produced when progress is silent, so engines do no progress work")
    func silentStyleProducesNoHandlers() async {
        let reporter = makeReporter()
        await reporter.begin(.transcribing, total: 10)
        #expect(await reporter.transcriptionHandler() == nil)
        #expect(await reporter.decodeHandler() == nil)
    }

    @Test("Handlers are produced when progress is enabled")
    func activeStyleProducesHandlers() async {
        let reporter = TerminalProgressReporter(
            output: ProgressOutput(fd: -1),
            style: .plainLines,
            verbose: false,
            logsEnabled: false
        )
        await reporter.begin(.transcribing, total: 10)
        #expect(await reporter.transcriptionHandler() != nil)
        #expect(await reporter.decodeHandler() != nil)
    }
}

// MARK: - Bar rendering

@Suite("Progress bar rendering")
struct ProgressBarTests {

    @Test("An empty bar is all track and a full bar is all fill")
    func emptyAndFull() {
        #expect(TerminalProgressReporter.barForTesting(fraction: 0, width: 10) == "▕░░░░░░░░░░▏")
        #expect(TerminalProgressReporter.barForTesting(fraction: 1, width: 10) == "▕██████████▏")
    }

    @Test("Bar width is honoured exactly, so the line cannot overflow the terminal")
    func widthIsHonoured() {
        for width in [10, 17, 24, 40] {
            let bar = TerminalProgressReporter.barForTesting(fraction: 0.5, width: width)
            // Two end caps plus exactly `width` cells.
            #expect(bar.count == width + 2, "width \(width) produced \(bar.count) characters")
        }
    }

    @Test("Fill is proportional to the fraction")
    func fillIsProportional() {
        let bar = TerminalProgressReporter.barForTesting(fraction: 0.5, width: 20)
        #expect(bar.filter { $0 == "█" }.count == 10)
        #expect(bar.filter { $0 == "░" }.count == 10)
    }

    @Test("Out-of-range fractions are clamped rather than producing a malformed bar")
    func outOfRangeIsClamped() {
        #expect(TerminalProgressReporter.barForTesting(fraction: 2.0, width: 10) == "▕██████████▏")
        #expect(TerminalProgressReporter.barForTesting(fraction: -1.0, width: 10) == "▕░░░░░░░░░░▏")
    }

    @Test("Percentage is floored and width-stable so the line does not jitter")
    func percentFormatting() {
        #expect(TerminalProgressReporter.percentForTesting(0) == "  0%")
        #expect(TerminalProgressReporter.percentForTesting(0.079) == "  7%")
        #expect(TerminalProgressReporter.percentForTesting(0.386) == " 38%")
        // Floored, not rounded: 99.9% must not display as 100% before it is done.
        #expect(TerminalProgressReporter.percentForTesting(0.999) == " 99%")
        #expect(TerminalProgressReporter.percentForTesting(1.0) == "100%")
    }
}
