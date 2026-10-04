import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class KeepAliveAndHostTests: XCTestCase {
    @MainActor func testBackgroundReadReachesModelAndActualNotificationDecisionLogs() throws {
        for authorized in [true, false] {
            let local = HostStore()
            let sampler = HostBrightnessSampler()
            let notifications = HostNoopNotifications()
            notifications.authorized = authorized
            let monitor = try SwitchMonitor(store: local, sampler: sampler, notifications: notifications,
                diagnosticContext: { ["applicationState": "background", "pipPhase": "active", "listenerHost": "app"] })
            try monitor.start()
            sampler.receive?(BrightnessReading(value: 0.02, source: .poll,
                timestamp: Date(), uptime: 11))
            XCTAssertEqual(monitor.snapshot.counters.polls, 1)
            XCTAssertNotNil(monitor.snapshot.heartbeatAt)
            XCTAssertEqual(monitor.snapshot.lastPollAt, monitor.snapshot.heartbeatAt)
            let score = try XCTUnwrap(local.records.last { $0.event == "trend_score" })
            XCTAssertEqual(score.fields["candidateCreated"], "true")
            XCTAssertEqual(score.fields["scoredTarget"], "dark")
            XCTAssertTrue(local.records.contains { $0.event == "notification_authorization_requested" })
            let result = try XCTUnwrap(local.records.last { $0.event == "notification_result" })
            XCTAssertEqual(result.fields["applicationState"], "background")
            XCTAssertEqual(result.fields["result"], authorized ? "success" : "blocked")
            XCTAssertEqual(monitor.snapshot.counters.notificationAttempts, authorized ? 1 : 0)
        }
    }

    @MainActor func testMethodsRunTogetherAndStopIndependently() async throws {
        let vpn = TestKeepAlive(), pip = TestKeepAlive(), location = TestKeepAlive()
        let manager = KeepAliveManager(services: [(.vpn, vpn), (.pip, pip), (.location, location)])
        for method in KeepAliveMethod.allCases { try await manager.setEnabled(true, method: method) }
        XCTAssertEqual(manager.entries.filter { $0.isEnabled }.count, 3)
        try await manager.setEnabled(false, method: .pip)
        XCTAssertEqual(pip.stops, 1)
        XCTAssertEqual(vpn.stops + location.stops, 0)
        XCTAssertEqual(manager.entries.filter { $0.isEnabled }.map(\.id), [.vpn, .location])
    }

    @MainActor func testOneFailureDoesNotStopAnotherMethod() async throws {
        let vpn = TestKeepAlive(), pip = TestKeepAlive()
        pip.error = KeepAliveError.message("not supported")
        let manager = KeepAliveManager(services: [(.vpn, vpn), (.pip, pip)])
        try await manager.setEnabled(true, method: .vpn)
        do { try await manager.setEnabled(true, method: .pip); XCTFail("Expected PiP failure") } catch {}
        XCTAssertEqual(vpn.state.phase, .active)
        XCTAssertEqual(vpn.stops, 0)
        XCTAssertNotNil(manager.entries.first { $0.id == .pip }?.state.lastError)
    }

    @MainActor func testLocationAndPiPShareOneBackgroundListenerAndLastStopSleepsIt() async throws {
        let fixture = HostFixture()
        fixture.coordinator.setAppExecutionAllowed(false)
        try await fixture.coordinator.reconcile()
        let runtime = try XCTUnwrap(fixture.runtimes.first)
        let location = TestKeepAlive(), pip = TestKeepAlive()
        let manager = KeepAliveManager(services: [(.location, location), (.pip, pip)])
        manager.onChange = {
            let allowed = [KeepAliveMethod.location, .pip].contains {
                manager.state(for: $0)?.phase.canMessage == true
            }
            fixture.coordinator.setAppExecutionAllowed(allowed)
        }

        location.setPhase(.starting)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        location.setPhase(.active)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.wakeCalls, 1)
        // A temporary positioning failure does not end the location session.
        location.setPhase(.reasserting)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.wakeCalls, 1)

        try await manager.setEnabled(true, method: .pip)
        try await fixture.coordinator.reconcile()
        XCTAssertEqual(fixture.runtimes.count, 1)
        XCTAssertEqual(runtime.wakeCalls, 1)
        try await manager.setEnabled(false, method: .location)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(pip.stops, 0)

        try await manager.setEnabled(false, method: .pip)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertNil(runtime.snapshot.heartbeatAt)
        try await manager.setEnabled(true, method: .location)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.wakeCalls, 2)
        location.setPhase(.failed)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertEqual(fixture.runtimes.count, 1)
    }

    @MainActor func testManagerRecordsConfirmedPipActiveTransition() async throws {
        let pip = TestKeepAlive()
        var events: [(String, [String: String])] = []
        let manager = KeepAliveManager(services: [(.pip, pip)]) { event, fields in
            events.append((event, fields))
        }
        XCTAssertEqual(events.first?.0, "keepalive_initial_state")
        try await manager.setEnabled(true, method: .pip)
        XCTAssertTrue(events.contains { $0.0 == "keepalive_pip_active" && $0.1["phase"] == "active" })
    }

    @MainActor func testOffDuringAsynchronousStartCannotLeaveServiceRunning() async throws {
        let pip = TestKeepAlive()
        pip.holdStart = true
        let manager = KeepAliveManager(services: [(.pip, pip)])
        let start = Task { try await manager.setEnabled(true, method: .pip) }
        while pip.resumeStart == nil { await Task.yield() }
        try await manager.setEnabled(false, method: .pip)
        pip.resumeStart?(); pip.resumeStart = nil
        try await start.value
        XCTAssertEqual(pip.state.phase, .stopped)
        XCTAssertFalse(manager.entries[0].isEnabled)
    }

    @MainActor func testVPNHandoffWaitsForIssuedNotificationThenTransfersLatestHistory() async throws {
        let fixture = HostFixture()
        try await fixture.coordinator.reconcile()
        XCTAssertEqual(fixture.runtimes.count, 1)
        let runtime = fixture.runtimes[0]
        runtime.holdStop = true
        let handoff = Task { try await fixture.coordinator.prepareForVPNStart() }
        while runtime.finishStop == nil { await Task.yield() }
        XCTAssertFalse(fixture.coordinator.canMessage)
        XCTAssertEqual(fixture.runtimes.count, 1)
        let latest = SubmissionHistory(target: .dark, submittedAt: Date(timeIntervalSince1970: 300))
        runtime.snapshot.history = latest
        runtime.finishStop?(); runtime.finishStop = nil
        try await handoff.value
        XCTAssertEqual(fixture.configuration.savedHistory, latest)
        XCTAssertEqual(fixture.local.savedHistory, latest)
        XCTAssertTrue(fixture.coordinator.usesVPN)
    }

    @MainActor func testProviderReadbackFailureDoesNotStartDuplicateLocalListener() async throws {
        let fixture = HostFixture()
        fixture.vpnState.phase = .active
        fixture.vpn.queryError = MonitorChannelError.emptyReply
        try await fixture.coordinator.reconcile()
        do { _ = try await fixture.coordinator.queryStatus(); XCTFail("Expected unavailable readback") } catch {}
        XCTAssertTrue(fixture.coordinator.usesVPN)
        XCTAssertTrue(fixture.runtimes.isEmpty)
    }

    @MainActor func testStoppingVPNReturnsToOneLocalHostAndPreservesNewerHistory() async throws {
        let fixture = HostFixture()
        fixture.vpnState.phase = .active
        let latest = SubmissionHistory(target: .light, submittedAt: Date(timeIntervalSince1970: 200))
        fixture.vpn.reply.snapshot?.history = latest
        fixture.local.savedHistory = SubmissionHistory(target: .dark, submittedAt: Date(timeIntervalSince1970: 100))
        _ = try await fixture.coordinator.queryStatus()
        fixture.vpnState.phase = .stopping
        try await fixture.coordinator.reconcile()
        XCTAssertTrue(fixture.runtimes.isEmpty)
        fixture.vpnState.phase = .stopped
        async let first: Void = fixture.coordinator.reconcile()
        async let second: Void = fixture.coordinator.reconcile()
        _ = try await (first, second)
        XCTAssertEqual(fixture.runtimes.count, 1)
        XCTAssertEqual(fixture.local.savedHistory, latest)
        XCTAssertEqual(fixture.configuration.savedHistory, latest)
        XCTAssertFalse(fixture.coordinator.usesVPN)
    }

    @MainActor func testFailedVPNStartRestoresLocalHostWithSavedFeatureSwitch() async throws {
        let fixture = HostFixture()
        fixture.configuration.config.isEnabled = false
        try await fixture.coordinator.reconcile()
        try await fixture.coordinator.prepareForVPNStart()
        try await fixture.coordinator.finishVPNStartRequest()
        XCTAssertEqual(fixture.runtimes.count, 2)
        XCTAssertEqual(fixture.runtimes[0].stops, 1)
        XCTAssertFalse(fixture.runtimes[1].snapshot.appliedConfiguration.isEnabled)
        XCTAssertTrue(fixture.coordinator.canMessage)
    }

    @MainActor func testLocalLogsRemainExportableWhileVPNOwnsMonitoring() async throws {
        let fixture = HostFixture()
        fixture.vpnState.phase = .active
        XCTAssertEqual(try fixture.coordinator.localDiagnostics(stream: .boost), "app-boost\n")
        let remote = try await fixture.coordinator.diagnostics(stream: .boost)
        XCTAssertEqual(remote, "vpn-boost\n")
        XCTAssertTrue(fixture.runtimes.isEmpty)
    }

    @MainActor func testBackgroundWithoutActivePipPausesLocalRuntimeAndActivePipResumesIt() async throws {
        let fixture = HostFixture()
        try await fixture.coordinator.reconcile()
        let runtime = try XCTUnwrap(fixture.runtimes.first)
        XCTAssertEqual(runtime.samples, 1)

        // PiP starting, stopped, or failed all map to execution disallowed.
        fixture.coordinator.setAppExecutionAllowed(false)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertEqual(runtime.sleepCalls, 1)
        XCTAssertNil(runtime.snapshot.heartbeatAt)

        // Only the caller's confirmed active/reasserting platform state grants it again.
        fixture.coordinator.setAppExecutionAllowed(true)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.wakeCalls, 1)
    }

    @MainActor func testPiPStartingBackgroundWakeReinstallsProductionSwitchMonitorSampling() async throws {
        let configuration = HostStore()
        let local = HostStore()
        let vpn = HostVPN()
        let sampler = HostBrightnessSampler()
        var monitor: SwitchMonitor?
        let coordinator = MonitoringHostCoordinator(vpn: vpn, vpnState: { KeepAliveState(phase: .stopped) },
            configurationStore: configuration, localStore: local, makeRuntime: {
                let current = try SwitchMonitor(store: local, sampler: sampler,
                    notifications: HostNoopNotifications())
                monitor = current
                return current
            }, exportLocal: { _ in "" })
        try await coordinator.reconcile()
        let runtime = try XCTUnwrap(monitor)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(sampler.startCalls, 1)
        let preSleepReceive = try XCTUnwrap(sampler.receive)

        let pip = TestKeepAlive()
        let manager = KeepAliveManager(services: [(.pip, pip)])
        manager.onChange = {
            let confirmedActive = pip.state.phase == .active || pip.state.phase == .reasserting
            coordinator.setAppExecutionAllowed(confirmedActive)
        }
        coordinator.setAppExecutionAllowed(false)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertNil(runtime.snapshot.heartbeatAt)

        pip.setPhase(.starting)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        pip.setPhase(.active)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(sampler.startCalls, 2)
        XCTAssertEqual(runtime.snapshot.activePollInterval, BrightnessTrendModel.normalPollInterval)

        // Late callback from the pre-sleep observer belongs to an invalid generation.
        let sampleCountAfterWake = runtime.snapshot.counters.samples
        preSleepReceive(BrightnessReading(value: 0.7, source: .poll, timestamp: Date(), uptime: 20))
        XCTAssertEqual(runtime.snapshot.counters.samples, sampleCountAfterWake)

        // Repeating the same active permission aligns state without replacing the sampler.
        coordinator.setAppExecutionAllowed(true)
        XCTAssertEqual(sampler.startCalls, 2)
        let heartbeat = Date(timeIntervalSince1970: 1_800_000_000)
        sampler.receive?(BrightnessReading(value: 0.62, source: .poll, timestamp: heartbeat, uptime: 30))
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.snapshot.heartbeatAt, heartbeat)
        XCTAssertEqual(runtime.snapshot.lastPollAt, heartbeat)
        XCTAssertEqual(runtime.snapshot.counters.polls, 1)

        // If another lifecycle edge left a sleeping runtime behind while policy
        // stayed allowed, the repeated grant repairs that phase mismatch.
        runtime.sleep()
        coordinator.setAppExecutionAllowed(true)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(sampler.startCalls, 3)
    }

    @MainActor func testBackgroundRuntimeCreatedWithoutKeepAliveDoesNotSample() async throws {
        let fixture = HostFixture()
        fixture.coordinator.setAppExecutionAllowed(false)
        try await fixture.coordinator.reconcile()

        let runtime = try XCTUnwrap(fixture.runtimes.first)
        XCTAssertEqual(runtime.samples, 0)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertTrue(runtime.snapshot.appliedConfiguration.isEnabled)

        // Configuration remains writable while asleep and does not wake sampling.
        var configuration = fixture.configuration.config
        configuration.isEnabled = false
        configuration.revision = "sleeping-update"
        _ = try await fixture.coordinator.applyConfiguration(configuration)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertFalse(runtime.snapshot.appliedConfiguration.isEnabled)
        XCTAssertEqual(runtime.samples, 0)
    }

    @MainActor func testForegroundRestoresSamplingWithoutAnyBackgroundKeepAlive() async throws {
        let fixture = HostFixture()
        try await fixture.coordinator.reconcile()
        let runtime = try XCTUnwrap(fixture.runtimes.first)
        fixture.coordinator.setAppExecutionAllowed(false)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)

        // Foreground policy is independent of PiP or Location service status.
        fixture.coordinator.setAppExecutionAllowed(true)
        XCTAssertEqual(runtime.snapshot.phase, .running)
        XCTAssertEqual(runtime.samples, 2)
    }

    @MainActor func testLocalExecutionPauseDoesNotAffectVPNOwnedRuntime() async throws {
        let fixture = HostFixture()
        fixture.vpnState.phase = .active
        fixture.coordinator.setAppExecutionAllowed(false)
        try await fixture.coordinator.reconcile()
        XCTAssertTrue(fixture.coordinator.usesVPN)
        XCTAssertTrue(fixture.runtimes.isEmpty)
        XCTAssertEqual(fixture.vpn.reply.snapshot?.phase, .starting)
    }

    @MainActor func testBackgroundHostConstructionFailureRestoresSavedConfiguration() async throws {
        let fixture = HostFixture()
        fixture.constructionError = ProjectError.message("construction failed")
        fixture.coordinator.setAppExecutionAllowed(false)
        do {
            try await fixture.coordinator.reconcile()
            XCTFail("Expected failed construction")
        } catch {
            XCTAssertTrue(fixture.local.config.isEnabled)
            XCTAssertFalse(fixture.coordinator.canMessage)
            XCTAssertTrue(fixture.runtimes.isEmpty)
        }
        fixture.constructionError = nil
        try await fixture.coordinator.reconcile()
        let runtime = try XCTUnwrap(fixture.runtimes.first)
        XCTAssertEqual(runtime.samples, 0)
        XCTAssertEqual(runtime.snapshot.phase, .sleeping)
        XCTAssertTrue(runtime.snapshot.appliedConfiguration.isEnabled)
    }
}

