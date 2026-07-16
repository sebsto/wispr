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
final class FakeInputActivityMonitor: InputActivityMonitoring, @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (@Sendable (Bool) -> Void)?

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
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

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func postMeetingDetectedNotification() {
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
    func testStartBeginsMonitoring() {
        let (service, monitor, notifier, _) = makeService(enabled: true)

        service.start()

        #expect(monitor.isStarted)
        #expect(monitor.startCount == 1)
        #expect(notifier.authorizationRequests == 1)
    }

    @Test("start() does not monitor when the setting is disabled")
    func testStartDisabledDoesNotMonitor() {
        let (service, monitor, notifier, _) = makeService(enabled: false)

        service.start()

        #expect(monitor.isStarted == false)
        #expect(monitor.startCount == 0)
        #expect(notifier.authorizationRequests == 0)
    }

    @Test("rising edge posts exactly one notification")
    func testRisingEdgePostsNotification() {
        let (service, _, notifier, _) = makeService(enabled: true)
        service.start()

        service.handleActivityChange(true)

        #expect(notifier.postedCount == 1)
    }

    @Test("no rising edge (already running) posts nothing")
    func testNoEdgePostsNothing() {
        let (service, _, notifier, _) = makeService(enabled: true)
        service.start()

        service.handleActivityChange(true)
        service.handleActivityChange(true)  // still running, no new edge

        #expect(notifier.postedCount == 1)
    }

    @Test("falling then rising edge posts again after cooldown of zero")
    func testSecondEdgePostsWithNoCooldown() {
        let (service, _, notifier, _) = makeService(enabled: true, cooldown: 0)
        service.start()

        service.handleActivityChange(true)
        service.handleActivityChange(false)
        service.handleActivityChange(true)

        #expect(notifier.postedCount == 2)
    }

    @Test("cooldown suppresses a second notification within the window")
    func testCooldownSuppressesSecondNotification() {
        let (service, _, notifier, _) = makeService(enabled: true, cooldown: 5 * 60)
        service.start()

        service.handleActivityChange(true)
        service.handleActivityChange(false)
        service.handleActivityChange(true)  // within cooldown

        #expect(notifier.postedCount == 1)
    }

    @Test("disabled setting suppresses notification on rising edge")
    func testDisabledSuppressesNotification() {
        let (service, _, notifier, settings) = makeService(enabled: true)
        service.start()
        settings.meetingDetectionEnabled = false

        service.handleActivityChange(true)

        #expect(notifier.postedCount == 0)
    }

    @Test("self microphone usage suppresses notification")
    func testSelfUsageSuppressesNotification() {
        let (service, _, notifier, _) = makeService(enabled: true)
        service.isSelfUsingMicrophone = { true }
        service.start()

        service.handleActivityChange(true)

        #expect(notifier.postedCount == 0)
    }

    @Test("stop() stops the monitor")
    func testStopStopsMonitor() {
        let (service, monitor, _, _) = makeService(enabled: true)
        service.start()

        service.stop()

        #expect(monitor.isStarted == false)
        #expect(monitor.stopCount == 1)
    }
}
