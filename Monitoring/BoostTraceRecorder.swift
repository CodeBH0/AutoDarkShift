import Foundation

/// Adapted from the archived Boost experiment's independent result logging.
/// Observes production sampling only; it never requests a rate or changes notification policy.
@MainActor final class BoostTraceRecorder {
    static let preludeDuration: TimeInterval = 5
    static let stableDuration: TimeInterval = 2
    static let stableRange = BrightnessTrendModel.noiseFloor
    nonisolated static let sampleColumns = BoostTraceEncoding.sampleColumns
    nonisolated static func encode(_ record: LogRecord) throws -> Data { try BoostTraceEncoding.encode(record) }

    private struct Observation {
        var time: TimeInterval
        var value: Double
        var record: LogRecord
    }
    private struct Capture {
        var id: String
        var startedAt: TimeInterval
        var lastFlush: TimeInterval
        var observations: [Observation] = []
        var buffer: [LogRecord] = []
        var samples = 0
        var polls = 0
        var lastState: [String: String]?
    }
    private let store: any MonitorStore
    private let instanceID: String
    private let failed: (String) -> Void
    private var prelude: [Observation] = []
    private var captures: [Capture] = []
    var activeIDs: [String] { captures.map(\.id) }

    init(store: any MonitorStore, instanceID: String, failed: @escaping (String) -> Void) {
        self.store = store
        self.instanceID = instanceID
        self.failed = failed
    }

    func consume(_ reading: BrightnessReading, sample: SampleSnapshot, uptime: TimeInterval,
                 previousInterval: TimeInterval, nextInterval: TimeInterval, pollInterval: TimeInterval?,
                 trend: BrightnessTrendSnapshot?, enteredBoost: Bool,
                 configuration: MonitorConfiguration, desired: DisplayMode?, pending: DisplayMode?,
                 candidate: NotificationCandidate?, inFlight: NotificationCandidate?) {
        guard MonitorConfiguration.validBrightness(reading.value), uptime.isFinite else {
            interrupt(reason: "invalid_sample", at: reading.timestamp)
            return
        }
        var fields: [String: String] = [
            "brightness": String(reading.value),
            "source": reading.source.rawValue, "sequence": String(sample.sequence),
            "uptime": String(uptime), "actualInterval": sample.actualInterval.map { String($0) } ?? "none",
            "pollInterval": pollInterval.map { String($0) } ?? "none",
            "requestedFrequency": String(1 / previousInterval), "nextFrequency": String(1 / nextInterval),
            "desiredTarget": desired?.rawValue ?? "none", "pendingTarget": pending?.rawValue ?? "none",
            "candidateID": candidate?.id.uuidString ?? "none", "inFlightID": inFlight?.id.uuidString ?? "none"
        ]
        if let trend {
            fields.merge(["A": String(trend.position), "delta": String(trend.change), "V": String(trend.speed),
                "S": String(trend.score), "velocity": String(trend.velocity),
                "baseline": trend.baseline.map { String($0) } ?? "none",
                "filteredBrightness": trend.filteredBrightness.map { String($0) } ?? "none",
                "dynamicSampling": String(trend.dynamicSampling),
                "quietDuration": String(trend.quietDuration)]) { _, new in new }
        }
        let observation = Observation(time: uptime, value: reading.value,
            record: LogRecord(timestamp: reading.timestamp, instanceID: instanceID, event: "boost_trace_sample", fields: fields))
        prelude.removeAll { uptime - $0.time > Self.preludeDuration }

        // A later Boost before stability gets its own overlapping capture, rather than truncating the first.
        var remaining: [Capture] = []
        for var capture in captures {
            add(observation, phase: "tracking", to: &capture)
            let cutoff = uptime - Self.stableDuration
            while capture.observations.count > 2, capture.observations[1].time <= cutoff {
                capture.observations.removeFirst()
            }
            let range = (capture.observations.map(\.value).max() ?? reading.value)
                - (capture.observations.map(\.value).min() ?? reading.value)
            let stable = reading.source == .poll && capture.observations.first.map {
                $0.time <= cutoff + 1e-9 && range <= Self.stableRange + 1e-9
            } == true
            if stable {
                capture.buffer.append(end(capture, at: reading.timestamp, reason: "brightness_stable", complete: true,
                    fields: ["duration": String(uptime - capture.startedAt), "observedStableRange": String(range)]))
                _ = write(&capture, finished: true)
            } else if capture.buffer.count >= 256 || uptime - capture.lastFlush >= 1 {
                if write(&capture, finished: false) { capture.lastFlush = uptime; remaining.append(capture) }
            } else { remaining.append(capture) }
        }
        captures = remaining

        if enteredBoost {
            let id = UUID().uuidString
            var capture = Capture(id: id, startedAt: uptime, lastFlush: uptime)
            capture.buffer.append(LogRecord(timestamp: reading.timestamp, instanceID: instanceID, event: "boost_trace_start", fields: [
                "traceID": id, "triggerSequence": String(sample.sequence), "triggerUptime": String(uptime),
                "preludeSeconds": String(Self.preludeDuration), "preludeSamples": String(prelude.count),
                "stableSeconds": String(Self.stableDuration), "stableRange": String(Self.stableRange),
                "completionCriterion": "poll_observed_brightness_range", "revision": configuration.revision,
                "schema": "boost-trace-v2", "model": "brightness-trend-v2", "cooldown": String(configuration.cooldown),
                "sampleColumns": Self.sampleColumns,
                "sourceCodes": "0=initial,1=poll,2=event,3=wake", "targetCodes": "0=none,1=dark,2=light",
                "stateFields": "d=desiredTarget,p=pendingTarget,c=candidateID,f=inFlightID",
                "statePolicy": "first_sample_then_on_change",
                "velocityWindow": String(BrightnessTrendModel.velocityWindow),
                "noiseFloor": String(BrightnessTrendModel.noiseFloor),
                "triggerVelocity": String(BrightnessTrendModel.triggerVelocity),
                "exitVelocity": String(BrightnessTrendModel.exitVelocity), "exitDuration": String(BrightnessTrendModel.exitDuration),
                "frequencyBands": "1,10,30,60,120", "bandBoundaries": "0.015,0.03,0.06,0.10"
            ].merging(BrightnessTrendModel.metadata) { _, new in new }))
            for entry in prelude { add(entry, phase: "preboost", to: &capture, stability: false) }
            add(observation, phase: "trigger", to: &capture)
            if write(&capture, finished: false) { captures.append(capture) }
        }
        // A retrigger needs the preceding velocity window even when it came from an earlier dynamic leg.
        prelude.append(observation)
    }