@MainActor private final class TestKeepAlive: KeepAliveService {
    let name = "Test"
    var state = KeepAliveState(phase: .stopped)
    var onStateChange: ((KeepAliveState) -> Void)?
    var error: Error?
    var holdStart = false
    var resumeStart: (() -> Void)?
    var stops = 0
    func prepare() async throws {}
    func refresh() async throws {}
    func updateState() {}
    func start() async throws {
        if let error { throw error }
        if holdStart { await withCheckedContinuation { continuation in resumeStart = { continuation.resume() } } }
        state.phase = .active; onStateChange?(state)
    }
    func stop() { stops += 1; state.phase = .stopped; onStateChange?(state) }
    func setPhase(_ phase: KeepAlivePhase) { state.phase = phase; onStateChange?(state) }
}

private final class HostStore: MonitorStore {
    var config = MonitorConfiguration()
    var savedHistory: SubmissionHistory?
    var savedSnapshot: RuntimeSnapshot?
    var records: [LogRecord] = []
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws { config = value }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ value: RuntimeSnapshot) throws { savedSnapshot = value }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ value: SubmissionHistory) throws { savedHistory = value }
    func append(_ record: LogRecord) throws { records.append(record) }
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {}
    func recoverBoostTraces(instanceID: String, at: Date) throws {}
}

