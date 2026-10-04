import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class ExclusiveMonitoringBusinessTests: XCTestCase {
    @MainActor func testStopFailureNeverStartsTarget() async throws {
        let fixture = BusinessFixture(standardPhase: .running, messagePhase: .stopped)
        fixture.standard.rejectDisable = true

        do {
            _ = try await fixture.coordinator.select(.message)
            XCTFail("Expected unconfirmed disable to fail")
        } catch { }

        XCTAssertEqual(fixture.message.enabledRequests, 0)
        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.messageStore.configuration().isEnabled)
    }

    @MainActor func testTargetWaitsForSubmittedNotificationToSettleBeforeStart() async throws {
        let fixture = BusinessFixture(standardPhase: .running, messagePhase: .stopped)
        fixture.standard.holdSubmission = true

        let switching = Task { try await fixture.coordinator.select(.message) }
        await waitForPendingSubmission(in: fixture.standard)
        XCTAssertEqual(fixture.message.enabledRequests, 0)
        XCTAssertEqual(fixture.standardStore.savedHistory, nil)

        fixture.standard.resumeSubmission?()
        _ = try await switching.value

        XCTAssertEqual(fixture.message.enabledRequests, 1)
        XCTAssertFalse(fixture.standard.applied.isEnabled)
        XCTAssertEqual(fixture.message.phase, .running)
        XCTAssertLessThan(try XCTUnwrap(fixture.events.values.firstIndex(of: "standard.settled")),
                          try XCTUnwrap(fixture.events.values.firstIndex(of: "message.enabled")))
        XCTAssertEqual(fixture.standardStore.savedHistory?.target, .dark)
    }

    @MainActor func testResumeConflictDisablesStandardBeforeAnyHostQueryAndMessageWins() async throws {
        let fixture = BusinessFixture(standardPhase: .stopped, messagePhase: .stopped)
        try fixture.standardStore.saveConfiguration(MonitorConfiguration(revision: "s-on", isEnabled: true))
        try fixture.messageStore.saveConfiguration(MonitorConfiguration(revision: "m-on", isEnabled: true))

        _ = try await fixture.coordinator.resumeSelected()

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.messageStore.configuration().isEnabled)
        let standardDisable = try XCTUnwrap(fixture.events.values.firstIndex(of: "standardStore.disabled"))
        let firstQuery = try XCTUnwrap(fixture.events.values.firstIndex(where: { $0.hasSuffix(".query") }))
        XCTAssertLessThan(standardDisable, firstQuery)
        XCTAssertEqual(fixture.standard.enabledRequests, 0)
        XCTAssertEqual(fixture.message.enabledRequests, 1)
        XCTAssertFalse(fixture.events.values.contains("standard.apply.disabled"))
    }

    @MainActor func testConcurrentSelectionsRunInOrderAndLeaveOnlyLastSelectionEnabled() async throws {
        let fixture = BusinessFixture(standardPhase: .running, messagePhase: .stopped)
        fixture.standard.holdSubmission = true

        let first = Task { try await fixture.coordinator.select(.message) }
        await waitForPendingSubmission(in: fixture.standard)
        let second = Task { try await fixture.coordinator.select(.standard) }
        fixture.standard.resumeSubmission?()
        _ = try await first.value
        _ = try await second.value

        XCTAssertTrue(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.messageStore.configuration().isEnabled)
        XCTAssertEqual(fixture.standard.phase, .running)
        XCTAssertFalse(fixture.message.applied.isEnabled)
        XCTAssertEqual(fixture.message.enabledRequests, 1)
        XCTAssertEqual(fixture.standard.enabledRequests, 1)
    }

    @MainActor func testRepeatedSelectionNeverEnablesBothBusinesses() async throws {
        let fixture = BusinessFixture(standardPhase: .stopped, messagePhase: .stopped)

        _ = try await fixture.coordinator.select(.message)
        _ = try await fixture.coordinator.select(.message)

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertTrue(try fixture.messageStore.configuration().isEnabled)
        XCTAssertEqual(fixture.standard.enabledRequests, 0)
        XCTAssertEqual(fixture.message.enabledRequests, 2)
    }

    @MainActor func testSelectingNilLeavesBothBusinessesDisabled() async throws {
        let fixture = BusinessFixture(standardPhase: .running, messagePhase: .running)

        let reply = try await fixture.coordinator.select(nil)

        XCTAssertFalse(try fixture.standardStore.configuration().isEnabled)
        XCTAssertFalse(try fixture.messageStore.configuration().isEnabled)
        XCTAssertFalse(fixture.standard.applied.isEnabled)
        XCTAssertFalse(fixture.message.applied.isEnabled)
        XCTAssertNil(reply?.snapshot?.activePollInterval)
    }

    @MainActor func testInactiveMessageHostIsNotReconciledWhenStandardIsSelected() async throws {
        let events = EventList()
        let standardStore = BusinessStore(name: "standardStore", events: events)
        let messageStore = BusinessStore(name: "messageStore", events: events)
        let vpn = BusinessClient(name: "vpn", phase: .stopped, events: events)
        var standardStarts = 0
        var messageFactoryCalls = 0
        let standardHost = MonitoringHostCoordinator(vpn: vpn,
            vpnState: { KeepAliveState(phase: .stopped) },
            configurationStore: standardStore, localStore: standardStore,
            makeRuntime: {
                standardStarts += 1
                return BusinessRuntime(configuration: try standardStore.configuration())
            }, exportLocal: { _ in "" })
        let messageHost = MonitoringHostCoordinator(vpn: vpn,
            vpnState: { KeepAliveState(phase: .stopped) },
            configurationStore: messageStore, localStore: messageStore,
            makeRuntime: {
                messageFactoryCalls += 1
                throw ProjectError.message("message API unavailable")
            }, exportLocal: { _ in "" })
        let coordinator = ExclusiveMonitoringBusiness(standard: standardHost, standardStore: standardStore,
            message: messageHost, messageStore: messageStore)

        _ = try await coordinator.select(.standard)

        XCTAssertEqual(standardStarts, 1)
        XCTAssertEqual(messageFactoryCalls, 0)
        XCTAssertTrue(try standardStore.configuration().isEnabled)
        XCTAssertFalse(try messageStore.configuration().isEnabled)
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
    let messageStore: BusinessStore
    let standard: BusinessClient
    let message: BusinessClient
    let coordinator: ExclusiveMonitoringBusiness

    init(standardPhase: RuntimePhase, messagePhase: RuntimePhase) {
        events = EventList()
        standardStore = BusinessStore(name: "standardStore", events: events)
        messageStore = BusinessStore(name: "messageStore", events: events)
        standard = BusinessClient(name: "standard", phase: standardPhase, events: events)
        message = BusinessClient(name: "message", phase: messagePhase, events: events)
        coordinator = ExclusiveMonitoringBusiness(standard: standard, standardStore: standardStore,
            message: message, messageStore: messageStore)
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

    func queryStatus() async throws -> MonitorReply {
        events.values.append("\(name).query")
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
    init(configuration: MonitorConfiguration) {
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
        snapshot.appliedConfiguration.revision = expectedRevision ?? snapshot.appliedConfiguration.revision
        return statusReply()
    }
    func statusReply() -> MonitorReply {
        MonitorReply(success: true, message: "business runtime",
            appliedRevision: snapshot.appliedConfiguration.revision, snapshot: snapshot)
    }
    func flushDiagnostics() {}
}
