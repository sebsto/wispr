//
//  TerminalProgressReporter.swift
//  wispr-cli
//
//  Progress indication for long-running CLI transcription.
//
//  Two inputs, one output. Engines push `ProgressUpdate` values at whatever
//  irregular rate they manage (WhisperKit reports roughly twice per minute of
//  audio); a 100 ms ticker drives the redraw. Separating the two is what lets the
//  display stay animated during the long gaps between engine reports, so a user
//  can tell "slow" from "hung".
//
//  All output goes to a caller-supplied file descriptor rather than
//  `FileHandle.standardError`. In its default mode the CLI dups /dev/null over
//  STDERR_FILENO for the whole run to silence FluidAudio's INFO logging, so
//  anything written to stderr by name would be discarded. See `WisprCLI.run`.
//

import Darwin
import Foundation
import Synchronization
import WisprCore

// MARK: - Phases

nonisolated enum ProgressPhase: Sendable, Equatable {
    case loadingModel(String)
    case decoding
    case transcribing

    var label: String {
        switch self {
        case .loadingModel(let name): "Loading model \(name)"
        case .decoding: "Decoding audio"
        case .transcribing: "Transcribing"
        }
    }

    /// Past-tense form used for the `--verbose` completion lines.
    var completedLabel: String {
        switch self {
        case .loadingModel(let name): "Model \(name) loaded"
        case .decoding: "Audio decoded"
        case .transcribing: "Transcribed"
        }
    }
}

// MARK: - Events

/// A progress report tagged with the phase that produced it.
nonisolated struct ProgressEvent: Sendable {
    let generation: Int
    let update: ProgressUpdate
}

// MARK: - Style

nonisolated enum ProgressStyle: Sendable {
    /// Single line redrawn in place with ANSI escapes. stderr is a TTY.
    case interactive
    /// Periodic plain one-line updates, no escapes, no carriage returns.
    case plainLines
    /// No progress output at all.
    case silent
}

/// What the user asked for on the command line.
nonisolated enum ProgressPreference: String, Sendable, CaseIterable {
    case auto
    case always
    case never
}

// MARK: - Output sink

/// A write-only wrapper around a raw file descriptor.
///
/// Deliberately not `FileHandle`: the descriptor the CLI hands us is a *dup* of
/// the original stderr, saved before stderr was redirected to /dev/null.
nonisolated struct ProgressOutput: Sendable {
    let fd: Int32

    /// stderr as it was before any redirection, for use when nothing is suppressed.
    static let standardError = ProgressOutput(fd: STDERR_FILENO)

    func write(_ string: String) {
        guard fd >= 0 else { return }
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count)
            }
            // EINTR is worth retrying; anything else means the descriptor is
            // gone and there is nothing useful left to do about it.
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                return
            }
        }
    }

    var isTTY: Bool {
        fd >= 0 && isatty(fd) == 1
    }

    /// Terminal width in columns, or nil when it can't be determined.
    var columns: Int? {
        guard fd >= 0 else { return nil }
        var ws = winsize()
        if ioctl(fd, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        if let env = ProcessInfo.processInfo.environment["COLUMNS"], let n = Int(env), n > 0 {
            return n
        }
        return nil
    }
}

// MARK: - Reporter

