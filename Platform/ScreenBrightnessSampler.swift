import Foundation
import UIKit

/// The legacy foreground scheduler remains the default for extension callers. The App
/// composition root can inject DispatchPollingScheduler for background PiP operation.
@MainActor final class MainRunLoopPollingScheduler: PollingScheduler {
    typealias Record = @Sendable (String, [String: String]) -> Void
    typealias Context = @MainActor () -> [String: String]

    private let record: Record
    private let context: Context
    private var timer: Timer?
    private var generation = UUID()
    private var tickCount: UInt64 = 0
    private var lastDiagnosticUptime: TimeInterval = -.infinity

    init(record: @escaping Record = { _, _ in }, context: @escaping Context = { [:] }) {
        self.record = record
        self.context = context
    }

    deinit {
        timer?.invalidate()
    }

    func start(interval: TimeInterval, tick: @escaping @MainActor () -> Void) {
        stop()
        let token = UUID()
        generation = token
        tickCount = 0
        lastDiagnosticUptime = -.infinity
        let interval = min(3_600, max(0.001, interval.isFinite ? interval : 1))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.timer != nil else { return }
                self.tickCount &+= 1
                let uptime = ProcessInfo.processInfo.systemUptime
                if uptime - self.lastDiagnosticUptime >= 1 {
                    self.lastDiagnosticUptime = uptime
                    self.record("poll_tick", self.context().merging([
                        "host": "app", "backend": "main_run_loop", "interval": String(interval),
                        "tickUptime": String(uptime), "generation": token.uuidString,
                        "count": String(self.tickCount)
                    ]) { _, new in new })
                }
                tick()
            }
        }
        timer.tolerance = 0
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        record("poll_scheduler_started", context().merging([
            "backend": "main_run_loop", "interval": String(interval), "generation": token.uuidString
        ]) { _, new in new })
    }

    func stop() {
        guard let timer else { return }
        self.timer = nil
        let stoppedGeneration = generation
        generation = UUID()
        timer.invalidate()
        record("poll_scheduler_stopped", context().merging([
            "backend": "main_run_loop", "generation": stoppedGeneration.uuidString
        ]) { _, new in new })
    }
}

/// Owns UIKit and sampling only. Scheduling is injectable and brightness is always read
/// on MainActor, even when DispatchPollingScheduler performs its wait on a worker queue.
@MainActor final class ScreenBrightnessSampler: BrightnessSampling {
    typealias Record = @Sendable (String, [String: String]) -> Void
    typealias Context = @MainActor () -> [String: String]

    private let scheduler: any PollingScheduler
    private let record: Record
    private let context: Context
    private var observer: NSObjectProtocol?
    private var generation = UUID()
    private var receive: ((BrightnessReading) -> Void)?
    private var sampleCount: UInt64 = 0
    private var lastSampleDiagnosticUptime: TimeInterval = -.infinity

    init(scheduler: (any PollingScheduler)? = nil,
         record: @escaping Record = { _, _ in },
         context: @escaping Context = { [:] }) {
        self.record = record
        self.context = context
        self.scheduler = scheduler ?? MainRunLoopPollingScheduler(record: record, context: context)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        stop()
        self.receive = receive
        sampleCount = 0
        lastSampleDiagnosticUptime = -.infinity
        let token = generation
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.sampleNow(.event)
            }
        }
        installPolling(interval: interval, token: token)
    }

    func updateInterval(_ interval: TimeInterval) {
        guard receive != nil else { return }
        installPolling(interval: interval, token: generation)
    }

    func sampleNow(_ source: SampleSource) {
        guard let receive else { return }
        // UIScreen is main-thread-bound. Keep both the API read and callback on MainActor.
        let uptime = ProcessInfo.processInfo.systemUptime
        let timestamp = Date()
        let value = Double(UIScreen.main.brightness)
        receive(BrightnessReading(value: value, source: source, timestamp: timestamp, uptime: uptime))
        sampleCount &+= 1
        if uptime - lastSampleDiagnosticUptime >= 1 {
            lastSampleDiagnosticUptime = uptime
            record("brightness_sample", context().merging([
                "source": source.rawValue, "brightness": String(value),
                "sampleAt": timestamp.ISO8601Format(), "sampleUptime": String(uptime),
                "count": String(sampleCount)
            ]) { _, new in new })
        }
    }

    func stop() {
        generation = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        scheduler.stop()
        receive = nil
    }

    private func installPolling(interval: TimeInterval, token: UUID) {
        scheduler.start(interval: interval) { [weak self] in
            guard let self, self.generation == token, self.receive != nil else { return }
            self.sampleNow(.poll)
        }
    }
}
