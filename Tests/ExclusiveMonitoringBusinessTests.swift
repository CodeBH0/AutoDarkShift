import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class ExclusiveMonitoringBusinessTests: XCTestCase {
    @MainActor func testStopFailureNeverStartsTarget() async throws {
        let fixture = BusinessFixture(standardPhase: .running, appPhase: .stopped)
        fixture.standard.rejectDisable = true

        do {
            _ = try await fixture.coordinator.select(.app)
            XCTFail("Expected unconfirmed disable to fail")
        } catch { }

        XCTAssertEqual(fixture.app.enabledRequests, 0)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
    }

    @MainActor func testTargetWaitsForSubmittedNotificationToSettleBeforeStart() async throws {
        let fixture = BusinessFixture(standardPhase: .running, appPhase: .stopped)
        fixture.standard.holdSubmission = true

        let switching = Task { try await fixture.coordinator.select(.app) }
        await waitForPendingSubmission(in: fixture.standard)
        XCTAssertEqual(fixture.app.enabledRequests, 0)
        XCTAssertEqual(fixture.standardStore.savedHistory, nil)

        fixture.standard.resumeSubmission?()
        _ = try await switching.value

        XCTAssertEqual(fixture.app.enabledRequests, 1)
        XCTAssertFalse(fixture.standard.applied.isEnabled)
        XCTAssertEqual(fixture.app.phase, .running)
        XCTAssertLessThan(try XCTUnwrap(fixture.events.values.firstIndex(of: "standard.settled")),
                          try XCTUnwrap(fixture.events.values.firstIndex(of: "app.enabled")))
        XCTAssertEqual(fixture.standardStore.savedHistory?.target, .dark)
    }

    @MainActor func testResumeConflictDisablesStandardBeforeAnyHostQueryAndAppWins() async throws {
        let fixture = BusinessFixture(standardPhase: .stopped, appPhase: .stopped)
        try fixture.standardStore.saveConfiguration(MonitorConfiguration(revision: "s-on", isEnabled: true))
        try fixture.appStore.saveConfiguration(MonitorConfiguration(revision: "m-on", isEnabled: true))

        _ = try await fixture.coordinator.resumeSelected()

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.appStore.configuration().isEnabled)
        let standardDisable = try XCTUnwrap(fixture.events.values.firstIndex(of: "standardStore.disabled"))
        let firstQuery = try XCTUnwrap(fixture.events.values.firstIndex(where: { $0.hasSuffix(".query") }))
        XCTAssertLessThan(standardDisable, firstQuery)
        XCTAssertEqual(fixture.standard.enabledRequests, 0)
        XCTAssertEqual(fixture.app.enabledRequests, 1)
        XCTAssertFalse(fixture.events.values.contains("standard.apply.disabled"))
    }

    @MainActor func testConcurrentSelectionsRunInOrderAndLeaveOnlyLastSelectionEnabled() async throws {
        let fixture = BusinessFixture(standardPhase: .running, appPhase: .stopped)
        fixture.standard.holdSubmission = true

        let first = Task { try await fixture.coordinator.select(.app) }
        await waitForPendingSubmission(in: fixture.standard)
        let second = Task { try await fixture.coordinator.select(.standard) }
        fixture.standard.resumeSubmission?()
        _ = try await first.value
        _ = try await second.value

        XCTAssertTrue(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
        XCTAssertEqual(fixture.standard.phase, .running)
        XCTAssertFalse(fixture.app.applied.isEnabled)
        XCTAssertEqual(fixture.app.enabledRequests, 1)
        XCTAssertEqual(fixture.standard.enabledRequests, 1)
    }

    @MainActor func testRepeatedSelectionNeverEnablesBothBusinesses() async throws {
        let fixture = BusinessFixture(standardPhase: .stopped, appPhase: .stopped)

        _ = try await fixture.coordinator.select(.app)
        _ = try await fixture.coordinator.select(.app)

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.appStore.configuration().isEnabled)
        XCTAssertEqual(fixture.standard.enabledRequests, 0)
        XCTAssertEqual(fixture.app.enabledRequests, 2)
    }

    @MainActor func testSelectingNilLeavesBothBusinessesDisabled() async throws {
        let fixture = BusinessFixture(standardPhase: .running, appPhase: .running)

        let reply = try await fixture.coordinator.select(nil)

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
        XCTAssertFalse(fixture.standard.applied.isEnabled)
        XCTAssertFalse(fixture.app.applied.isEnabled)
        XCTAssertNil(reply?.snapshot?.activePollInterval)
    }

    @MainActor func testInactiveAppHostIsNotReconciledWhenStandardIsSelected() async throws {
        let events = EventList()
        let standardStore = BusinessStore(name: "standardStore", events: events)
        let appStore = BusinessStore(name: "appStore", events: events)
        let vpn = BusinessClient(name: "vpn", phase: .stopped, events: events)
        var standardStarts = 0
        var appFactoryCalls = 0
        let standardHost = MonitoringHostCoordinator(process: .packetTunnel, vpn: vpn,
            vpnState: { KeepAliveState(phase: .stopped) },
            configurationStore: standardStore, localStore: standardStore,
            makeRuntime: {
                standardStarts += 1
                return BusinessRuntime(configuration: try standardStore.configuration())
            }, exportLocal: { _ in "" })
        let appHost = MonitoringHostCoordinator(process: .app, vpn: vpn,
            vpnState: { KeepAliveState(phase: .stopped) },
            configurationStore: appStore, localStore: appStore,
            makeRuntime: {
                appFactoryCalls += 1
                throw ProjectError.message("App brightness source unavailable")
            }, exportLocal: { _ in "" })
        let coordinator = ExclusiveMonitoringBusiness(standard: standardHost, standardStore: standardStore,
            app: appHost, appStore: appStore)

        _ = try await coordinator.select(.standard)

        XCTAssertEqual(standardStarts, 0)
        XCTAssertEqual(appFactoryCalls, 0)
        XCTAssertTrue(try standardStore.configuration().isEnabled)
        XCTAssertFalse(try appStore.configuration().isEnabled)
    }

    @MainActor func testDisconnectedTunnelCanBeSelectedDisabledAndReplacedByAppPath() async throws {
        let fixture = ProcessBusinessFixture()
        fixture.vpn.queryError = MonitorChannelError.emptyReply
        let selected = try await fixture.coordinator.select(.standard)
        XCTAssertEqual(selected?.snapshot?.phase, .stopped)
        XCTAssertTrue(selected?.snapshot?.appliedConfiguration.isEnabled == true)
        XCTAssertNil(selected?.snapshot?.heartbeatAt)
        XCTAssertEqual(fixture.appStarts, 0)
        XCTAssertTrue(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)

        _ = try await fixture.coordinator.select(nil)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
        XCTAssertEqual(fixture.appStarts, 0)

        _ = try await fixture.coordinator.select(.standard)
        let appReply = try await fixture.coordinator.select(.app)
        XCTAssertEqual(appReply?.snapshot?.phase, .running)
        XCTAssertEqual(fixture.appStarts, 1)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.appStore.configuration().isEnabled)
        XCTAssertFalse(fixture.events.values.contains("vpn.query"))
        XCTAssertEqual(fixture.tunnelAppStarts, 0)
    }

    @MainActor func testUnknownTunnelReadbackBlocksAppBusinessStartup() async throws {
        for phase in [KeepAlivePhase.starting, .active, .reasserting, .stopping, .failed] {
            let fixture = ProcessBusinessFixture()
            fixture.vpnState.phase = phase
            fixture.vpn.queryError = MonitorChannelError.emptyReply
            do {
                _ = try await fixture.coordinator.select(.app)
                XCTFail("Unknown tunnel state cannot authorize the App path: \(phase)")
            } catch { }
            XCTAssertEqual(fixture.appStarts, 0)
            XCTAssertEqual(fixture.tunnelAppStarts, 0)
            XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
            XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
        }
    }

    @MainActor func testPacketTunnelNotificationSettlesBeforeAppPathStarts() async throws {
        let fixture = ProcessBusinessFixture()
        fixture.vpnState.phase = .active
        fixture.vpn.phase = .running
        fixture.vpn.applied.isEnabled = true
        fixture.vpn.holdSubmission = true
        let selecting = Task { try await fixture.coordinator.select(.app) }
        await waitForPendingSubmission(in: fixture.vpn)
        XCTAssertEqual(fixture.appStarts, 0)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        fixture.vpn.resumeSubmission?()
        _ = try await selecting.value
        XCTAssertEqual(fixture.appStarts, 1)
        XCTAssertEqual(fixture.standardStore.savedHistory?.target, .dark)
        XCTAssertFalse(fixture.vpn.applied.isEnabled)
        XCTAssertEqual(fixture.tunnelAppStarts, 0)
        XCTAssertLessThan(try XCTUnwrap(fixture.events.values.firstIndex(of: "vpn.settled")),
                          try XCTUnwrap(fixture.events.values.firstIndex(of: "app.started")))
    }

    @MainActor func testPersistedConflictResumesOnlyAppPathWithoutStartingTunnelSampler() async throws {
        let fixture = ProcessBusinessFixture()
        fixture.standardStore.config.isEnabled = true
        fixture.appStore.config.isEnabled = true
        _ = try await fixture.coordinator.resumeSelected()
        XCTAssertEqual(fixture.appStarts, 1)
        XCTAssertEqual(fixture.tunnelAppStarts, 0)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.appStore.configuration().isEnabled)
        XCTAssertFalse(fixture.events.values.contains("vpn.query"))
    }

    @MainActor func testTunnelProfilePersistenceFailureBlocksAppStartup() async throws {
        let fixture = ProcessBusinessFixture()
        fixture.vpn.persistError = ProjectError.message("profile save failed")
        do {
            _ = try await fixture.coordinator.select(.app)
            XCTFail("Unpersisted tunnel disable cannot authorize App startup")
        } catch { }
        XCTAssertEqual(fixture.appStarts, 0)
        XCTAssertEqual(fixture.tunnelAppStarts, 0)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.appStore.configuration().isEnabled)
        XCTAssertFalse(fixture.events.values.contains("vpn.query"))
    }

    @MainActor func testTunnelDisableIsPersistedBeforeDrainAndAppStartup() async throws {
        let fixture = ProcessBusinessFixture()
        fixture.vpnState.phase = .active
        fixture.vpn.phase = .running
        fixture.vpn.applied.isEnabled = true
        _ = try await fixture.coordinator.select(.app)
        let persisted = try XCTUnwrap(fixture.events.values.firstIndex(of: "vpn.persist.disabled"))
        let queried = try XCTUnwrap(fixture.events.values.firstIndex(of: "vpn.query"))
        let drained = try XCTUnwrap(fixture.events.values.firstIndex(of: "vpn.apply.disabled"))
        let appStarted = try XCTUnwrap(fixture.events.values.firstIndex(of: "app.started"))
        XCTAssertLessThan(persisted, queried)
        XCTAssertLessThan(queried, drained)
        XCTAssertLessThan(drained, appStarted)
        XCTAssertFalse(try XCTUnwrap(fixture.vpn.persistedConfigurations.last).isEnabled)
    }

    @MainActor private func waitForPendingSubmission(in client: BusinessClient) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while client.resumeSubmission == nil && ProcessInfo.processInfo.systemUptime < deadline {
            await Task.yield()
        }
        XCTAssertNotNil(client.resumeSubmission, "The switch did not reach the held notification callback.")
    }
}

