import XCTest
#if canImport(AutoDarkShiftCore)
@testable import AutoDarkShiftCore
#endif

final class KeepAliveAndHostTests: XCTestCase {
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
}

private final class HostStore: MonitorStore {
    var config = MonitorConfiguration()
    var savedHistory: SubmissionHistory?
    var savedSnapshot: RuntimeSnapshot?
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws { config = value }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ value: RuntimeSnapshot) throws { savedSnapshot = value }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ value: SubmissionHistory) throws { savedHistory = value }
    func append(_ record: LogRecord) throws {}
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {}
    func recoverBoostTraces(instanceID: String, at: Date) throws {}
}

@MainActor private final class HostRuntime: MonitoringRuntime {
    var snapshot: RuntimeSnapshot
    var holdStop = false
    var finishStop: (() -> Void)?
    var stops = 0
    init(configuration: MonitorConfiguration) {
        snapshot = RuntimeSnapshot(instanceID: "test-local", appliedConfiguration: configuration, counters: RuntimeCounters())
    }
    func start() throws { snapshot.phase = .running }
    func fail(_ error: Error, completion: @escaping () -> Void) { completion() }
    func stop(reason: String, finalPhase: RuntimePhase, completion: @escaping () -> Void) {
        stops += 1
        if holdStop { finishStop = { self.snapshot.phase = finalPhase; completion() } }
        else { snapshot.phase = finalPhase; completion() }
    }
    func sleep() {}
    func wake() {}
    func reload(expectedRevision: String?) -> MonitorReply { statusReply() }
    func statusReply() -> MonitorReply { MonitorReply(success: true, message: "local", snapshot: snapshot) }
    func flushDiagnostics() {}
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
    lazy var coordinator = MonitoringHostCoordinator(vpn: vpn, vpnState: { self.vpnState },
        configurationStore: configuration, localStore: local, makeRuntime: {
            let runtime = HostRuntime(configuration: self.local.config)
            self.runtimes.append(runtime)
            return runtime
        }, exportLocal: { "app-\($0.rawValue)\n" })
}
