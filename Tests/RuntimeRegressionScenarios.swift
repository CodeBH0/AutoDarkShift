import Foundation
#if SWIFT_PACKAGE
@testable import AutoDarkShiftCore
#endif

/// Shared by XCTest and the standalone runner: both exercise the actual production files.
@MainActor enum RuntimeRegressionScenarios {
    static var cases: [(String, () async throws -> Void)] { [
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
        ("sampling gaps clear trend before evaluating new brightness", samplingGap),
        ("retired wire commands are rejected without changing sampling", retiredCommands),
        ("historic test records remain exportable without mutation", legacyDiagnosticRetention),
        ("raw provider probe does not depend on JSON or runtime state", transportProbe),
        ("transport fallback is sticky serialized and rejects bad replies", transportFallback),
        ("diagnostic pagination preserves snapshot and UTF8 boundaries", diagnosticPagination),
        ("provider log cache survives restart and rejects incomplete data", providerLogCache),
        ("real loopback transports ordinary monitoring logs into offline export cache", loopbackExportChain)
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
        machine.complete(dark, succeeded: true, at: t.addingTimeInterval(1))
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
        for index in 1...240 {
            let elapsed = Double(index) / 120
            f.clock.now = Date(timeIntervalSince1970: 1_700_000_001 + elapsed)
            f.sampler.emit(0.20 - min(elapsed, 0.9) * 0.12, at: f.clock.now, uptime: f.clock.uptime)
        }
        try require(f.sampler.starts == 1 && f.sampler.retimes >= 4 && f.sampler.interval == 1,
                    "dynamic rate changes preserve observer and return to 1 Hz")
        try require(f.runtime.snapshot.counters.polls == 241, "every high-rate read is evaluated")
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
        try require(f.sampler.starts == 1 && f.sampler.retimes == 2 && f.sampler.interval == 1.0 / 30,
                    "retiming does not replace observation generation")
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
        let record = LogRecord(instanceID: "provider", event: "sample", fields: ["text": String(repeating: "日志😀", count: 1000)])
        let logs = String(decoding: try SharedJSON.encoder().encode(record), as: UTF8.self) + "\n"
        var loads = 0
        let collected = try await MonitorDiagnosticPager.collect(id: id) { request in
            try pager.page(for: request) { loads += 1; return logs }
        }
        try require(collected == logs && loads == 1, "one stable snapshot with UTF8-safe byte reassembly")
        let otherID = UUID().uuidString
        _ = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: otherID, exportOffset: 0)) { logs }
        let resumed = try pager.page(for: MonitorRequest(command: .exportDiagnosticPage, exportID: id, exportOffset: 4096)) { "changed" }
        try require(resumed.exportID == id && resumed.exportTotalBytes == logs.utf8.count,
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
            var data = Data()
            for record in f.store.logs {
                data.append(try SharedJSON.encoder().encode(record)); data.append(0x0A)
            }
            return String(decoding: data, as: UTF8.self)
        }, configurationStore: f.store, pager: pager)
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
        let logs = try await MonitorDiagnosticPager.collect(id: UUID().uuidString) { request in
            let data = try await client.send(SharedJSON.encoder().encode(request), credentials: credentials)
            return try SharedJSON.decoder().decode(MonitorReply.self, from: data)
        }
        try require(logs.utf8.count > 4096 && logs.contains("sample") && logs.contains(configuration.revision)
                    && logs.contains("\"sequence\":\"101\""), "actual TCP transfers all pages of ordinary monitoring logs")
        try withStore { store, root in
            try store.saveProviderDiagnostics(logs)
            server.stop()
            let offline = try SharedStore(directory: root)
            try require(try offline.providerDiagnostics() == logs, "ordinary records remain available without a live provider")
            let exported = String(decoding: try offline.exportData(metadata: [:]), as: UTF8.self)
            try require(exported.contains("provider_logs_cache_export") && exported.contains(configuration.revision)
                        && exported.contains("\"sequence\":\"101\""), "ordinary transport output reaches the final offline export format")
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
    var authorizationCallback: ((Bool, String) -> Void)?
    var submissionCallback: ((Error?) -> Void)?
    func authorization(_ completion: @escaping (Bool, String) -> Void) {
        if deferAuthorization { authorizationCallback = completion }
        else { completion(allowed, "test") }
    }
    func submit(_ candidate: NotificationCandidate, source: SampleSource, completion: @escaping (Error?) -> Void) {
        submissions += 1
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