@MainActor private final class BusinessFixture {
    let events: EventList
    let standardStore: BusinessStore
    let appStore: BusinessStore
    let standard: BusinessClient
    let app: BusinessClient
    let coordinator: ExclusiveMonitoringBusiness

    init(standardPhase: RuntimePhase, appPhase: RuntimePhase) {
        events = EventList()
        standardStore = BusinessStore(name: "standardStore", events: events)
        appStore = BusinessStore(name: "appStore", events: events)
        standard = BusinessClient(name: "standard", phase: standardPhase, events: events)
        app = BusinessClient(name: "app", phase: appPhase, events: events)
        coordinator = ExclusiveMonitoringBusiness(standard: standard, standardStore: standardStore,
            app: app, appStore: appStore)
    }
}

private final class EventList {
    var values: [String] = []
}

private final class BusinessStore: MonitorStore {
    let name: String
    let events: EventList
    var config = MonitorConfiguration()
    var savedHistory: SubmissionHistory?
    var savedSnapshot: RuntimeSnapshot?
    init(name: String, events: EventList) { self.name = name; self.events = events }
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws {
        config = value
        events.values.append("\(name).\(value.isEnabled ? "enabled" : "disabled")")
    }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ snapshot: RuntimeSnapshot) throws { savedSnapshot = snapshot }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ history: SubmissionHistory) throws { savedHistory = history }
    func append(_ record: LogRecord) throws {}
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {}
    func recoverBoostTraces(instanceID: String, at: Date) throws {}
}