@MainActor private final class HostRuntime: MonitoringRuntime {
    var snapshot: RuntimeSnapshot
    let currentConfiguration: () -> MonitorConfiguration
    var holdStop = false
    var finishStop: (() -> Void)?
    var stops = 0
    var samples = 0
    var sleepCalls = 0
    var wakeCalls = 0
    init(configuration: MonitorConfiguration, currentConfiguration: @escaping () -> MonitorConfiguration) {
        self.currentConfiguration = currentConfiguration
        snapshot = RuntimeSnapshot(instanceID: "test-local", appliedConfiguration: configuration, counters: RuntimeCounters())
    }
    func start() throws {
        snapshot.phase = .running
        if snapshot.appliedConfiguration.isEnabled { samples += 1 }
    }
    func fail(_ error: Error, completion: @escaping () -> Void) { completion() }
    func stop(reason: String, finalPhase: RuntimePhase, completion: @escaping () -> Void) {
        stops += 1
        if holdStop { finishStop = { self.snapshot.phase = finalPhase; completion() } }
        else { snapshot.phase = finalPhase; completion() }
    }
    func sleep() {
        sleepCalls += 1
        snapshot.phase = .sleeping
        snapshot.heartbeatAt = nil
    }
    func wake() {
        wakeCalls += 1
        snapshot.phase = .running
        if snapshot.appliedConfiguration.isEnabled { samples += 1 }
    }
    func reload(expectedRevision: String?) -> MonitorReply {
        snapshot.appliedConfiguration = currentConfiguration()
        return statusReply()
    }
    func statusReply() -> MonitorReply {
        MonitorReply(success: true, message: "local", appliedRevision: snapshot.appliedConfiguration.revision,
                     snapshot: snapshot)
    }
    func flushDiagnostics() {}
}

