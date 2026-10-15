import Foundation

/// Polls only the BackBoard getter. There is no fallback reader or brightness observer.
@MainActor final class BackBoardBrightnessSampler: BrightnessSampling {
    private let scheduler: any PollingScheduler
    private let read: () -> Float?
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    private let record: (String, [String: String]) -> Void
    private let context: () -> [String: String]
    private var receive: ((BrightnessReading) -> Void)?
    private var generation = UUID()
    private var readCount: UInt64 = 0
    private var lastDiagnosticUptime: TimeInterval = -.infinity

    init(scheduler: any PollingScheduler,
         read: @escaping () -> Float? = BackBoardBrightnessProbe.read,
         clock: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         record: @escaping (String, [String: String]) -> Void = { _, _ in },
         context: @escaping () -> [String: String] = { [:] }) {
        self.scheduler = scheduler
        self.read = read
        self.clock = clock
        self.uptime = uptime
        self.record = record
        self.context = context
    }

    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        stop()
        self.receive = receive
        readCount = 0
        lastDiagnosticUptime = -.infinity
        record("backboard_sampler_started", fields(["interval": String(interval), "observer": "none"]))
        installPolling(interval)
    }

    func updateInterval(_ interval: TimeInterval) {
        guard receive != nil else { return }
        generation = UUID()
        installPolling(interval)
    }

    func sampleNow(_ source: SampleSource) {
        guard let receive, source != .event else { return }
        let timestamp = clock()
        let uptime = self.uptime()
        let result = read()
        readCount &+= 1
        if uptime - lastDiagnosticUptime >= 1 || source == .initial || source == .wake {
            lastDiagnosticUptime = uptime
            let value = result.map(Double.init)
            record(result == nil ? "backboard_read_unavailable" : "backboard_brightness_sample", fields([
                "source": source.rawValue, "brightness": value.map { String($0) } ?? "unavailable",
                "valid": String(value.map { $0.isFinite && (0...1).contains($0) } ?? false),
                "sampleAt": timestamp.ISO8601Format(), "sampleUptime": String(uptime),
                "readCount": String(readCount)
            ]))
        }
        guard let result else { return }
        // Preserve NaN/out-of-range values for the existing invalid-input handling.
        receive(BrightnessReading(value: Double(result), source: source, timestamp: timestamp, uptime: uptime))
    }

    func stop() {
        generation = UUID()
        scheduler.stop()
        if receive != nil { record("backboard_sampler_stopped", fields([:])) }
        receive = nil
    }

    private func installPolling(_ interval: TimeInterval) {
        let token = generation
        scheduler.start(interval: interval) { [weak self] in
            guard let self, self.generation == token, self.receive != nil else { return }
            self.sampleNow(.poll)
        }
    }

    private func fields(_ extra: [String: String]) -> [String: String] {
        context().merging(["business": "backboard", "api": BackBoardBrightnessProbe.symbol,
                           "samplingMode": "backboard_poll_only", "samplerGeneration": generation.uuidString]) { _, new in new }
            .merging(extra) { _, new in new }
    }
}