@MainActor private final class BusinessClient: MonitoringClient {
    let name: String
    let events: EventList
    var phase: RuntimePhase
    var applied = MonitorConfiguration()
    var queryError: Error?
    var persistError: Error?
    var persistedConfigurations: [MonitorConfiguration] = []
    var rejectDisable = false
    var holdSubmission = false
    var resumeSubmission: (() -> Void)?
    var enabledRequests = 0
    private var history: SubmissionHistory?
    private var submission: SubmissionSnapshot?

    init(name: String, phase: RuntimePhase, events: EventList) {
        self.name = name; self.phase = phase; self.events = events
        applied.isEnabled = phase != .stopped
    }

    func persistConfigurationForNextStart(_ configuration: MonitorConfiguration) async throws {
        events.values.append("\(name).persist.\(configuration.isEnabled ? "enabled" : "disabled")")
        if let persistError { throw persistError }
        persistedConfigurations.append(configuration)
    }

    func queryStatus() async throws -> MonitorReply {
        events.values.append("\(name).query")
        if let queryError { throw queryError }
        return reply(success: true, phase: phase, message: "status")
    }

    func applyConfiguration(_ configuration: MonitorConfiguration) async throws -> MonitorReply {
        events.values.append("\(name).apply.\(configuration.isEnabled ? "enabled" : "disabled")")
        if !configuration.isEnabled && rejectDisable {
            return reply(success: false, phase: phase, message: "disable rejected")
        }
        applied = configuration
        if configuration.isEnabled {
            enabledRequests += 1
            phase = .running
            events.values.append("\(name).enabled")
        } else if holdSubmission {
            submission = SubmissionSnapshot(identifier: "pending", target: .dark, brightness: 0.1,
                source: .event, timestamp: Date(), result: .submitting)
            resumeSubmission = {
                self.holdSubmission = false
                self.submission?.result = .success
                self.history = SubmissionHistory(target: .dark, submittedAt: Date())
                self.events.values.append("\(self.name).settled")
            }
        }
        return reply(success: true, phase: phase, message: "applied", revision: configuration.revision)
    }

