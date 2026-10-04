import Foundation
import UIKit

/// A separate, typed-message-only input. Requires an iOS 26 SDK at build time.
/// No polling timer or legacy NotificationCenter observer is installed here.
@available(iOS 26.0, *)
@MainActor final class ScreenBrightnessMessageSampler: BrightnessSampling {
    private let screen: UIScreen
    private let center: NotificationCenter
    private let record: (String, [String: String]) -> Void
    private let context: () -> [String: String]
    private var observer: NotificationCenter.ObservationToken?
    private var receive: ((BrightnessReading) -> Void)?
    private var generation = UUID()

    init(screen: UIScreen, center: NotificationCenter = .default,
         record: @escaping (String, [String: String]) -> Void = { _, _ in },
         context: @escaping () -> [String: String] = { [:] }) {
        self.screen = screen
        self.center = center
        self.record = record
        self.context = context
    }

    func start(interval: TimeInterval, receive: @escaping (BrightnessReading) -> Void) {
        stop()
        self.receive = receive
        let token = generation
        observer = center.addObserver(of: nil, for: UIScreen.BrightnessDidChangeMessage.self) { [weak self] message in
            guard let self, self.generation == token, message.screen === self.screen else { return }
            // The typed message contains the screen, not a captured brightness value.
            self.deliver(Double(message.screen.brightness), source: .event)
        }
        record("brightness_message_observer_started", context().merging([
            "business": "message", "api": "UIScreen.BrightnessDidChangeMessage", "polling": "false"
        ]) { _, new in new })
    }

    // The reused model can recommend frequencies, but this input never starts a timer.
    func updateInterval(_ interval: TimeInterval) {}

    func sampleNow(_ source: SampleSource) {
        guard source == .initial || source == .wake else { return }
        // Registration does not replay an initial message. Seed a fresh model baseline.
        deliver(Double(screen.brightness), source: source)
    }

    func stop() {
        generation = UUID()
        receive = nil
        if let observer {
            center.removeObserver(observer)
            record("brightness_message_observer_stopped", context().merging([
                "business": "message"
            ]) { _, new in new })
        }
        observer = nil
    }

    private func deliver(_ value: Double, source: SampleSource) {
        guard let receive else { return }
        receive(BrightnessReading(value: value, source: source, timestamp: Date(),
                                  uptime: ProcessInfo.processInfo.systemUptime))
    }
}
