import Foundation
import UIKit

/// Owns UIKit and scheduling only. No VPN, scoring policy, notification, or storage.
@MainActor final class ScreenBrightnessSampler: BrightnessSampling {
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    private var generation = UUID()
    private var timerGeneration = UUID()
    private var receive: ((BrightnessReading) -> Void)?

    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        stop()
        self.receive = receive
        let token = generation
        observer = NotificationCenter.default.addObserver(
            forName: UIScreen.brightnessDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.sampleNow(.event)
            }
        }
        updateInterval(interval)
    }

    func updateInterval(_ interval: TimeInterval) {
        timer?.invalidate()
        timerGeneration = UUID()
        let token = timerGeneration
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            // The timer is installed exclusively on the main run loop. Avoid a queued Task per read.
            MainActor.assumeIsolated {
                guard let self, self.timerGeneration == token, self.receive != nil else { return }
                self.sampleNow(.poll)
            }
        }
        timer.tolerance = 0
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func sampleNow(_ source: SampleSource) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let value = Double(UIScreen.main.brightness)
        receive?(BrightnessReading(value: value, source: source, timestamp: Date(),
                                   uptime: uptime))
    }

    func stop() {
        generation = UUID()
        timerGeneration = UUID()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.invalidate()
        timer = nil
        receive = nil
    }
}