    func prepareHostHandoff() async throws -> MonitorReply {
        events.values.append("\(name).handoff")
        return reply(success: true, phase: phase, message: "stopped")
    }

    func diagnostics(stream: MonitorLogStream) async throws -> String { "" }

    private func reply(success: Bool, phase: RuntimePhase, message: String,
                       revision: String? = nil) -> MonitorReply {
        var configuration = applied
        if let revision { configuration.revision = revision }
        var snapshot = RuntimeSnapshot(instanceID: name, phase: phase, history: history,
            appliedConfiguration: configuration, counters: RuntimeCounters())
        snapshot.submission = submission
        snapshot.activePollInterval = configuration.isEnabled ? 1 : nil
        return MonitorReply(success: success, message: message, appliedRevision: revision, snapshot: snapshot)
    }
}

@MainActor private final class BusinessRuntime: MonitoringRuntime {
    var snapshot: RuntimeSnapshot
    let currentConfiguration: (() -> MonitorConfiguration)?
    init(configuration: MonitorConfiguration, currentConfiguration: (() -> MonitorConfiguration)? = nil) {
        self.currentConfiguration = currentConfiguration
        snapshot = RuntimeSnapshot(instanceID: "business-runtime", phase: .starting,
            appliedConfiguration: configuration, counters: RuntimeCounters())
    }
    func start() throws {
        snapshot.phase = .running
        snapshot.activePollInterval = snapshot.appliedConfiguration.isEnabled ? 1 : nil
    }
    func fail(_ error: Error, completion: @escaping () -> Void) { completion() }
    func stop(reason: String, finalPhase: RuntimePhase, completion: @escaping () -> Void) {
        snapshot.phase = finalPhase
        snapshot.activePollInterval = nil
        completion()
    }
    func sleep() { snapshot.phase = .sleeping; snapshot.activePollInterval = nil }
    func wake() {
        snapshot.phase = .running
        snapshot.activePollInterval = snapshot.appliedConfiguration.isEnabled ? 1 : nil
    }
    func reload(expectedRevision: String?) -> MonitorReply {
        if let currentConfiguration { snapshot.appliedConfiguration = currentConfiguration() }
        snapshot.appliedConfiguration.revision = expectedRevision ?? snapshot.appliedConfiguration.revision
        snapshot.activePollInterval = snapshot.appliedConfiguration.isEnabled && snapshot.phase == .running ? 1 : nil
        return statusReply()
    }
    func statusReply() -> MonitorReply {
        MonitorReply(success: true, message: "business runtime",
            appliedRevision: snapshot.appliedConfiguration.revision, snapshot: snapshot)
    }
    func flushDiagnostics() {}
}


@MainActor private final class ProcessBusinessFixture {
    let events = EventList()
    lazy var standardStore = BusinessStore(name: "standardStore", events: events)
    lazy var appStore = BusinessStore(name: "appStore", events: events)
    lazy var vpn = BusinessClient(name: "vpn", phase: .stopped, events: events)
    var vpnState = KeepAliveState(phase: .stopped)
    var appStarts = 0
    var tunnelAppStarts = 0
    lazy var standard = MonitoringHostCoordinator(process: .packetTunnel, vpn: vpn,
        vpnState: { self.vpnState }, configurationStore: standardStore, localStore: standardStore,
        makeRuntime: {
            self.tunnelAppStarts += 1
            throw ProjectError.message("Packet Tunnel must never construct an App sampler")
        }, exportLocal: { _ in "" })
    lazy var app = MonitoringHostCoordinator(process: .app, vpn: vpn,
        vpnState: { self.vpnState }, configurationStore: appStore, localStore: appStore,
        makeRuntime: {
            self.appStarts += 1
            self.events.values.append("app.started")
            return BusinessRuntime(configuration: self.appStore.config,
                currentConfiguration: { self.appStore.config })
        }, exportLocal: { _ in "" })
    lazy var coordinator = ExclusiveMonitoringBusiness(standard: standard, standardStore: standardStore,
        app: app, appStore: appStore)
}
