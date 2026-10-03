import Foundation
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

/// Shared by XCTest and the standalone runner: both exercise the actual production files.
@MainActor enum RuntimeRegressionScenarios {
    static var cases: [(String, () async throws -> Void)] { [
        ("legacy monitor configuration defaults auto dark shift on", legacyMonitorConfiguration),
        ("disabled monitor remains ready without sampling across sleep and wake", disabledStartupLifecycle),
        ("monitor toggle preserves issued results and cancels pending authorization", monitorFeatureToggle),
        ("provider host handoff reads final issued notification history", providerHandoffDrainsIssuedNotification),
        ("lifecycle and independent sampler", lifecycle),
        ("query never creates heartbeat", queryIsReadOnly),
        ("stale sampler callbacks ignored", staleSamples),
        ("permission callback after stop cancelled", permissionAfterStop),
        ("stop waits for issued notification", stopWaitsForSubmission),
        ("reload cancels old candidate", reloadCancelsCandidate),
        ("failed permission retries on fresh samples", blockedPermissionRetries),
        ("history survives host replacement", historyAcrossHosts),
        ("startup persistence failure cleans sampling", startupFailure),
        ("in-app client reuses listener", localClient),
        ("endpoint replies without initialized listener", endpointWithoutRuntime),
        ("malformed request returns explicit error", malformedRequest),
        ("runtime identity rejects old build/storage", identityMismatch),
        ("nil reply retry succeeds", nilReplyRetry),
        ("nil replies terminate after two attempts", nilReplyBounded),
        ("timeout ignores late duplicate callbacks", timeoutAndLateReply),
        ("message cancellation completes", messageCancellation),
        ("malformed reply is not retried", malformedReply),
        ("shared store round trip and corrupt data", storageRoundTrip),
        ("JSONL tail repair and bounded diagnostic export", logRepair),
        ("trend score and deduplication", trendBoundaries),
        ("missing App Group selects explicit local mode", missingAppGroup),
        ("provider honors negotiated storage mode", providerStorageMode),
        ("local IPC applies configuration and returns real snapshot", localIPCConfiguration),
        ("local IPC rejects missing or mismatched configuration", localIPCRejectsConfiguration),
        ("provider errors survive NSError serialization", serializedError),
        ("switch follows actual lifecycle and external disconnect", switchLifecycle),
        ("switch resets after startup preparation failure", switchFailure),
        ("switch holds pending setup and blocks duplicate start", switchPendingSetup),
        ("missing readback does not declare listener failure", unavailableReadback),
        ("readback retry backs off and recovers", readbackRecovery),
        ("rejected and malformed replies remain errors", actionableReadbackFailure),
        ("retired test configuration and snapshot load as ordinary monitoring", retiredConfiguration),
        ("dynamic sampling bounds storage and preserves notifications", dynamicStorageCadence),
        ("retiming preserves observer and pending authorization", retimingPreservesAuthorization),
        ("baseline survives exit in snapshot logs and IPC", baselineSurvivesExit),
        ("in-flight notification completes after score fallback", scoreFallbackStillSubmits),
        ("observation resets preserve in-flight notification", observationResetKeepsInFlight),
        ("lifecycle cancellation consumes no cooldown", cancelledAllowsImmediateCandidate),
        ("duplicate authorization and result callbacks submit once", duplicateNotificationCallbacks),
        ("sampling gaps clear trend before evaluating new brightness", samplingGap),
        ("retired wire commands are rejected without changing sampling", retiredCommands),
        ("historic test records remain exportable without mutation", legacyDiagnosticRetention),
        ("Boost trace retains prelude every poll and post-exit changes until stability", boostTraceCompleteness),
        ("brightness events prevent premature trace stability without becoming polls", boostTraceEvents),
        ("overlapping Boost captures and lifecycle interruptions are explicit", boostTraceLifecycle),
        ("Boost trace storage survives rotation restart and paged offline export", boostTraceStorage),
        ("Boost trace recovery repairs a torn tail and retains whole captures", boostTraceRecovery),
        ("Boost trace write failure does not change sampling or notification results", boostTraceFailure),
        ("compact Boost records decode production fields and materially reduce bytes", boostCompactEncoding),
        ("split cache migration preserves old Boost data and runtime write errors", splitLogMigration),
        ("completed pagination snapshots release memory before new exports", diagnosticSnapshotRelease),
        ("raw provider probe does not depend on JSON or runtime state", transportProbe),
        ("transport fallback is sticky serialized and rejects bad replies", transportFallback),
        ("diagnostic pagination preserves snapshot and UTF8 boundaries", diagnosticPagination),
        ("provider log cache survives restart and rejects incomplete data", providerLogCache),
        ("real loopback transports both monitoring logs and Boost traces into offline export cache", loopbackExportChain)
    ] }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ detail: String) throws {
        if try condition() == false { throw ProjectError.message("Regression: \(detail)") }
    }

    private static func fixture(cooldown: Double = 0) throws -> Fixture {
        let store = MemoryStore()
        store.config = MonitorConfiguration(cooldown: cooldown)
        let sampler = FakeSampler()
        let sink = FakeNotifications()
        let clock = TestClock()
        let runtime = try SwitchMonitor(store: store, sampler: sampler, notifications: sink, clock: { clock.now },
                                       uptime: { clock.uptime })
        return Fixture(store: store, sampler: sampler, sink: sink, clock: clock, runtime: runtime)
    }

    private static func legacyMonitorConfiguration() async throws {
        let legacy = Data(#"{"revision":"legacy","cooldown":7}"#.utf8)
        let configuration = try SharedJSON.decoder().decode(MonitorConfiguration.self, from: legacy)
        try require(configuration.revision == "legacy" && configuration.cooldown == 7 && configuration.isEnabled,
                    "old persisted settings retain revision and cooldown while enabling the new feature by default")
        let current = MonitorConfiguration(revision: "current", cooldown: 2, isEnabled: false)
        let roundTrip = try SharedJSON.decoder().decode(MonitorConfiguration.self,
            from: SharedJSON.encoder().encode(current))
        try require(roundTrip == current, "explicit feature setting survives configuration persistence")
    }

    private static func disabledStartupLifecycle() async throws {
        let store = MemoryStore()
        store.config = MonitorConfiguration(isEnabled: false)
        let sampler = FakeSampler()
        let runtime = try SwitchMonitor(store: store, sampler: sampler, notifications: FakeNotifications())
        try runtime.start()
        try require(runtime.snapshot.phase == .running && runtime.snapshot.heartbeatAt == nil
                    && runtime.snapshot.activePollInterval == nil && runtime.snapshot.counters.samples == 0
                    && sampler.starts == 0 && !sampler.active,
                    "disabled startup is ready but creates no observer, sample, or heartbeat")
        let readyLog = store.logs.last { $0.event == "monitor_ready" }
        try require(readyLog != nil, "disabled monitoring can still report host readiness")
        runtime.sleep()
        runtime.wake()
        try require(runtime.snapshot.phase == .running && sampler.starts == 0
                    && runtime.snapshot.heartbeatAt == nil && runtime.snapshot.activePollInterval == nil,
                    "sleep and wake do not start sampling while the saved feature switch is off")
        try require(runtime.statusReply().snapshot?.phase == .running, "status remains queryable while disabled")
    }

    private static func monitorFeatureToggle() async throws {
        let f = try fixture()
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        let priorHistory = f.store.savedHistory
        let priorCounters = f.runtime.snapshot.counters
        try require(priorHistory?.target == .dark && priorCounters.notificationAttempts == 1
                    && priorCounters.notificationSuccesses == 1, "the test establishes a completed notification before disabling")

        let staleCallback = f.sampler.receive
        let startsBeforeDisable = f.sampler.starts
        f.store.config = MonitorConfiguration(revision: "disabled", cooldown: 0, isEnabled: false)
        let disabled = f.runtime.reload(expectedRevision: "disabled")
        try require(disabled.success && f.runtime.snapshot.phase == .running && !f.sampler.active
                    && f.runtime.snapshot.activePollInterval == nil && f.runtime.snapshot.heartbeatAt == nil,
                    "feature disable stops observation without stopping its host")
        staleCallback?(BrightnessReading(value: 0.10, source: .poll, timestamp: f.clock.now,
                                          uptime: f.clock.uptime))
        try require(f.runtime.snapshot.counters.samples == priorCounters.samples
                    && f.runtime.snapshot.counters.polls == priorCounters.polls
                    && f.runtime.snapshot.history == priorHistory,
                    "stale callbacks cannot change counts or successful history after disabling")
        f.runtime.sleep()
        f.runtime.wake()
        try require(f.sampler.starts == startsBeforeDisable && f.runtime.snapshot.phase == .running
                    && f.runtime.snapshot.heartbeatAt == nil,
                    "disabled wake leaves the independent runtime ready without polling")

        f.store.config = MonitorConfiguration(revision: "enabled", cooldown: 0, isEnabled: true)
        let enabled = f.runtime.reload(expectedRevision: "enabled")
        try require(enabled.success && f.sampler.starts == startsBeforeDisable + 1
                    && f.sampler.active && f.sampler.interval == 1
                    && f.runtime.snapshot.activePollInterval == 1,
                    "re-enable starts fresh ordinary one second observation")
        try require(f.runtime.snapshot.history == priorHistory
                    && f.runtime.snapshot.counters.notificationAttempts == priorCounters.notificationAttempts
                    && f.runtime.snapshot.counters.notificationSuccesses == priorCounters.notificationSuccesses
                    && f.runtime.snapshot.counters.extensionStarts == priorCounters.extensionStarts,
                    "feature toggling preserves history and lifecycle counters without restarting the host")

        let pending = try fixture()
        pending.sampler.value = 0.40
        pending.sink.deferAuthorization = true
        try pending.runtime.start()
        pending.clock.advance(1)
        pending.sampler.emit(0.20, at: pending.clock.now, uptime: pending.clock.uptime)
        try require(pending.runtime.snapshot.submission?.result == .submitting,
                    "a qualifying sample waits for deferred notification authorization")
        pending.store.config = MonitorConfiguration(revision: "off-pending", cooldown: 0, isEnabled: false)
        _ = pending.runtime.reload(expectedRevision: "off-pending")
        try require(pending.runtime.snapshot.submission?.result == .cancelled
                    && pending.runtime.snapshot.counters.notificationAttempts == 0,
                    "disable cancels an authorization request before notification center add")
        pending.sink.completeAuthorization(true)
        try require(pending.sink.submissions == 0 && pending.runtime.snapshot.phase == .running,
                    "late authorization cannot submit after disable or stop the keep-alive host")
    }

    private static func providerHandoffDrainsIssuedNotification() async throws {
        let f = try fixture()
        let originalConfiguration = f.store.config
        f.sampler.value = 0.40
        f.sink.deferSubmission = true
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.runtime.snapshot.counters.notificationAttempts == 1
                    && f.runtime.snapshot.history == nil,
                    "notification has been added but its accepted result is still pending")

        var localIdentity = identity
        localIdentity.storageMode = RuntimeStorageMode.localIPC.rawValue
        let endpoint = MonitorControlEndpoint(identity: localIdentity, runtime: { f.runtime }, diagnostics: { "" },
                                               configurationStore: f.store)
        let handoff = try decode(endpoint.handle(SharedJSON.encoder().encode(
            MonitorRequest(command: .prepareHostHandoff))))
        try require(handoff.success && handoff.snapshot?.phase == .stopping
                    && handoff.snapshot?.history == nil,
                    "production handoff endpoint reports stopping while an issued add is unresolved")

        f.sink.completeSubmission(nil)
        let final = try decode(endpoint.handle(SharedJSON.encoder().encode(
            MonitorRequest(command: .queryStatus))))
        try require(final.success && final.snapshot?.phase == .stopped
                    && final.snapshot?.history?.target == .dark
                    && final.snapshot?.counters.notificationSuccesses == 1,
                    "status after drain exposes the committed result and latest successful history")
        try require(f.store.config == originalConfiguration,
                    "host handoff and final readback leave saved monitoring parameters unchanged")
    }

    private static func lifecycle() async throws {
        let f = try fixture()
        try f.runtime.start()
        try require(f.sampler.starts == 1 && f.runtime.snapshot.sample?.source == .initial, "initial sampling")
        try require(f.runtime.snapshot.counters.samples == 1, "initial sample counter")
        f.runtime.sleep()
        try require(f.runtime.snapshot.phase == .sleeping && f.runtime.snapshot.heartbeatAt == nil, "sleep removes heartbeat")
        f.clock.advance(5)
        f.runtime.wake()
        try require(f.sampler.starts == 2 && f.runtime.snapshot.sample?.source == .wake, "wake restarts sampling")
        var finished = false
        f.runtime.stop(reason: "test", finalPhase: .stopped) { finished = true }
        try require(finished && f.runtime.snapshot.phase == .stopped && !f.sampler.active, "clean stop")
    }

    private static func queryIsReadOnly() async throws {
        let f = try fixture()
        try f.runtime.start()
        let before = f.runtime.snapshot
        f.clock.advance(20)
        _ = f.runtime.statusReply()
        try require(f.runtime.snapshot.heartbeatAt == before.heartbeatAt, "query heartbeat unchanged")
        try require(f.runtime.snapshot.counters.samples == before.counters.samples, "query creates no samples")
    }

    private static func staleSamples() async throws {
        let f = try fixture()
        try f.runtime.start()
        let oldCallback = f.sampler.receive
        f.runtime.sleep()
        f.runtime.wake()
        let count = f.runtime.snapshot.counters.samples
        oldCallback?(BrightnessReading(value: 0, source: .poll, timestamp: f.clock.now))
        try require(f.runtime.snapshot.counters.samples == count, "old sampler generation ignored")
    }

    private static func permissionAfterStop() async throws {
        let f = try fixture()
        f.sink.deferAuthorization = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        var stopped = false
        f.runtime.stop(reason: "test", finalPhase: .stopped) { stopped = true }
        try require(!stopped, "stop drains permission callback")
        f.sink.completeAuthorization(true)
        try require(stopped && f.sink.submissions == 0, "stale permission sends no notification")
        try require(f.runtime.snapshot.submission?.result == .cancelled, "stale candidate cancelled")
    }

    private static func stopWaitsForSubmission() async throws {
        let f = try fixture()
        f.sink.deferSubmission = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        var completions = 0
        f.runtime.stop(reason: "first", finalPhase: .stopped) { completions += 1 }
        f.runtime.stop(reason: "second", finalPhase: .stopped) { completions += 1 }
        try require(completions == 0 && f.runtime.snapshot.phase == .stopping, "all stop calls wait")
        f.sink.completeSubmission(nil)
        try require(completions == 2 && f.store.savedHistory?.target == .dark, "submission committed before both stops")
        try require(f.runtime.snapshot.phase == .stopped && f.runtime.snapshot.heartbeatAt == nil, "stop does not revive heartbeat")
    }

    private static func reloadCancelsCandidate() async throws {
        let f = try fixture()
        f.sink.deferAuthorization = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        f.store.config = MonitorConfiguration(revision: "new", cooldown: 0)
        let reply = f.runtime.reload(expectedRevision: "new")
        try require(reply.success && f.sampler.interval == 1, "configuration applies to scheduler")
        f.sink.completeAuthorization(true)
        try require(f.sink.submissions == 0, "configuration invalidates old candidate")
        let mismatch = f.runtime.reload(expectedRevision: "old")
        try require(!mismatch.success && mismatch.appliedRevision == "new", "stale config not acknowledged")
    }

    private static func blockedPermissionRetries() async throws {
        let f = try fixture(cooldown: 2)
        f.sink.allowed = false
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.runtime.snapshot.submission?.result == .blocked && f.sink.submissions == 0, "permission block")
        f.sink.allowed = true
        f.clock.advance(1)
        f.sampler.emit(0.15, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sink.submissions == 0, "cooldown preserved")
        f.clock.advance(1)
        f.sampler.emit(0.10, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sink.submissions == 1 && f.runtime.snapshot.history?.target == .dark, "fresh sample retries")
    }

    private static func historyAcrossHosts() async throws {
        let f = try fixture()
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        f.runtime.stop(reason: "replace host", finalPhase: .stopped) {}
        let newSampler = FakeSampler()
        newSampler.value = 0
        let newSink = FakeNotifications()
        let newRuntime = try SwitchMonitor(store: f.store, sampler: newSampler, notifications: newSink)
        try newRuntime.start()
        try require(newSink.submissions == 0 && newRuntime.snapshot.history?.target == .dark, "same target dedupes across host instances")
    }

    private static func startupFailure() async throws {
        let f = try fixture()
        f.store.failSnapshot = true
        do { try f.runtime.start(); throw ProjectError.message("Expected storage failure") }
        catch {
            try require(!f.sampler.active && f.runtime.snapshot.heartbeatAt == nil && f.runtime.snapshot.phase == .failed,
                        "failed start leaves no sampling resources")
        }
    }

    private static func localClient() async throws {
        let f = try fixture()
        try f.runtime.start()
        let client = LocalMonitoringClient(runtime: f.runtime, store: f.store, diagnostics: { "local\n" })
        let config = MonitorConfiguration(revision: "local", cooldown: 4)
        let reply = try await client.applyConfiguration(config)
        try require(reply.appliedRevision == "local" && f.sampler.interval == 1, "in-app client has same configuration behavior")
        let diagnostics = try await client.diagnostics()
        try require(diagnostics == "local\n", "local diagnostics")
    }

    private static var identity: RuntimeIdentity {
        RuntimeIdentity(bundleIdentifier: "example.PacketTunnel", buildVersion: "4", appGroupIdentifier: "group.example")
    }
    private static func endpointWithoutRuntime() async throws {
        let endpoint = MonitorControlEndpoint(identity: identity, runtime: { nil }, diagnostics: { "provider startup failure\n" })
        let query = try decode(endpoint.handle(SharedJSON.encoder().encode(MonitorRequest(command: .handshake))))
        try require(!query.success && query.identity == identity, "handshake has identity even without runtime")
        let log = try decode(endpoint.handle(SharedJSON.encoder().encode(MonitorRequest(command: .exportDiagnostics))))
        try require(log.success && log.diagnostics != nil, "diagnostics independent of runtime")
    }
    private static func malformedRequest() async throws {
        let endpoint = MonitorControlEndpoint(identity: identity, runtime: { nil }, diagnostics: { "" })
        let reply = try decode(endpoint.handle(Data("bad json".utf8)))
        try require(!reply.success && reply.identity == identity, "malformed requests get explicit replies")
    }
    private static func decode(_ data: Data?) throws -> MonitorReply {
        guard let data else { throw ProjectError.message("Missing reply") }
        return try SharedJSON.decoder().decode(MonitorReply.self, from: data)
    }
    private static func identityMismatch() async throws {
        try identity.validate(against: identity)
        var old = identity
        old.storageMode = "local-v1"
        var rejected = false
        do { try old.validate(against: identity) } catch { rejected = true }
        try require(rejected, "old storage rejected")
        old = identity
        old.buildVersion = "3"
        rejected = false
        do { try old.validate(against: identity) } catch { rejected = true }
        try require(rejected, "old build rejected")
    }
    private static func nilReplyRetry() async throws {
        let channel = MonitorMessageChannel(retryNanoseconds: 0)
        let payload = try SharedJSON.encoder().encode(MonitorReply(success: true, message: "ok", identity: identity))
        var calls = 0
        let reply = try await channel.send(.init(command: .queryStatus)) { _, completion in
            calls += 1
            completion(calls == 1 ? nil : payload)
        }
        try require(calls == 2 && reply.success, "nil reply startup race recovered")
    }
    private static func nilReplyBounded() async throws {
        var calls = 0
        var rejected = false
        do {
            _ = try await MonitorMessageChannel(retryNanoseconds: 0).send(.init(command: .queryStatus)) { _, completion in
                calls += 1; completion(nil)
            }
        } catch { rejected = error is MonitorChannelError }
        try require(rejected && calls == 2, "nil replies terminate")
    }
    private static func timeoutAndLateReply() async throws {
        let payload = try SharedJSON.encoder().encode(MonitorReply(success: true, message: "late"))
        var callbacks: [(Data?) -> Void] = []
        var timedOut = false
        do {
            _ = try await MonitorMessageChannel(timeoutNanoseconds: 1_000_000, retryNanoseconds: 0)
                .send(.init(command: .queryStatus)) { _, completion in callbacks.append(completion) }
        } catch { timedOut = error is MonitorChannelError }
        try require(timedOut && callbacks.count == 2, "no callback timeout bounded")
        callbacks.forEach { $0(payload); $0(nil) }
        await Task.yield() // Late and duplicate replies must not resume a continuation twice.
    }
    private static func messageCancellation() async throws {
        let channel = MonitorMessageChannel(timeoutNanoseconds: 60_000_000_000)
        var callback: ((Data?) -> Void)?
        let task = Task { try await channel.send(.init(command: .queryStatus)) { _, completion in callback = completion } }
        while callback == nil { await Task.yield() }
        task.cancel()
        var cancelled = false
        do { _ = try await task.value } catch { cancelled = error is CancellationError }
        try require(cancelled, "cancelled channel terminates without deadline")
        callback?(nil)
    }
    private static func malformedReply() async throws {
        var calls = 0
        var rejected = false
        do {
            _ = try await MonitorMessageChannel(retryNanoseconds: 0).send(.init(command: .queryStatus)) { _, completion in
                calls += 1; completion(Data("bad json".utf8))
            }
        } catch { rejected = error is DecodingError }
        try require(rejected && calls == 1, "decode failures never retry")
    }
    private static func withStore(_ body: (SharedStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(SharedStore(directory: root), root)
    }
    private static func storageRoundTrip() async throws {
        try withStore { store, root in
            let defaults = try store.configuration()
            try require(defaults.revision == "defaults-v1", "defaults when absent")
            var config = defaults
            config.revision = "saved"
            try store.saveConfiguration(config)
            try require(try store.configuration() == config, "config round trip")
            let history = SubmissionHistory(target: .light, submittedAt: Date())
            try store.saveHistory(history)
            try require(try store.history()?.target == .light, "history round trip")
            try Data("broken".utf8).write(to: root.appendingPathComponent("configuration.json"))
            var corrupt = false
            do { _ = try store.configuration() } catch { corrupt = true }
            try require(corrupt, "corrupt config never silently falls back")
        }
    }
    private static func logRepair() async throws {
        try withStore { store, root in
            try store.append(LogRecord(instanceID: "test", event: "before"))
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("runtime-0.jsonl"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{truncated".utf8))
            try handle.close()
            try store.append(LogRecord(instanceID: "test", event: "after"))
            let data = try store.exportData(metadata: [:])
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            for line in lines { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
            try require(lines.count == 3, "broken append tail removed")
            for i in 0..<100 { try store.append(LogRecord(instanceID: "test", event: "event-\(i)", fields: ["text": String(repeating: "x", count: 100)])) }
            let tail = try store.diagnosticTail(maxBytes: 1024)
            try require(tail.utf8.count <= 1024 && tail.contains("event-99"), "bounded diagnostic tail keeps newest records")
            for line in tail.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        }
    }
    private static func trendBoundaries() async throws {
        var machine = try BrightnessTrendStateMachine(configuration: MonitorConfiguration(cooldown: 0))
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        try require(machine.sample(brightness: 0.40, at: t, uptime: 0) == nil, "first reading has no transition")
        guard let dark = machine.sample(brightness: 0.20, at: t.addingTimeInterval(1), uptime: 1) else {
            throw ProjectError.message("Missing dark trend candidate")
        }
        machine.complete(dark, result: .success, at: t.addingTimeInterval(1))
        try require(machine.sample(brightness: 0.18, at: t.addingTimeInterval(1.1), uptime: 1.1) == nil, "same target dedupes")
        machine.resetObservations()
        _ = machine.sample(brightness: 0.10, at: t.addingTimeInterval(2), uptime: 2)
        let light = machine.sample(brightness: 0.30, at: t.addingTimeInterval(3), uptime: 3)
        try require(light?.target == .light, "opposite trend switches immediately at score threshold")
    }

    private static func missingAppGroup() async throws {
        try withStore { local, _ in
            let selection = try RuntimeStoreSelection.forApp(shared: {
                throw ProjectError.message("App Group unavailable")
            }, local: { local })
            try require(selection.mode == .localIPC && selection.fallbackReason?.contains("App Group unavailable") == true,
                        "app selects explicit mode and retains reason")
            let configuration = MonitorConfiguration(revision: "local-start", cooldown: 4)
            try selection.store.saveConfiguration(configuration)
            try require(try selection.store.configuration() == configuration, "local mode persists editable configuration")
        }
    }

    private static func providerStorageMode() async throws {
        try withStore { local, _ in
            var sharedOpened = false
            let selected = try RuntimeStoreSelection.forProvider(mode: .localIPC, shared: {
                sharedOpened = true; throw ProjectError.message("No group")
            }, local: { local })
            try require(selected.mode == .localIPC && !sharedOpened, "local provider does not require shared entitlement")
            var rejected = false
            do {
                _ = try RuntimeStoreSelection.forProvider(mode: .appGroup, shared: {
                    throw ProjectError.message("No group")
                }, local: { local })
            } catch { rejected = true }
            try require(rejected, "provider cannot silently pick a different mode")
        }
    }

    private static func localIPCConfiguration() async throws {
        let f = try fixture()
        try f.runtime.start()
        var localIdentity = identity
        localIdentity.storageMode = RuntimeStorageMode.localIPC.rawValue
        let endpoint = MonitorControlEndpoint(identity: localIdentity, runtime: { f.runtime }, diagnostics: { "" }, configurationStore: f.store)
        let configuration = MonitorConfiguration(revision: "ipc-new", cooldown: 2)
        let before = f.runtime.snapshot.heartbeatAt
        let payload = try SharedJSON.encoder().encode(MonitorRequest(command: .reloadConfiguration,
            expectedRevision: configuration.revision, configuration: configuration))
        let reply = try await MonitorMessageChannel().send(.init(command: .reloadConfiguration,
            expectedRevision: configuration.revision, configuration: configuration)) { _, completion in
            completion(endpoint.handle(payload))
        }
        try require(reply.success && reply.appliedRevision == "ipc-new" && f.sampler.interval == 1, "IPC actually applies configuration")
        try require(reply.snapshot?.heartbeatAt == before, "IPC reply does not manufacture heartbeat")
        try require(reply.identity == localIdentity, "actual mode included in handshake")
    }

    private static func localIPCRejectsConfiguration() async throws {
        let f = try fixture()
        try f.runtime.start()
        var localIdentity = identity
        localIdentity.storageMode = RuntimeStorageMode.localIPC.rawValue
        let endpoint = MonitorControlEndpoint(identity: localIdentity, runtime: { f.runtime }, diagnostics: { "" }, configurationStore: f.store)
        let original = f.store.config
        for request in [MonitorRequest(command: .reloadConfiguration, expectedRevision: "new"),
                        MonitorRequest(command: .reloadConfiguration, expectedRevision: "different", configuration: original),
                        MonitorRequest(command: .reloadConfiguration, expectedRevision: "invalid",
                                       configuration: MonitorConfiguration(revision: "invalid", cooldown: -1))] {
            let reply = try decode(endpoint.handle(SharedJSON.encoder().encode(request)))
            try require(!reply.success && f.store.config == original, "invalid IPC input leaves old configuration intact")
        }
    }

    private static func serializedError() async throws {
        let error = ProjectError.message("App Group unavailable; local disk failed") as NSError
        try require(error.domain == "AutoDarkShift" && error.localizedDescription.contains("local disk failed"), "NSError retains precise reason")
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSError.self, from: data)
        try require(decoded?.localizedDescription == error.localizedDescription, "cross-process coding preserves description")
    }

    private static func switchLifecycle() async throws {
        let service = FakeKeepAlive()
        let control = KeepAliveSwitchControl(service: service)
        try require(!control.isOn, "initially off")
        try await control.setEnabled(true)
        try require(control.isOn && control.isTransitioning && service.starts == 1, "start indicates connecting")
        service.state.phase = .active
        try require(control.isOn && !control.isTransitioning, "connected switch on")
        try await control.setEnabled(false)
        try require(!control.isOn && control.isTransitioning && service.stops == 1, "stop indicates turning off")
        service.state.phase = .stopped
        try require(!control.isOn && !control.isTransitioning, "stopped switch off")
        service.state.phase = .active
        service.state.phase = .stopped
        try require(!control.isOn, "external disconnect reflected without saved intent")
    }

    private static func switchFailure() async throws {
        let service = FakeKeepAlive()
        service.startError = ProjectError.message("Permission denied")
        let control = KeepAliveSwitchControl(service: service)
        var rejected = false
        do { try await control.setEnabled(true) } catch { rejected = true }
        try require(rejected && !control.isOn && !control.isTransitioning, "failed preparation resets switch")
    }

    private static func switchPendingSetup() async throws {
        let service = FakeKeepAlive()
        service.deferStart = true
        let control = KeepAliveSwitchControl(service: service)
        let start = Task { try await control.setEnabled(true) }
        while service.pendingStart == nil { await Task.yield() }
        try require(control.isOn && control.isTransitioning, "switch stays on during system setup")
        try await control.setEnabled(true)
        try require(service.starts == 1, "duplicate setup does not create duplicate VPN profiles")
        service.finishStart()
        try await start.value
        try require(control.isOn, "switch follows accepted start")
    }

    private static func unavailableReadback() async throws {
        let f = try fixture()
        try f.runtime.start()
        var readback = MonitoringReadback()
        let before = f.runtime.snapshot
        do {
            _ = try await MonitorMessageChannel(retryNanoseconds: 0).send(.init(command: .handshake)) { _, completion in
                completion(nil)
            }
            throw ProjectError.message("Expected missing reply")
        } catch {
            try require(error is MonitorChannelError, "actual nil transport outcome classified")
            readback.receivedError(error, at: f.clock.now)
        }
        try require(readback.availability == .unavailable && readback.issue != nil,
                    "unavailable readback retains diagnostic without declaring failure")
        try require(f.runtime.snapshot.phase == .running && f.runtime.snapshot.heartbeatAt == before.heartbeatAt,
                    "missing query reply neither stops listener nor fabricates heartbeat")
        f.clock.advance(1)
        f.sampler.sampleNow(.poll)
        try require(f.runtime.snapshot.counters.samples > before.counters.samples, "independent listener still accepts real samples")
    }

    private static func readbackRecovery() async throws {
        var readback = MonitoringReadback()
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        for (index, delay) in [30.0, 60, 120, 300, 300].enumerated() {
            let changed = readback.receivedError(MonitorChannelError.emptyReply, at: now)
            try require(changed == (index == 0), "repeated identical absence is not a new incident")
            try require(!readback.shouldQuery(at: now.addingTimeInterval(delay - 1)), "automatic retry backs off")
            now = now.addingTimeInterval(delay)
            try require(readback.shouldQuery(at: now), "retry eventually available and capped")
        }
        readback.receivedReply(at: now)
        try require(readback.availability == .available && readback.issue == nil && readback.consecutiveUnavailable == 0,
                    "successful reply clears absence and backoff")
        try require(readback.shouldQuery(at: now.addingTimeInterval(1)), "normal refresh restored")
        readback.receivedError(MonitorChannelError.timeout, at: now)
        readback.reset()
        try require(readback.availability == .notChecked && readback.shouldQuery(at: now), "new session can query immediately")
    }

    private static func actionableReadbackFailure() async throws {
        var readback = MonitoringReadback()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        do {
            _ = try await MonitorMessageChannel().send(.init(command: .handshake)) { _, completion in
                completion(Data("bad-json".utf8))
            }
            throw ProjectError.message("Expected invalid reply")
        } catch {
            readback.receivedError(error, at: now)
            try require(readback.availability == .failed, "undecodable reply is not disguised as absence")
        }
        readback.receivedError(ProjectError.message("Incompatible provider identity"), at: now)
        try require(readback.availability == .failed && readback.issue?.contains("Incompatible") == true,
                    "identity rejection remains actionable")
    }

    private static func retiredConfiguration() async throws {
        let f = try fixture()
        try f.runtime.start()
        try withStore { store, root in
            var configuration = try JSONSerialization.jsonObject(with: SharedJSON.encoder().encode(f.store.config)) as! [String: Any]
            configuration["pollInterval"] = 2.0
            configuration["darkThreshold"] = 0.95
            configuration["lightThreshold"] = 0.98
            configuration["stableDuration"] = 100.0
            configuration["pollingBoost"] = "hz1000"
            let legacyConfiguration = try JSONSerialization.data(withJSONObject: configuration)
            try legacyConfiguration.write(to: root.appendingPathComponent("configuration.json"))
            var status = try JSONSerialization.jsonObject(with: SharedJSON.encoder().encode(f.runtime.snapshot)) as! [String: Any]
            status["appliedConfiguration"] = configuration
            status["schemaVersion"] = 1
            status.removeValue(forKey: "trend")
            status["pollingTestID"] = UUID().uuidString
            status["activePollInterval"] = 0.001
            try JSONSerialization.data(withJSONObject: status).write(to: root.appendingPathComponent("status.json"))
            let sampler = FakeSampler()
            let runtime = try SwitchMonitor(store: store, sampler: sampler, notifications: FakeNotifications())
            try runtime.start()
            try require(sampler.interval == 1 && runtime.snapshot.activePollInterval == 1,
                        "upgrade uses model 1 Hz baseline and ignores legacy interval, thresholds and Boost")
            try require(runtime.snapshot.counters.samples == f.runtime.snapshot.counters.samples + 1,
                        "legacy sample counters survive upgrade")
            try store.saveConfiguration(store.configuration())
            let saved = String(decoding: try Data(contentsOf: root.appendingPathComponent("configuration.json")), as: UTF8.self)
            let savedStatus = String(decoding: try Data(contentsOf: root.appendingPathComponent("status.json")), as: UTF8.self)
            try require(!saved.contains("pollingBoost") && !saved.contains("pollInterval")
                        && !saved.contains("darkThreshold") && !saved.contains("stableDuration")
                        && !savedStatus.contains("pollingTestID"),
                        "subsequent persistence drops retired fields")
            runtime.stop(reason: "test", finalPhase: .stopped) {}
        }
    }

    private static func dynamicStorageCadence() async throws {
        let f = try fixture()
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        let writes = f.store.snapshotWrites
        for index in 1...360 {
            let elapsed = Double(index) / 120
            f.clock.now = Date(timeIntervalSince1970: 1_700_000_001 + elapsed)
            f.sampler.emit(0.20 - min(elapsed, 0.9) * 0.12, at: f.clock.now, uptime: f.clock.uptime)
        }
        try require(f.sampler.starts == 1 && f.sampler.retimes >= 4 && f.sampler.interval == 1,
                    "dynamic rate changes preserve observer and return to 1 Hz")
        try require(f.runtime.snapshot.counters.polls == 361, "every high-rate read is evaluated")
        try require(f.sink.submissions == 1 && f.store.savedHistory?.target == .dark,
                    "score request and successful history survive high-rate storage throttling")
        try require(f.store.snapshotWrites - writes < 20 && f.store.logs.filter { $0.event == "sample" }.count < 10,
                    "routine dynamic storage stays bounded")
        try require(f.store.logs.contains { $0.event == "trend_score" }
                    && f.store.logs.contains { $0.event == "sampling_rate_changed" }, "score and rate diagnostics")
    }

    private static func retimingPreservesAuthorization() async throws {
        let f = try fixture()
        f.sink.deferAuthorization = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.10)
        f.sampler.emit(0.195, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.70)
        f.sampler.emit(0.195, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sampler.starts == 1 && f.sampler.retimes == 2 && f.sampler.interval == 1.0 / 30,
                    "fixed-time velocity retiming does not replace observation generation")
        f.sink.completeAuthorization(true)
        try require(f.sink.submissions == 1 && f.runtime.snapshot.submission?.result == .success,
                    "still-qualified authorization survives sampling rate changes")
    }

    private static func samplingGap() async throws {
        let f = try fixture()
        f.sampler.value = 0.20
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.22, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(10)
        f.sampler.emit(0.90, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.runtime.snapshot.trend?.baseline == nil && f.sampler.interval == 1 && f.sink.submissions == 0,
                    "unobserved gap cannot fabricate a transition")
        try require(f.store.logs.contains { $0.event == "sampling_gap" }, "gap diagnostic")
    }

    private static func baselineSurvivesExit() async throws {
        let f = try fixture()
        f.sampler.value = 0.10
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.25, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(1)
        f.sampler.emit(0.25, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.31)
        f.sampler.emit(0.25, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sampler.interval == 1 && f.runtime.snapshot.trend?.dynamicSampling == false,
                    "quiet trend returns to normal polling")
        for snapshot in [f.runtime.snapshot, f.store.savedSnapshot!] {
            try require(snapshot.trend?.baseline == 0.10 && snapshot.trend?.change == 1,
                        "runtime and persisted snapshot retain cumulative evidence at exit")
        }
        f.clock.advance(1)
        f.sampler.emit(0.25, at: f.clock.now, uptime: f.clock.uptime)
        let endpoint = MonitorControlEndpoint(identity: identity, runtime: { f.runtime }, diagnostics: { "" })
        let reply = try decode(endpoint.handle(SharedJSON.encoder().encode(MonitorRequest(command: .queryStatus))))
        try require(reply.snapshot?.trend?.baseline == 0.10 && reply.snapshot?.trend?.change == 1,
                    "IPC reports the retained baseline during stable 1 Hz polling")
        try require(f.store.logs.contains {
            $0.event == "sampling_rate_changed" && $0.fields["frequency"] == "1.0"
                && $0.fields["baseline"] == "0.1" && $0.fields["delta"] == "1.0"
        }, "exit diagnostic preserves baseline and delta")
        try require(f.sink.submissions == 1 && f.store.savedHistory?.target == .light,
                    "retained cumulative evidence does not duplicate a successful request")
    }

    private static func scoreFallbackStillSubmits() async throws {
        let f = try fixture()
        f.sink.deferAuthorization = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.28, at: f.clock.now, uptime: f.clock.uptime)
        let request = f.runtime.snapshot.submission!
        f.clock.advance(0.10)
        f.sampler.emit(0.28, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.31)
        f.sampler.emit(0.28, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(1)
        f.sampler.emit(0.31, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.runtime.snapshot.trend!.score > -0.50 && f.runtime.snapshot.pendingTarget == nil,
                    "ordinary sampling falls below the dark decision threshold")
        try require(f.runtime.snapshot.submission?.identifier == request.identifier
                    && f.runtime.snapshot.submission?.result == .submitting && f.sink.authorizationCalls == 1,
                    "score changes retain the single original request")
        f.sink.completeAuthorization(true)
        try require(f.sink.submissions == 1 && f.sink.lastCandidate?.target == .dark
                    && f.sink.lastCandidate?.brightness == 0.28 && f.sink.lastSource == .poll,
                    "authorization submits the original target brightness and source")
        try require(f.runtime.snapshot.sample?.brightness == 0.31
                    && f.runtime.snapshot.submission?.brightness == 0.28
                    && f.runtime.snapshot.submission?.result == .success,
                    "latest sample and original submission remain distinct and accurate")
        let reply = try SharedJSON.decoder().decode(MonitorReply.self,
            from: SharedJSON.encoder().encode(f.runtime.statusReply()))
        try require(reply.snapshot?.submission?.identifier == request.identifier
                    && reply.snapshot?.history?.target == .dark
                    && f.store.savedHistory?.target == .dark
                    && f.store.savedSnapshot?.submission?.result == .success,
                    "IPC persisted snapshot and history agree on successful completion")
        try require(f.store.logs.contains {
            $0.event == "notification_result" && $0.fields["identifier"] == request.identifier
                && $0.fields["result"] == "success"
        } && !f.store.logs.contains { $0.event == "notification_result" && $0.fields["result"] == "cancelled" },
        "score fallback produces success rather than cancellation diagnostics")
    }

    private static func observationResetKeepsInFlight() async throws {
        for invalidInput in [true, false] {
            let f = try fixture()
            f.sink.deferAuthorization = true
            f.sampler.value = 0.40
            try f.runtime.start()
            f.clock.advance(1)
            f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
            f.clock.advance(invalidInput ? 0.1 : 10)
            f.sampler.emit(invalidInput ? .nan : 0.90, at: f.clock.now, uptime: f.clock.uptime)
            try require(f.runtime.snapshot.pendingTarget == nil, "observation reset clears the pending score condition")
            f.sink.completeAuthorization(true)
            try require(f.sink.submissions == 1 && f.runtime.snapshot.submission?.result == .success
                        && f.store.savedHistory?.target == .dark,
                        "missing or invalid later observations cannot revoke an accepted candidate")
        }
    }

    private static func cancelledAllowsImmediateCandidate() async throws {
        for reload in [true, false] {
            let f = try fixture(cooldown: 30)
            f.sink.deferAuthorization = true
            f.sampler.value = 0.40
            try f.runtime.start()
            f.clock.advance(1)
            f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
            let cancelledID = f.runtime.snapshot.submission!.identifier
            if reload {
                f.store.config.revision = "cancelled-reload"
                try require(f.runtime.reload(expectedRevision: f.store.config.revision).success, "reload invalidates old generation")
            } else {
                f.runtime.sleep()
                f.clock.advance(0.1)
                f.runtime.wake()
            }
            f.sink.completeAuthorization(true)
            try require(f.runtime.snapshot.submission?.result == .cancelled && f.sink.submissions == 0
                        && f.runtime.snapshot.counters.notificationAttempts == 0 && f.store.savedHistory == nil,
                        "lifecycle cancellation submits nothing and saves no success history")
            f.sink.deferAuthorization = false
            f.clock.advance(1)
            f.sampler.emit(0.40, at: f.clock.now, uptime: f.clock.uptime)
            f.clock.advance(1)
            f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
            try require(f.runtime.snapshot.submission?.result == .success
                        && f.runtime.snapshot.submission?.identifier != cancelledID
                        && f.sink.submissions == 1 && f.runtime.snapshot.counters.notificationAttempts == 1
                        && f.runtime.snapshot.counters.notificationSuccesses == 1,
                        "next qualifying candidate submits immediately within the nominal 30 second cooldown")
            try require(f.store.savedHistory?.submittedAt == f.clock.now
                        && f.store.savedSnapshot?.submission?.result == .success,
                        "only the actually successful replacement contributes history and counters")
            let results = f.store.logs.filter { $0.event == "notification_result" }.map { $0.fields["result"] ?? "" }
            try require(results == ["cancelled", "success"], "diagnostics retain both the cancellation and replacement outcome")
        }
    }

    private static func duplicateNotificationCallbacks() async throws {
        let f = try fixture()
        f.sink.deferAuthorization = true
        f.sink.deferSubmission = true
        f.sampler.value = 0.40
        try f.runtime.start()
        f.clock.advance(1)
        f.sampler.emit(0.20, at: f.clock.now, uptime: f.clock.uptime)
        let authorization = f.sink.authorizationCallback!
        f.sink.completeAuthorization(true)
        authorization(true, "duplicate")
        try require(f.sink.submissions == 1 && f.runtime.snapshot.counters.notificationAttempts == 1,
                    "repeated authorization cannot issue a second add while the first is in flight")
        f.clock.advance(0.1)
        f.sampler.emit(0.90, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sink.authorizationCalls == 1, "opposite score cannot replace the in-flight request")
        let completion = f.sink.submissionCallback!
        f.sink.completeSubmission(nil)
        completion(nil)
        authorization(true, "stale")
        try require(f.sink.submissions == 1 && f.runtime.snapshot.counters.notificationSuccesses == 1
                    && f.store.savedHistory?.target == .dark,
                    "stale callbacks cannot resubmit or alter completion history")
    }

    private static func retiredCommands() async throws {
        let f = try fixture()
        try f.runtime.start()
        let identity = RuntimeIdentity(bundleIdentifier: "test", buildVersion: "9", appGroupIdentifier: "test")
        let endpoint = MonitorControlEndpoint(identity: identity, runtime: { f.runtime }, diagnostics: { "logs" })
        let starts = f.sampler.starts
        for command in ["startPollingTest", "stopPollingTest"] {
            let data = try JSONSerialization.data(withJSONObject: ["command": command, "pollingTestID": UUID().uuidString])
            let reply = try decode(endpoint.handle(data))
            try require(!reply.success && reply.identity == identity, "old clients receive explicit rejection of retired controls")
        }
        f.clock.advance(120)
        f.sampler.emit(0.24, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sampler.starts == starts && f.sampler.interval == 1 && f.runtime.snapshot.phase == .running,
                    "retired controls cannot start a sweep or alter normal sampling")
    }

    private static func legacyDiagnosticRetention() async throws {
        try withStore { store, root in
            let first = try SharedJSON.encoder().encode(LogRecord(instanceID: "old", event: "polling_test_stage", fields: ["testID": "historic"]))
            let last = try SharedJSON.encoder().encode(LogRecord(instanceID: "old", event: "polling_test_summary", fields: ["testID": "historic"]))
            let firstPath = root.appendingPathComponent("polling-results-1.jsonl")
            let lastPath = root.appendingPathComponent("polling-results-0.jsonl")
            var firstFile = first; firstFile.append(0x0A)
            var lastFile = last; lastFile.append(0x0A); lastFile.append(Data("{truncated".utf8))
            try firstFile.write(to: firstPath); try lastFile.write(to: lastPath)
            for index in 0..<600 {
                try store.append(LogRecord(instanceID: "current", event: "load", fields: ["index": String(index), "text": String(repeating: "x", count: 2048)]))
            }
            let legacy = try store.legacyDiagnostics()
            try require(legacy == String(decoding: firstFile + last + Data([0x0A]), as: UTF8.self),
                        "historic records are returned chronologically, skipping only the incomplete tail")
            let export = String(decoding: try store.exportData(metadata: [:]), as: UTF8.self)
            try require(export.contains("historic") && !export.contains("truncated") && !export.contains("\"index\":\"0\""),
                        "ordinary log rotation cannot evict historic test results from export")
            for line in export.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
            try require(try Data(contentsOf: firstPath) == firstFile && Data(contentsOf: lastPath) == lastFile,
                        "upgrade/export never writes, repairs or deletes the archived device records")
        }
    }

    private static func boostTraceCompleteness() async throws {
        let f = try fixture()
        try f.runtime.start()
        for _ in 1...6 {
            f.clock.advance(1); f.sampler.emit(0.24, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        let id = f.runtime.snapshot.boostTraceIDs!.first!
        let prelude = f.store.boostTraces[id]!.filter { $0.fields["phase"] == "preboost" }
        try require(prelude.count == 5 && prelude.first?.fields["sequence"] == "3"
                    && prelude.last?.fields["sequence"] == "7", "exact preceding five seconds of actual 1 Hz samples")
        let triggerTime = f.clock.now
        for index in 1...140 {
            f.clock.now = triggerTime.addingTimeInterval(Double(index) / 100)
            f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.runtime.flushDiagnostics()
        try require(f.sampler.interval == 1 && f.runtime.snapshot.boostTraceIDs == [id]
                    && !f.store.boostTraces[id]!.contains { $0.event == "boost_trace_end" },
                    "return to 1 Hz cannot end the capture")
        for index in 1...3 {
            f.clock.advance(index == 1 ? 0.4 : 1)
            f.sampler.emit(0.44 + Double(index) * 0.003, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.runtime.flushDiagnostics()
        try require(f.runtime.snapshot.boostTraceIDs == [id], "slow cumulative drift exceeding 0.005 over two seconds keeps recording")
        for _ in 1...3 {
            f.clock.advance(1); f.sampler.emit(0.449, at: f.clock.now, uptime: f.clock.uptime)
        }
        let records = f.store.boostTraces[id]!
        let samples = records.filter { $0.event == "boost_trace_sample" }
        let firstSequence = Int(samples.first!.fields["sequence"]!)!
        let lastSequence = Int(samples.last!.fields["sequence"]!)!
        try require(samples.count == lastSequence - firstSequence + 1 && samples.count >= 50
                    && samples.allSatisfy { $0.fields["source"] == "poll" },
                    "every prelude, trigger, high-rate and settled poll is retained without throttling")
        let end = records.last!
        try require(end.event == "boost_trace_end" && end.fields["complete"] == "true"
                    && end.fields["reason"] == "brightness_stable" && f.runtime.snapshot.boostTraceIDs?.isEmpty == true,
                    "only independent observed stability completes a trace")
        let trigger = samples.first { $0.fields["phase"] == "trigger" }!
        for key in ["S", "baseline", "filteredBrightness", "pollInterval", "requestedFrequency",
                    "nextFrequency", "quietDuration", "candidateID", "inFlightID"] {
            try require(trigger.fields[key] != nil, "full scoring and scheduling result: \(key)")
        }
        try require(trigger.fields["requestedFrequency"] == "1.0" && trigger.fields["nextFrequency"] == "120.0"
                    && f.sink.submissions == 1 && f.store.savedHistory?.target == .light,
                    "capture is observational and preserves the production request")
        let count = samples.count
        f.clock.advance(1); f.sampler.emit(0.449, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.store.boostTraces[id]!.filter { $0.event == "boost_trace_sample" }.count == count,
                    "a completed trace cannot keep collecting stable background polls")
    }

    private static func boostTraceEvents() async throws {
        let f = try fixture(); try f.runtime.start()
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        let id = f.runtime.snapshot.boostTraceIDs!.first!
        let trigger = f.clock.now
        for index in 1...40 {
            f.clock.now = trigger.addingTimeInterval(Double(index) / 100)
            f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.7)
        f.sampler.receive?(BrightnessReading(value: 0.60, source: .event, timestamp: f.clock.now, uptime: f.clock.uptime))
        f.clock.advance(0.1)
        f.sampler.receive?(BrightnessReading(value: 0.44, source: .event, timestamp: f.clock.now, uptime: f.clock.uptime))
        f.clock.advance(0.2); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.runtime.statusReply().snapshot?.boostTraceIDs == [id], "an observed event transient invalidates an otherwise quiet polling window")
        for _ in 1...3 { f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime) }
        let records = f.store.boostTraces[id]!
        try require(records.filter { $0.fields["source"] == "event" }.count == 2
                    && records.last?.fields["complete"] == "true" && f.runtime.snapshot.counters.eventCallbacks == 2,
                    "real events are retained separately and stability is confirmed by later polling")
    }

    private static func boostTraceLifecycle() async throws {
        for reason in ["sleep", "reload", "stop", "gap", "invalid", "clock"] {
            let f = try fixture(); try f.runtime.start()
            f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
            let id = f.runtime.snapshot.boostTraceIDs!.first!
            switch reason {
            case "sleep": f.runtime.sleep()
            case "reload": _ = f.runtime.reload(expectedRevision: f.store.config.revision)
            case "stop": f.runtime.stop(reason: "test", finalPhase: .stopped) {}
            case "gap": f.clock.advance(3); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
            case "invalid": f.clock.advance(0.1); f.sampler.emit(.nan, at: f.clock.now, uptime: f.clock.uptime)
            default: f.clock.advance(-0.1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
            }
            let end = f.store.boostTraces[id]!.last!
            try require(end.event == "boost_trace_end" && end.fields["complete"] == "false"
                        && end.fields["reason"] != "brightness_stable", "\(reason) records a partial capture without fabricating stability")
            try require(f.runtime.statusReply().snapshot?.boostTraceIDs?.isEmpty == true, "\(reason) clears active IDs in IPC")
        }
        let f = try fixture(); try f.runtime.start()
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        let first = f.runtime.snapshot.boostTraceIDs!.first!
        let trigger = f.clock.now
        for index in 1...140 {
            f.clock.now = trigger.addingTimeInterval(Double(index) / 100)
            f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.clock.advance(0.2); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        f.clock.advance(0.4); f.sampler.emit(0.24, at: f.clock.now, uptime: f.clock.uptime)
        let ids = f.runtime.statusReply().snapshot!.boostTraceIDs!
        try require(ids.count == 2 && ids.contains(first), "retrigger before stability keeps both independent captures")
        f.runtime.sleep()
        for id in ids {
            try require(f.store.boostTraces[id]!.last?.fields["reason"] == "sleep", "both captures close on lifecycle interruption")
        }
    }

    private static func boostTraceStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SharedStore(directory: root)
        let id = UUID().uuidString
        var records = [LogRecord(instanceID: "provider", event: "boost_trace_start", fields: ["traceID": id])]
        for index in 0..<9000 {
            records.append(LogRecord(instanceID: "provider", event: "boost_trace_sample", fields: [
                "traceID": id, "source": "poll", "sequence": String(index), "S": "0.70",
                "brightness": "0.44", "uptime": String(Double(index) / 120), "requestedFrequency": "120", "nextFrequency": "120", "baseline": "0.24", "filteredBrightness": "0.44"
            ]))
        }
        records.append(LogRecord(instanceID: "provider", event: "boost_trace_end", fields: ["traceID": id, "complete": "true"]))
        try store.appendBoostTrace(id: id, records: records, finished: true)
        for index in 0..<550 {
            try store.append(LogRecord(instanceID: "provider", event: "ordinary", fields: ["index": String(index), "text": String(repeating: "x", count: 2048)]))
        }
        let source = try store.boostTraceDiagnostics()
        try require(source.utf8.count > MonitorWire.maximumFrameBytes && source.contains("\"s\":[0,")
                    && source.contains("\"s\":[8999,"), "independent full traces survive ordinary log rotation and exceed one frame")
        let pager = MonitorDiagnosticPager()
        let collected = try await MonitorDiagnosticPager.collect(id: UUID().uuidString, stream: .boost) { request in
            try pager.page(for: request) { source }
        }
        try require(collected == source, "all trace pages reassemble exactly without applying runtime tail limits")
        let app = try SharedStore(directory: root.appendingPathComponent("app"))
        try app.saveProviderDiagnostics(collected, stream: .boost)
        let offline = try SharedStore(directory: root.appendingPathComponent("app"))
        let export = String(decoding: try offline.exportData(metadata: [:], stream: .boost), as: UTF8.self)
        try require(export.contains(id) && export.contains("\"s\":[0,") && export.contains("\"s\":[8999,"),
                    "local IPC copy remains complete and exportable after VPN shutdown and App restart")
        let shared = String(decoding: try store.exportData(metadata: [:], stream: .boost), as: UTF8.self)
        try require(shared.contains("boost_trace_start") && shared.contains("boost_trace_end"), "App Group export includes the second log module")
    }

    private static func boostTraceRecovery() async throws {
        try withStore { store, root in
            let id = UUID().uuidString
            let record = LogRecord(instanceID: "old", event: "boost_trace_start", fields: ["traceID": id])
            try store.appendBoostTrace(id: id, records: [record], finished: false)
            let path = root.appendingPathComponent("boost-trace-\(id).open.jsonl")
            let handle = try FileHandle(forWritingTo: path)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("{truncated".utf8)); try handle.close()
            try store.recoverBoostTraces(instanceID: "new", at: Date())
            let recovered = try store.boostTraceDiagnostics()
            try require(recovered.contains("process_interrupted") && recovered.contains("\"complete\":\"false\"")
                        && !recovered.contains("truncated"), "restart repairs the torn tail and marks the capture partial")
            let live = UUID().uuidString
            try store.appendBoostTrace(id: live, records: [LogRecord(instanceID: "new", event: "boost_trace_start", fields: ["traceID": live])], finished: false)
            for _ in 0..<10 {
                let completed = UUID().uuidString
                try store.appendBoostTrace(id: completed, records: [
                    LogRecord(instanceID: "new", event: "boost_trace_start", fields: ["traceID": completed]),
                    LogRecord(instanceID: "new", event: "boost_trace_end", fields: ["traceID": completed, "complete": "true"])
                ], finished: true)
            }
            let paths = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("boost-trace-") }
            try require(paths.count == 9 && paths.contains("boost-trace-\(live).open.jsonl"), "retention preserves eight whole completed captures and every active capture")
            for line in try store.boostTraceDiagnostics().split(separator: "\n") {
                _ = try SharedJSON.decoder().decode(LogRecord.self, from: Data(line.utf8))
            }
        }
    }

    private static func boostTraceFailure() async throws {
        let f = try fixture(); f.store.failBoostTrace = true
        try f.runtime.start()
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        try require(f.sampler.interval == 1 / 120 && f.sink.submissions == 1
                    && f.store.savedHistory?.target == .light && f.runtime.snapshot.counters.polls == 1,
                    "diagnostic failure cannot change scoring, retiming, notification or counters")
        try require(f.store.logs.contains { $0.event == "boost_trace_error" }
                    && f.runtime.snapshot.lastError != nil && f.runtime.snapshot.boostTraceIDs?.isEmpty == true,
                    "write failure remains actionable and never claims an active or complete capture")
    }

    private static func boostCompactEncoding() async throws {
        let f = try fixture(); try f.runtime.start()
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        let id = f.runtime.snapshot.boostTraceIDs!.first!
        let trigger = f.clock.now
        for index in 1...140 {
            f.clock.now = trigger.addingTimeInterval(Double(index) / 100)
            f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        }
        f.runtime.flushDiagnostics()
        let records = f.store.boostTraces[id]!
        let samples = records.filter { $0.event == "boost_trace_sample" }
        let oldBytes = try samples.reduce(0) { try $0 + SharedJSON.encoder().encode($1).count }
        let newBytes = try samples.reduce(0) { try $0 + BoostTraceRecorder.encode($1).count }
        try require(newBytes * 3 < oldBytes, "numeric rows remove at least two thirds of repeated sample bytes")
        let encoded = try BoostTraceRecorder.encode(samples.first!)
        let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let row = object["s"] as! [Any]
        try require(row.count == BoostTraceRecorder.sampleColumns.split(separator: ",").count
                    && (row[0] as? NSNumber)?.uint64Value == UInt64(samples.first!.fields["sequence"]!)
                    && (row[3] as? NSNumber)?.doubleValue == Double(samples.first!.fields["brightness"]!)
                    && object["fields"] == nil && object["instanceID"] == nil, "production encoder preserves input numbers and versioned positional columns")
#if os(macOS)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var data = Data()
        for record in records { data.append(try BoostTraceRecorder.encode(record)); data.append(0x0A) }
        let input = directory.appendingPathComponent("boost.jsonl")
        let csv = directory.appendingPathComponent("decoded.csv")
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/decode_boost_trace.py").path,
                             input.path, "--output", csv.path]
        try process.run(); process.waitUntilExit()
        let decoded = try String(contentsOf: csv)
        try require(process.terminationStatus == 0 && decoded.contains("filteredBrightness") && decoded.contains(id)
                    && decoded.split(separator: "\n").count == samples.count + 1 && decoded.contains(",trigger,"),
                    "shipped Python decoder restores every production compact sample and its capture phase: status=\(process.terminationStatus), rows=\(decoded.split(separator: "\n").count), expected=\(samples.count + 1), phase=\(decoded.contains(",trigger,")), id=\(decoded.contains(id)), header=\(decoded.contains("filteredBrightness"))")
#endif
    }

    private static func splitLogMigration() async throws {
        try withStore { store, root in
            let onlyRuntime = String(decoding: try SharedJSON.encoder().encode(LogRecord(instanceID: "first", event: "monitor_ready")), as: UTF8.self) + "\n"
            try store.saveProviderDiagnostics(onlyRuntime)
            try require(try store.providerDiagnostics(stream: .boost) == nil,
                        "a runtime-only cache cannot claim a Boost snapshot was acquired")
            let id = UUID().uuidString
            let rows = [LogRecord(instanceID: "old", event: "monitor_ready"),
                        LogRecord(instanceID: "old", event: "boost_trace_start", fields: ["traceID": id]),
                        LogRecord(instanceID: "old", event: "boost_trace_end", fields: ["traceID": id, "complete": "true"])]
            var old = Data()
            for row in rows { old.append(try SharedJSON.encoder().encode(row)); old.append(0x0A) }
            try old.write(to: root.appendingPathComponent("provider-diagnostics.jsonl"))
            let fresh = String(decoding: try SharedJSON.encoder().encode(LogRecord(instanceID: "new", event: "boost_trace_error", fields: ["detail": "disk failure"])), as: UTF8.self) + "\n"
            try store.saveProviderDiagnostics(fresh)
            do { try store.saveProviderDiagnostics("{partial", stream: .boost); throw ProjectError.message("Expected invalid Boost cache rejection") }
            catch { try require(!(error as NSError).localizedDescription.contains("Expected"), "failed Boost sync preserves migrated data") }
            let offline = try SharedStore(directory: root)
            let runtime = String(decoding: try offline.exportData(metadata: [:]), as: UTF8.self)
            let boost = String(decoding: try offline.exportData(metadata: [:], stream: .boost), as: UTF8.self)
            try require(runtime.contains("boost_trace_error") && !runtime.contains("boost_trace_start")
                        && boost.contains(id) && boost.contains("boost_trace_end") && !boost.contains("disk failure"),
                        "legacy Boost survives a runtime cache replacement and write failure stays in runtime export")
            try offline.saveProviderDiagnostics("", stream: .boost)
            try require(try offline.providerDiagnostics(stream: .boost) == "", "a complete empty Boost snapshot can explicitly replace prior retained data")
        }
    }

    private static func diagnosticSnapshotRelease() async throws {
        let pager = MonitorDiagnosticPager()
        let source = String(decoding: try SharedJSON.encoder().encode(LogRecord(instanceID: "provider", event: "sample", fields: ["text": String(repeating: "x", count: 100_000)])), as: UTF8.self) + "\n"
        let first = UUID().uuidString
        _ = try await MonitorDiagnosticPager.collect(id: first, stream: .boost) { try pager.page(for: $0) { source } }
        try require(pager.retainedSnapshotBytes == source.utf8.count, "finished snapshot remains available for final-page retry")
        let retry = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: first,
                                  exportOffset: source.utf8.count, exportStream: .boost)) { "changed" }
        try require(retry.exportTotalBytes == source.utf8.count, "same export ID retries the immutable final snapshot")
        _ = try await MonitorDiagnosticPager.collect(id: UUID().uuidString) { try pager.page(for: $0) { source } }
        try require(pager.retainedSnapshotBytes == source.utf8.count, "next independent export releases completed bytes instead of accumulating histories")
        let mixed = UUID().uuidString
        _ = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: mixed, exportOffset: 0, exportStream: .boost)) { source }
        do {
            _ = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: mixed, exportOffset: 0, exportStream: .runtime)) { source }
            throw ProjectError.message("Expected stream identity mismatch")
        } catch { try require(!(error as NSError).localizedDescription.contains("Expected"), "one export ID cannot mix runtime and Boost offsets") }
    }

    private static func transportProbe() async throws {
        var sent = Data()
        try await MonitorMessageChannel().probe { data, completion in sent = data; completion(data) }
        try require(sent.starts(with: MonitorWire.probePrefix), "raw probe bypasses reply Codable and runtime readback")
        var refused = false
        do { try await MonitorMessageChannel().probe { _, completion in completion(Data("wrong".utf8)) } }
        catch { refused = true }
        try require(refused, "probe must echo unique payload")
        let payload = Data(repeating: 17, count: 65_536)
        let frame = try MonitorWire.frame(payload)
        try require(try MonitorWire.frameLength(Data(frame.prefix(4))) == payload.count, "multi-byte network length")
        do { _ = try MonitorWire.frameLength(Data([255, 255, 255, 255])); throw ProjectError.message("Expected oversized frame rejection") }
        catch { try require(!(error as NSError).localizedDescription.contains("Expected"), "oversized frames rejected") }
    }

    private static func transportFallback() async throws {
        let router = MonitorTransportRouter()
        var primaryCalls = 0
        var fallbackCalls = 0
        let primary: @MainActor () async throws -> MonitorReply = {
            primaryCalls += 1; throw MonitorChannelError.emptyReply
        }
        let fallback: @MainActor () async throws -> MonitorReply = {
            fallbackCalls += 1; return MonitorReply(success: true, message: "real provider reply")
        }
        _ = try await router.send(primary: primary, fallback: fallback)
        _ = try await router.send(primary: primary, fallback: fallback)
        try require(primaryCalls == 1 && fallbackCalls == 2 && router.usesFallback, "failed system channel is not retried on every log page")
        router.reset()
        var rejected = false
        do {
            _ = try await router.send(primary: { throw ProjectError.message("bad identity or malformed reply") }, fallback: fallback)
        } catch { rejected = true }
        try require(rejected && fallbackCalls == 2, "business/decoding rejection never hidden by fallback")
        var order: [Int] = []
        let first = Task { try await router.send(primary: {
            order.append(1); try await Task.sleep(nanoseconds: 20_000_000); order.append(2)
            return MonitorReply(success: true, message: "first")
        }, fallback: fallback) }
        try await Task.sleep(nanoseconds: 5_000_000)
        let second = Task { try await router.send(primary: {
            order.append(3); order.append(4); return MonitorReply(success: true, message: "second")
        }, fallback: fallback) }
        _ = try await first.value; _ = try await second.value
        try require(order == [1, 2, 3, 4], "status refresh and export cannot overlap session messages")
        let obsolete = Task { try await router.send(primary: {
            try await Task.sleep(nanoseconds: 30_000_000)
            return MonitorReply(success: true, message: "old session")
        }, fallback: fallback) }
        try await Task.sleep(nanoseconds: 5_000_000)
        router.reset()
        var cancelled = false
        do { _ = try await obsolete.value } catch is CancellationError { cancelled = true }
        try require(cancelled && !router.usesFallback, "new VPN session cannot accept obsolete jobs")
    }

    private static func diagnosticPagination() async throws {
        let pager = MonitorDiagnosticPager()
        let id = UUID().uuidString
        let record = LogRecord(instanceID: "provider", event: "sample", fields: ["text": String(repeating: "日志😀", count: 10000)])
        let logs = String(decoding: try SharedJSON.encoder().encode(record), as: UTF8.self) + "\n"
        var loads = 0
        let collected = try await MonitorDiagnosticPager.collect(id: id) { request in
            try pager.page(for: request) { loads += 1; return logs }
        }
        try require(collected == logs && loads == 1, "one stable snapshot with UTF8-safe byte reassembly")
        let activeID = UUID().uuidString
        _ = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: activeID, exportOffset: 0)) { logs }
        let otherID = UUID().uuidString
        _ = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: otherID, exportOffset: 0)) { logs }
        let resumed = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: activeID, exportOffset: MonitorWire.diagnosticPageBytes)) { "changed" }
        try require(resumed.exportID == activeID && resumed.exportTotalBytes == logs.utf8.count,
                    "manual export and automatic sync cannot replace each other's active snapshot")
        var refused = false
        do {
            _ = try await MonitorDiagnosticPager.collect(id: UUID().uuidString) { request in
                MonitorReply(success: true, message: "bad", diagnosticPage: Data(), exportID: request.exportID,
                             exportNextOffset: 0, exportTotalBytes: 100)
            }
        } catch { refused = true }
        try require(refused, "non-advancing or truncated pages cannot produce a complete export")
        let unknown = MonitorRequest(command: .exportDiagnosticPage, exportID: UUID().uuidString, exportOffset: 4096)
        do { _ = try pager.page(for: unknown) { logs }; throw ProjectError.message("Expected expired snapshot error") }
        catch { try require(!(error as NSError).localizedDescription.contains("Expected"), "expired export cannot silently mix log snapshots") }
    }

    private static func providerLogCache() async throws {
        try withStore { store, root in
            let logs = String(decoding: try SharedJSON.encoder().encode(LogRecord(instanceID: "provider", event: "monitor_ready")), as: UTF8.self) + "\n"
            try store.saveProviderDiagnostics(logs)
            let reopened = try SharedStore(directory: root)
            try require(try reopened.providerDiagnostics() == logs, "provider results remain after app restart or VPN shutdown")
            let exported = String(decoding: try reopened.exportData(metadata: [:]), as: UTF8.self)
            try require(exported.contains("provider_logs_cache_export") && exported.contains("monitor_ready"),
                        "offline JSONL export contains the actual provider records")
            do { try reopened.saveProviderDiagnostics("{incomplete"); throw ProjectError.message("Expected malformed cache rejection") }
            catch { try require(!(error as NSError).localizedDescription.contains("Expected"), "partial reply never overwrites complete cache") }
            try require(try reopened.providerDiagnostics() == logs, "failed update preserves previous complete logs")
        }
    }

    private static func loopbackExportChain() async throws {
        let f = try fixture()
        try f.runtime.start()
        let credentials = MonitorBridgeCredentials()
        let identity = RuntimeIdentity(storageMode: RuntimeStorageMode.localIPC.rawValue,
                                       bundleIdentifier: "test", buildVersion: "9", appGroupIdentifier: "test")
        let pager = MonitorDiagnosticPager()
        let endpoint = MonitorControlEndpoint(identity: identity, runtime: { f.runtime }, diagnostics: {
            f.runtime.flushDiagnostics()
            var data = Data()
            for record in f.store.logs {
                data.append(try SharedJSON.encoder().encode(record)); data.append(0x0A)
            }
            return String(decoding: data, as: UTF8.self)
        }, configurationStore: f.store, pager: pager, boostDiagnostics: {
            f.runtime.flushDiagnostics()
            var data = Data()
            for id in f.store.boostTraces.keys.sorted() {
                for record in f.store.boostTraces[id]! {
                    data.append(try BoostTraceRecorder.encode(record)); data.append(0x0A)
                }
            }
            return String(decoding: data, as: UTF8.self)
        })
        var ready = false
        var listenerError: String?
        let server = LoopbackMonitorServer(credentials: credentials, handle: { endpoint.handle($0) }, record: { event, fields in
            if event == "loopback_listener_ready" { ready = true }
            if event == "loopback_listener_failed" { listenerError = fields["error"] }
        })
        defer { server.stop() }
        try server.start()
        for _ in 0..<100 where !ready && listenerError == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(ready, "actual loopback listener starts: \(listenerError ?? "timeout")")
        let client = LoopbackMonitorClient()
        let configuration = MonitorConfiguration(revision: UUID().uuidString, cooldown: 2)
        let applyData = try await client.send(SharedJSON.encoder().encode(MonitorRequest(command: .reloadConfiguration,
                                     expectedRevision: configuration.revision, configuration: configuration)), credentials: credentials)
        let applied = try SharedJSON.decoder().decode(MonitorReply.self, from: applyData)
        try require(applied.success && applied.identity == identity && applied.appliedRevision == configuration.revision
                    && f.sampler.interval == 1, "actual TCP applies ordinary configuration to the real runtime")
        for _ in 1...100 {
            f.clock.advance(2)
            f.sampler.emit(0.24, at: f.clock.now, uptime: f.clock.uptime)
        }
        let statusData = try await client.send(SharedJSON.encoder().encode(MonitorRequest(command: .queryStatus)), credentials: credentials)
        let status = try SharedJSON.decoder().decode(MonitorReply.self, from: statusData)
        try require(status.success && status.snapshot?.counters.polls == 100 && status.snapshot?.sample?.sequence == 101,
                    "query over TCP returns actual sampling counters without creating a heartbeat")
        f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        let traceID = f.runtime.snapshot.boostTraceIDs!.first!
        let trigger = f.clock.now
        for index in 1...140 {
            f.clock.now = trigger.addingTimeInterval(Double(index) / 100)
            f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime)
        }
        for _ in 1...3 { f.clock.advance(1); f.sampler.emit(0.44, at: f.clock.now, uptime: f.clock.uptime) }
        let logs = try await MonitorDiagnosticPager.collect(id: UUID().uuidString) { request in
            let data = try await client.send(SharedJSON.encoder().encode(request), credentials: credentials)
            return try SharedJSON.decoder().decode(MonitorReply.self, from: data)
        }
        try require(logs.utf8.count > 4096 && logs.contains("sample") && logs.contains(configuration.revision)
                    && logs.contains("\"sequence\":\"101\""), "actual TCP transfers all pages of ordinary monitoring logs")
        let boost = try await MonitorDiagnosticPager.collect(id: UUID().uuidString, stream: .boost) { request in
            let data = try await client.send(SharedJSON.encoder().encode(request), credentials: credentials)
            return try SharedJSON.decoder().decode(MonitorReply.self, from: data)
        }
        try require(!logs.contains("boost_trace_start") && boost.contains(traceID) && boost.contains("boost_trace_start")
                    && boost.contains("boost_trace_end") && boost.contains("\"complete\":\"true\"") && boost.contains("\"s\":["),
                    "actual TCP independently carries compact Boost inputs from prelude to stable completion")
        try withStore { store, root in
            try store.saveProviderDiagnostics(logs)
            try store.saveProviderDiagnostics(boost, stream: .boost)
            server.stop()
            let offline = try SharedStore(directory: root)
            try require(try offline.providerDiagnostics() == logs && offline.providerDiagnostics(stream: .boost) == boost,
                        "both independent provider snapshots survive shutdown and App restart")
            let runtimeExport = try offline.exportData(metadata: [:])
            let boostExport = try offline.exportData(metadata: [:], stream: .boost)
            let exported = String(decoding: runtimeExport, as: UTF8.self)
            let traceExported = String(decoding: boostExport, as: UTF8.self)
            try require(exported.contains("provider_logs_cache_export") && exported.contains(configuration.revision)
                        && exported.contains("\"sequence\":\"101\"") && !exported.contains("boost_trace_start")
                        && traceExported.contains(traceID) && traceExported.contains("boost_trace_end")
                        && !traceExported.contains("notification_submit"), "two offline exports have independent contents")
            let urls = try SharedStore.writeExports([.runtime: runtimeExport, .boost: boostExport])
            try require(urls.count == 2 && urls[0].lastPathComponent.contains("runtime") && urls[1].lastPathComponent.contains("boost")
                        && (try Data(contentsOf: urls[0])) == runtimeExport && (try Data(contentsOf: urls[1])) == boostExport,
                        "the share sheet receives two real independent JSONL files")
        }
        // Restart listener to check that a token from another profile cannot invoke controls.
        ready = false
        try server.start()
        for _ in 0..<100 where !ready { try await Task.sleep(nanoseconds: 10_000_000) }
        let wrong = MonitorBridgeCredentials(port: credentials.port, token: String(repeating: "x", count: 72))
        var rejected = false
        do { _ = try await client.send(SharedJSON.encoder().encode(MonitorRequest(command: .queryStatus)), credentials: wrong) }
        catch { rejected = true }
        try require(rejected, "wrong per-profile authentication token is rejected")
    }

}