/// Accumulates progress reports and renders them to a terminal.
///
/// Lifecycle: `begin` a phase, let updates flow in via the handler from
/// `transcriptionHandler()` / `decodeHandler()`, `endPhase()`, then `finish()`
/// exactly once — from a `defer`, so the line is erased even on a thrown error.
actor TerminalProgressReporter {

    // MARK: Configuration

    private let output: ProgressOutput
    private let style: ProgressStyle
    private let verbose: Bool
    private let useColor: Bool
    /// Status lines are controlled separately from the progress animation: a
    /// non-TTY run shows no progress but should still report which model it used,
    /// as it always has. Only `--quiet` silences both.
    private let logsEnabled: Bool

    /// Engine callbacks are synchronous and `@Sendable`, so they cannot await
    /// into this actor. They yield here instead: `yield` is non-blocking, and
    /// `.bufferingNewest(1)` collapses a burst of token-rate events down to the
    /// most recent one, so there is no unbounded queue and no backpressure on
    /// the decoder. Both are `let` constants of Sendable type, hence readable
    /// from nonisolated context.
    private let events: AsyncStream<ProgressEvent>
    private let eventSink: AsyncStream<ProgressEvent>.Continuation

    /// Identifies which phase an event belongs to.
    ///
    /// Intake is asynchronous, so an event yielded near the end of one phase can
    /// arrive after the next phase has begun. Untagged, the decoder's final
    /// event (a position equal to the whole audio length) would be accepted as a
    /// transcription position and pin the bar at 100%, after which the monotonic
    /// clamp would reject every real update for the rest of the run.
    private var generation = 0

    // MARK: Phase state

    private var phase: ProgressPhase?
    private var phaseStart: ContinuousClock.Instant?
    private var total: Double?
    private var position: Double = 0
    private var hasPosition = false

    // MARK: Rate estimation

    private var smoothedSpeed: Double?
    private var lastSpeedSample: (position: Double, elapsed: Double)?

    // MARK: Rendering state

    private var spinnerIndex = 0
    private var lineIsDirty = false
    private var cursorHidden = false
    private var lastPlainEmit: ContinuousClock.Instant?
    private var lastPlainFraction: Double?

    private var intakeTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?

    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private static let tickInterval = Duration.milliseconds(100)
    /// Non-TTY updates are emitted on whichever of these comes first.
    private static let plainMinInterval = Duration.seconds(5)
    private static let plainMinDelta = 0.05
    /// Narrowest bar worth drawing. Below this the line drops the bar and keeps
    /// the numbers instead.
    private static let minBarWidth = 10
    private static let maxBarWidth = 40

    init(output: ProgressOutput, style: ProgressStyle, verbose: Bool, logsEnabled: Bool) {
        self.output = output
        self.style = style
        self.verbose = verbose
        self.logsEnabled = logsEnabled

        let env = ProcessInfo.processInfo.environment
        self.useColor = env["NO_COLOR"] == nil && env["TERM"] != "dumb" && style == .interactive

        let (stream, continuation) = AsyncStream.makeStream(
            of: ProgressEvent.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = stream
        self.eventSink = continuation
    }

    // MARK: - Handlers handed to WisprCore

    /// A handler for `TranscriptionEngine.transcribe(_:language:onProgress:)`,
    /// or nil when progress is disabled.
    ///
    /// Returning nil rather than a no-op closure matters: the engines build their
    /// backend callbacks with `onProgress.map`, so a nil handler means the engine
    /// is handed nil callbacks and does no progress work at all. A no-op closure
    /// would still cost a call for every report.
    ///
    /// Must be called *after* `begin(_:total:)` for the phase it belongs to, so
    /// it captures that phase's generation.
    func transcriptionHandler() -> TranscriptionProgressHandler? {
        guard style != .silent else { return nil }
        let sink = eventSink
        let phaseGeneration = generation
        return { update in
            sink.yield(ProgressEvent(generation: phaseGeneration, update: update))
        }
    }

    /// A handler for `AudioFileDecoder.decode(fileURL:onProgress:)`, converting
    /// decoded sample counts into audio seconds at the decoder's 16 kHz output.
    /// Nil when progress is disabled. Same ordering requirement as above.
    func decodeHandler() -> DecodeProgressHandler? {
        guard style != .silent else { return nil }
        let sink = eventSink
        let phaseGeneration = generation
        return { sampleCount in
            sink.yield(ProgressEvent(
                generation: phaseGeneration,
                update: ProgressUpdate(processedSeconds: Double(sampleCount) / 16_000.0)
            ))
        }
    }

    // MARK: - Lifecycle

    /// Starts the intake and render loops. Safe to call when silent — it does nothing.
    func start() {
        guard style != .silent, intakeTask == nil else { return }

        let stream = events
        intakeTask = Task { [weak self] in
            for await update in stream {
                await self?.apply(update)
            }
        }

        renderTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                if Task.isCancelled { return }
                await self?.tick()
            }
        }

        if style == .interactive {
            output.write(Ansi.hideCursor)
            cursorHidden = true
        }
    }

    /// Begins a phase. `total` is the phase's full length in seconds; pass nil
    /// for phases whose length isn't known (model loading), which renders as an
    /// indeterminate spinner.
    func begin(_ newPhase: ProgressPhase, total: Double? = nil) {
        eraseLine()
        // Invalidate any event still in flight from the previous phase.
        generation += 1
        phase = newPhase
        phaseStart = .now
        self.total = total
        position = 0
        hasPosition = false
        smoothedSpeed = nil
        lastSpeedSample = nil
        lastPlainEmit = nil
        lastPlainFraction = nil
        render()
    }

    /// Ends the current phase, reporting its elapsed time when verbose.
    func endPhase(detail: String? = nil) {
        guard let phase, let phaseStart else { return }
        let elapsed = elapsedSeconds(since: phaseStart)
        eraseLine()
        if verbose, logsEnabled {
            let suffix = detail.map { " (\($0))" } ?? ""
            writeLine("\(symbol("✓")) \(phase.completedLabel) in \(formatDuration(elapsed))\(suffix)")
        }
        self.phase = nil
        self.phaseStart = nil
    }

    /// Writes a status message without colliding with the progress line.
    func log(_ message: String) {
        guard logsEnabled else { return }
        eraseLine()
        writeLine(message)
    }

    /// Tears everything down and leaves the terminal as it was found.
    /// Idempotent, and safe to call from a `defer` on the error path.
    func finish() {
        intakeTask?.cancel()
        renderTask?.cancel()
        intakeTask = nil
        renderTask = nil
        eventSink.finish()
        eraseLine()
        if cursorHidden {
            output.write(Ansi.showCursor)
            cursorHidden = false
        }
    }

    // MARK: - Event handling

    private func apply(_ event: ProgressEvent) {
        // Drop events belonging to a phase that has already ended.
        guard event.generation == generation else { return }
        let update = event.update

        if total == nil, let reported = update.totalSeconds {
            total = reported
        }

        // Clamp monotonic, so an out-of-order or stale report from an engine
        // can never move the bar backwards.
        let candidate = min(update.processedSeconds, total ?? .greatestFiniteMagnitude)
        guard candidate > position || !hasPosition else { return }
        position = max(position, candidate)
        hasPosition = true

        updateSpeed()
    }

    private func updateSpeed() {
        guard let phaseStart else { return }
        let elapsed = elapsedSeconds(since: phaseStart)

        guard let last = lastSpeedSample else {
            lastSpeedSample = (position, elapsed)
            return
        }

        let deltaPosition = position - last.position
        let deltaTime = elapsed - last.elapsed
        guard deltaTime > 0.2, deltaPosition > 0 else { return }

        // EMA so one slow window doesn't make the ETA lurch.
        let instant = deltaPosition / deltaTime
        smoothedSpeed = smoothedSpeed.map { 0.7 * $0 + 0.3 * instant } ?? instant
        lastSpeedSample = (position, elapsed)
    }

    private func tick() {
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
        render()
    }

    // MARK: - Derived values

    private func elapsedSeconds(since instant: ContinuousClock.Instant) -> Double {
        (ContinuousClock.now - instant).seconds
    }

    /// Realtime factor: audio seconds processed per wall-clock second.
    private var speed: Double? {
        if let smoothedSpeed { return smoothedSpeed }
        guard hasPosition, let phaseStart else { return nil }
        let elapsed = elapsedSeconds(since: phaseStart)
        guard elapsed > 0.5, position > 0 else { return nil }
        return position / elapsed
    }

    /// Seconds remaining, or nil until there's enough information to say.
    /// Never guessed — an absent ETA is better than a wrong one.
    private var eta: Double? {
        guard hasPosition, let total, let speed, speed > 0 else { return nil }
        let remaining = total - position
        guard remaining > 0 else { return 0 }
        return remaining / speed
    }

    private var fraction: Double? {
        guard hasPosition, let total, total > 0 else { return nil }
        return min(max(position / total, 0), 1)
    }

    /// Internal accessors backing the test seams below.
    var currentFraction: Double? { fraction }
    var currentGeneration: Int { generation }

    func applyForTesting(_ event: ProgressEvent) { apply(event) }

    // MARK: - Rendering

    private func render() {
        guard let phase, let phaseStart else { return }
        switch style {
        case .silent:
            return
        case .interactive:
            renderInteractive(phase: phase, elapsed: elapsedSeconds(since: phaseStart))
        case .plainLines:
            renderPlain(phase: phase, elapsed: elapsedSeconds(since: phaseStart))
        }
    }

    private func renderInteractive(phase: ProgressPhase, elapsed: Double) {
        let spinner = Self.spinnerFrames[spinnerIndex]
        // One column is left free: writing to the last cell makes some terminals
        // wrap, which would defeat the in-place redraw.
        let budget = (output.columns ?? 80) - 1

        var line = composeLine(phase: phase, elapsed: elapsed, spinner: spinner, budget: budget)

        // Belt and braces. Everything above sizes itself to the budget, so this
        // should not trigger; if it ever does, a truncated line still beats a
        // wrapped one that leaves stale text on screen.
        line = truncate(line, to: budget)

        output.write("\r\(Ansi.clearToEndOfLine)\(line)")
        lineIsDirty = true
    }

    /// Builds the progress line, degrading gracefully as the terminal narrows:
    /// full line with bar → line without bar → compact label and percentage.
    ///
    /// The bar is sized from the space actually left over rather than a fixed
    /// reserve, so no field ever gets truncated away at an awkward width.
    private func composeLine(
        phase: ProgressPhase,
        elapsed: Double,
        spinner: String,
        budget: Int
    ) -> String {
        let prefix = "\(spinner) \(phase.label)"

        // Indeterminate: no fabricated bar, just liveness and elapsed time.
        guard let fraction, let total else {
            return "\(prefix)  \(dim(formatDuration(elapsed)))"
        }

        var details = [
            "\(formatClock(position)) / \(formatClock(total))",
            "elapsed \(formatDuration(elapsed))"
        ]
        if let eta { details.append("eta \(formatDuration(eta))") }
        if let speed { details.append(String(format: "%.1f×", speed)) }
        let detailText = details.joined(separator: "   ")
        let pct = percent(fraction)

        // Fields are joined by a single fixed separator so the width arithmetic
        // below cannot drift out of step with the string built at the end — the
        // bug that had ETA and speed truncated away at ~89 columns.
        let sep = "  "
        let fullLayoutSeparators = sep.count * 3     // prefix|bar|pct|detail
        let barCaps = 2                              // ▕ and ▏

        let fixed = prefix.count + pct.count + detailText.count
            + fullLayoutSeparators + barCaps
        let barWidth = min(budget - fixed, Self.maxBarWidth)

        if barWidth >= Self.minBarWidth {
            return prefix + sep + bar(fraction: fraction, width: barWidth)
                + sep + pct + sep + dim(detailText)
        }

        // Too narrow for a useful bar: keep the numbers, drop the graphic.
        let withoutBarWidth = prefix.count + pct.count + detailText.count + sep.count * 2
        if withoutBarWidth <= budget {
            return prefix + sep + pct + sep + dim(detailText)
        }

        // Narrower still: label and percentage only.
        return "\(prefix) \(pct)"
    }

    private func renderPlain(phase: ProgressPhase, elapsed: Double) {
        let now = ContinuousClock.now
        let currentFraction = fraction

        // Throttle: emit on the interval, or on a big enough jump.
        let dueByTime = lastPlainEmit.map { (now - $0) >= Self.plainMinInterval } ?? true
        let dueByDelta: Bool
        if let currentFraction {
            // A first-ever fraction counts as a change worth reporting. Without
            // this, the phase-start line (which has no fraction yet) would set
            // `lastPlainEmit` and suppress every percentage until the interval
            // elapsed — so a phase finishing inside 5 s reported 0% and nothing else.
            dueByDelta = lastPlainFraction.map {
                abs(currentFraction - $0) >= Self.plainMinDelta
            } ?? true
        } else {
            dueByDelta = false
        }
        guard dueByTime || dueByDelta else { return }

        var parts = ["[progress]", phase.label.lowercased()]
        if let currentFraction, let total {
            parts.append(percent(currentFraction))
            parts.append("\(formatClock(position))/\(formatClock(total))")
        }
        parts.append("elapsed \(formatDuration(elapsed))")
        if let eta { parts.append("eta \(formatDuration(eta))") }
        if let speed { parts.append(String(format: "%.1fx", speed)) }

        writeLine(parts.joined(separator: " "))
        lastPlainEmit = now
        lastPlainFraction = currentFraction
    }

    private func bar(fraction: Double, width: Int) -> String {
        Self.makeBar(fraction: fraction, width: width)
    }

    private func percent(_ fraction: Double) -> String {
        Self.makePercent(fraction)
    }

    /// Static and pure so the geometry can be tested without a terminal.
    nonisolated static func makeBar(fraction: Double, width: Int) -> String {
        let clamped = min(max(fraction, 0), 1)
        let filled = min(max(Int((Double(width) * clamped).rounded()), 0), width)
        return "▕" + String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled) + "▏"
    }

    /// Floored, not rounded: 99.9% must not read as 100% before the phase ends.
    /// Fixed width so the line does not jitter as the number grows.
    nonisolated static func makePercent(_ fraction: Double) -> String {
        String(format: "%3d%%", Int((min(max(fraction, 0), 1) * 100).rounded(.down)))
    }

    private func truncate(_ line: String, to width: Int) -> String {
        guard width > 1 else { return line }
        // Count visible characters only; ANSI sequences occupy no columns.
        let visible = line.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        guard visible.count > width else { return line }
        return String(visible.prefix(width - 1)) + "…"
    }

    // MARK: - Low-level output

    private func eraseLine() {
        guard lineIsDirty, style == .interactive else { return }
        output.write("\r\(Ansi.clearToEndOfLine)")
        lineIsDirty = false
    }

    private func writeLine(_ text: String) {
        output.write(text + "\n")
    }

    private func dim(_ text: String) -> String {
        useColor ? "\(Ansi.dim)\(text)\(Ansi.reset)" : text
    }

    private func symbol(_ text: String) -> String {
        useColor ? "\(Ansi.green)\(text)\(Ansi.reset)" : text
    }
}