@MainActor private final class HostBrightnessSampler: BrightnessSampling {
    private(set) var receive: ((BrightnessReading) -> Void)?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private(set) var interval: TimeInterval?
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        startCalls += 1
        self.interval = interval
        self.receive = receive
    }
    func updateInterval(_ interval: TimeInterval) { self.interval = interval }
    func sampleNow(_ source: SampleSource) {
        receive?(BrightnessReading(value: 0.5, source: source, timestamp: Date(), uptime: 10))
    }
    func stop() { stopCalls += 1; receive = nil; interval = nil }
}

@MainActor private final class HostNoopNotifications: ModeNotificationSubmitting {
    var authorized = true
    func authorization(_ completion: @escaping (Bool, String) -> Void) { completion(authorized, "test") }
    func submit(_ candidate: NotificationCandidate, source: SampleSource,
                completion: @escaping (Error?) -> Void) { completion(nil) }
}

@MainActor private final class HostVPN: MonitoringClient {
    var queryError: Error?
    var reply = MonitorReply(success: true, message: "vpn", snapshot:
        RuntimeSnapshot(instanceID: "test-vpn", appliedConfiguration: MonitorConfiguration(), counters: RuntimeCounters()))
    func queryStatus() async throws -> MonitorReply { if let queryError { throw queryError }; return reply }
    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply { reply }
    func diagnostics(stream: MonitorLogStream) async throws -> String { "vpn-\(stream.rawValue)\n" }
}

@MainActor private final class HostFixture {
    let configuration = HostStore()
    let local = HostStore()
    let vpn = HostVPN()
    var vpnState = KeepAliveState(phase: .stopped)
    var runtimes: [HostRuntime] = []
    var constructionError: Error?
    lazy var coordinator = MonitoringHostCoordinator(vpn: vpn, vpnState: { self.vpnState },
        configurationStore: configuration, localStore: local, makeRuntime: {
            if let error = self.constructionError { throw error }
            let runtime = HostRuntime(configuration: self.local.config, currentConfiguration: { self.local.config })
            self.runtimes.append(runtime)
            return runtime
        }, exportLocal: { "app-\($0.rawValue)\n" })
}