@MainActor private final class FakeKeepAlive: KeepAliveService {
    let name = "Test"
    var state = KeepAliveState()
    var onStateChange: ((KeepAliveState) -> Void)?
    var starts = 0
    var stops = 0
    var startError: Error?
    var deferStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    func updateState() {}
    func refresh() async throws {}
    func prepare() async throws {}
    func start() async throws {
        starts += 1
        if let startError { throw startError }
        if deferStart { await withCheckedContinuation { pendingStart = $0 } }
        state.phase = .starting
    }
    func finishStart() { pendingStart?.resume(); pendingStart = nil }
    func stop() { stops += 1; state.phase = .stopping }
}

private struct Fixture {
    let store: MemoryStore
    let sampler: FakeSampler
    let sink: FakeNotifications
    let clock: TestClock
    let runtime: SwitchMonitor
}
private final class MemoryStore: MonitorStore {
    var config = MonitorConfiguration()
    var savedSnapshot: RuntimeSnapshot?
    var savedHistory: SubmissionHistory?
    var failSnapshot = false
    var snapshotWrites = 0
    var logs: [LogRecord] = []
    var boostTraces: [String: [LogRecord]] = [:]
    var failBoostTrace = false
    func configuration() throws -> MonitorConfiguration { config }
    func saveConfiguration(_ value: MonitorConfiguration) throws { config = value }
    func snapshot() throws -> RuntimeSnapshot? { savedSnapshot }
    func saveSnapshot(_ value: RuntimeSnapshot) throws {
        if failSnapshot { throw ProjectError.message("Simulated disk error") }
        savedSnapshot = value
        snapshotWrites += 1
    }
    func history() throws -> SubmissionHistory? { savedHistory }
    func saveHistory(_ value: SubmissionHistory) throws { savedHistory = value }
    func append(_ record: LogRecord) throws { logs.append(record) }
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {
        if failBoostTrace { throw ProjectError.message("Simulated trace disk error") }
        boostTraces[id, default: []].append(contentsOf: records)
    }
    func recoverBoostTraces(instanceID: String, at: Date) throws {}

}
@MainActor private final class FakeSampler: BrightnessSampling {
    var receive: ((BrightnessReading) -> Void)?
    var starts = 0
    var retimes = 0
    var interval: Double = 0
    var value = 0.24
    var active = false
    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        starts += 1; active = true; self.interval = interval; self.receive = receive
    }
    func updateInterval(_ interval: TimeInterval) { retimes += 1; self.interval = interval }
    func sampleNow(_ source: SampleSource) {
        receive?(BrightnessReading(value: value, source: source, timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
    }
    func stop() { active = false; receive = nil }
    func emit(_ value: Double, at date: Date, uptime: TimeInterval? = nil) {
        receive?(BrightnessReading(value: value, source: .poll, timestamp: date, uptime: uptime))
    }
}
@MainActor private final class FakeNotifications: ModeNotificationSubmitting {
    var allowed = true
    var deferAuthorization = false
    var deferSubmission = false
    var submissions = 0
    var authorizationCalls = 0
    var lastCandidate: NotificationCandidate?
    var lastSource: SampleSource?
    var authorizationCallback: ((Bool, String) -> Void)?
    var submissionCallback: ((Error?) -> Void)?
    func authorization(_ completion: @escaping (Bool, String) -> Void) {
        authorizationCalls += 1
        if deferAuthorization { authorizationCallback = completion }
        else { completion(allowed, "test") }
    }
    func submit(_ candidate: NotificationCandidate, source: SampleSource, completion: @escaping (Error?) -> Void) {
        submissions += 1
        lastCandidate = candidate
        lastSource = source
        if deferSubmission { submissionCallback = completion }
        else { completion(nil) }
    }
    func completeAuthorization(_ allowed: Bool) {
        let callback = authorizationCallback; authorizationCallback = nil; callback?(allowed, "test")
    }
    func completeSubmission(_ error: Error?) {
        let callback = submissionCallback; submissionCallback = nil; callback?(error)
    }
}
@MainActor private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var uptime: TimeInterval { now.timeIntervalSince1970 - 1_700_000_000 }
    func advance(_ seconds: Double) { now.addTimeInterval(seconds) }
}