    private func add(_ observation: Observation, phase: String, to capture: inout Capture, stability: Bool = true) {
        var record = observation.record
        record.fields["traceID"] = capture.id
        record.fields["phase"] = phase
        let state = record.fields.filter { ["desiredTarget", "pendingTarget", "candidateID", "inFlightID"].contains($0.key) }
        if capture.lastState != state { record.fields["stateChanged"] = "true"; capture.lastState = state }
        capture.buffer.append(record)
        capture.samples += 1
        if record.fields["source"] == SampleSource.poll.rawValue { capture.polls += 1 }
        if stability { capture.observations.append(observation) }
    }

    private func end(_ capture: Capture, at date: Date, reason: String, complete: Bool,
                     fields: [String: String] = [:]) -> LogRecord {
        LogRecord(timestamp: date, instanceID: instanceID, event: "boost_trace_end", fields: fields.merging([
            "traceID": capture.id, "reason": reason, "complete": String(complete),
            "samples": String(capture.samples), "polls": String(capture.polls)
        ]) { _, new in new })
    }

    private func write(_ capture: inout Capture, finished: Bool) -> Bool {
        do {
            try store.appendBoostTrace(id: capture.id, records: capture.buffer, finished: finished)
            capture.buffer.removeAll(keepingCapacity: true)
            return true
        } catch { failed("traceID=\(capture.id); \(describeError(error))"); return false }
    }

    func flush() {
        captures = captures.compactMap { capture in
            var copy = capture
            return write(&copy, finished: false) ? copy : nil
        }
    }

    func interrupt(reason: String, at date: Date) {
        for var capture in captures {
            capture.buffer.append(end(capture, at: date, reason: reason, complete: false))
            _ = write(&capture, finished: true)
        }
        captures.removeAll()
        prelude.removeAll()
    }
}
