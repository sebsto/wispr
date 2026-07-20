//
//  MeetingDetectionServiceTests.swift
//  wisprTests
//
//  Unit tests for MeetingDetectionService using fake monitor and notifier.
//

import Foundation
import Testing

@testable import WisprApp

// MARK: - Fakes

/// Fake input-activity monitor that captures the `onChange` closure so tests
/// can drive activity events synchronously.
@MainActor
final class FakeInputActivityMonitor: InputActivityMonitoring {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@Sendable (Bool, Bool) -> Void)?

    func start(onChange: @escaping @Sendable (Bool, Bool) -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    var isStarted: Bool { onChange != nil }
}

/// Fake notifier that records calls.
@MainActor
final class FakeMeetingNotifier: MeetingNotifying {
    private(set) var authorizationRequests = 0
    private(set) var postedCount = 0

    func requestAuthorization() async {
        authorizationRequests += 1
    }

    func postMeetingDetectedNotification() async {
        postedCount += 1
    }
}

// MARK: - Helpers

@MainActor
private func makeService(
    enabled: Bool = true,
    cooldown: TimeInterval = 5 * 60
) -> (MeetingDetectionService, FakeInputActivityMonitor, FakeMeetingNotifier, SettingsStore) {
    let settings = SettingsStore(
        defaults: UserDefaults(suiteName: "test.wispr.detection.\(UUID().uuidString)")!
    )
    settings.meetingDetectionEnabled = enabled

    let monitor = FakeInputActivityMonitor()
    let notifier = FakeMeetingNotifier()
    let service = MeetingDetectionService(
        settingsStore: settings,
        notifier: notifier,
        monitor: monitor,
        cooldown: cooldown
    )
    return (service, monitor, notifier, settings)
}

// MARK: - Tests

@MainActor
@Suite("MeetingDetectionService Tests", .serialized)
struct MeetingDetectionServiceTests {

    @Test("start() begins monitoring and requests authorization when enabled")
    func testStartBeginsMonitoring() async {
        let (service, monitor, notifier, _) = makeService(enabled: true)

        await service.start()

        #expect(monitor.isStarted)
        #expect(monitor.startCount == 1)
        #expect(notifier.authorizationRequests == 1)
    }

    @Test("start() does not monitor when the setting is disabled")
    func testStartDisabledDoesNotMonitor() async {
        let (service, monitor, notifier, _) = makeService(enabled: false)

        await service.start()

        #expect(monitor.isStarted == false)
        #expect(monitor.startCount == 0)
        #expect(notifier.authorizationRequests == 0)
    }

    @Test("rising edge posts exactly one notification")
    func testRisingEdgePostsNotification() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        await service.start()

        await service.handleActivityChange(true, isBaseline: false)

        #expect(notifier.postedCount == 1)
    }

    @Test("no rising edge (already running) posts nothing")
    func testNoEdgePostsNothing() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        await service.start()

        await service.handleActivityChange(true, isBaseline: false)
        await service.handleActivityChange(true, isBaseline: false)  // still running, no new edge

        #expect(notifier.postedCount == 1)
    }

    @Test("baseline emission (already in use) does not post, and suppresses the next same-state edge")
    func testBaselineSeedsWithoutNotifying() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        await service.start()

        // Monitoring starts mid-call: baseline says "running".
        await service.handleActivityChange(true, isBaseline: true)
        // A subsequent real callback with the same state is not a rising edge.
        await service.handleActivityChange(true, isBaseline: false)

        #expect(notifier.postedCount == 0)
    }

    @Test("rising edge after an idle baseline still posts")
    func testRisingEdgeAfterIdleBaseline() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        await service.start()

        await service.handleActivityChange(false, isBaseline: true)  // idle baseline
        await service.handleActivityChange(true, isBaseline: false)  // real rising edge

        #expect(notifier.postedCount == 1)
    }

    @Test("device-change baseline re-seed does not post")
    func testDeviceChangeBaselineDoesNotPost() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        await service.start()

        await service.handleActivityChange(false, isBaseline: true)  // initial idle baseline
        await service.handleActivityChange(true, isBaseline: true)  // device switched mid-call

        #expect(notifier.postedCount == 0)
    }

    @Test("falling then rising edge posts again after cooldown of zero")
    func testSecondEdgePostsWithNoCooldown() async {
        let (service, _, notifier, _) = makeService(enabled: true, cooldown: 0)
        await service.start()

        await service.handleActivityChange(true, isBaseline: false)
        await service.handleActivityChange(false, isBaseline: false)
        await service.handleActivityChange(true, isBaseline: false)

        #expect(notifier.postedCount == 2)
    }

    @Test("cooldown suppresses a second notification within the window")
    func testCooldownSuppressesSecondNotification() async {
        let (service, _, notifier, _) = makeService(enabled: true, cooldown: 5 * 60)
        await service.start()

        await service.handleActivityChange(true, isBaseline: false)
        await service.handleActivityChange(false, isBaseline: false)
        await service.handleActivityChange(true, isBaseline: false)  // within cooldown

        #expect(notifier.postedCount == 1)
    }

    @Test("disabled setting suppresses notification on rising edge")
    func testDisabledSuppressesNotification() async {
        let (service, _, notifier, settings) = makeService(enabled: true)
        await service.start()
        settings.meetingDetectionEnabled = false

        await service.handleActivityChange(true, isBaseline: false)

        #expect(notifier.postedCount == 0)
    }

    @Test("self microphone usage suppresses notification")
    func testSelfUsageSuppressesNotification() async {
        let (service, _, notifier, _) = makeService(enabled: true)
        service.isSelfUsingMicrophone = { true }
        await service.start()

        await service.handleActivityChange(true, isBaseline: false)

        #expect(notifier.postedCount == 0)
    }

    @Test("stop() stops the monitor")
    func testStopStopsMonitor() async {
        let (service, monitor, _, _) = makeService(enabled: true)
        await service.start()

        await service.stop()

        #expect(monitor.isStarted == false)
        #expect(monitor.stopCount == 1)
    }
}