// MARK: - Test seams

extension TerminalProgressReporter {
    /// Feeds an update straight into the state machine, bypassing the
    /// asynchronous intake so a test observes it deterministically.
    /// Defaults to the current phase's generation.
    func ingestForTesting(processedSeconds: Double, generation: Int? = nil) {
        applyForTesting(ProgressEvent(
            generation: generation ?? currentGeneration,
            update: ProgressUpdate(processedSeconds: processedSeconds)
        ))
    }

    var fractionForTesting: Double? { currentFraction }
    var generationForTesting: Int { currentGeneration }

    nonisolated static func barForTesting(fraction: Double, width: Int) -> String {
        makeBar(fraction: fraction, width: width)
    }

    nonisolated static func percentForTesting(_ fraction: Double) -> String {
        makePercent(fraction)
    }
}

// MARK: - ANSI

nonisolated enum Ansi {
    static let clearToEndOfLine = "\u{1B}[K"
    static let hideCursor = "\u{1B}[?25l"
    static let showCursor = "\u{1B}[?25h"
    static let dim = "\u{1B}[2m"
    static let green = "\u{1B}[32m"
    static let reset = "\u{1B}[0m"
}

// MARK: - Cursor safety on signals

/// Restores the terminal cursor if the process is interrupted.
///
/// Without this, `^C` during an interactive run leaves the cursor hidden and the
/// user's shell prompt invisible until they type `reset`.
nonisolated enum CursorRestorer {
    /// Keeps the dispatch sources alive for the process's lifetime.
    ///
    /// A `Mutex` rather than `nonisolated(unsafe)`: the write-once discipline
    /// would have made the unchecked version sound, but this costs nothing and
    /// keeps the file free of concurrency escape hatches.
    private static let sources = Mutex<[DispatchSourceSignal]>([])

    static func install(output: ProgressOutput) {
        // Installing twice would leak a second set of sources and double the
        // cursor-restore writes.
        let alreadyInstalled = sources.withLock { !$0.isEmpty }
        guard !alreadyInstalled else { return }

        var installed: [DispatchSourceSignal] = []
        for sig in [SIGINT, SIGTERM] {
            // Ignore the default disposition so the process survives long enough
            // for the handler below to run.
            signal(sig, SIG_IGN)
            // A global queue, not .main: the main thread is running the Swift
            // concurrency executor for `AsyncParsableCommand`, and relying on it
            // to drain the main dispatch queue would be fragile.
            let source = DispatchSource.makeSignalSource(
                signal: sig,
                queue: DispatchQueue.global(qos: .userInitiated)
            )
            source.setEventHandler {
                output.write(Ansi.showCursor + "\n")
                // Restore the default behaviour and re-raise, so the exit status
                // and any parent shell's job control see a normal signal death.
                signal(sig, SIG_DFL)
                raise(sig)
            }
            source.resume()
            installed.append(source)
        }
        sources.withLock { $0 = installed }
    }
}
