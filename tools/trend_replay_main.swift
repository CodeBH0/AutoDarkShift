import Foundation

private struct ReplayInput: Decodable {
    var instanceID: String
    var sequence: UInt64
    var timestamp: Double
    var uptime: Double
    var brightness: Double
    var source: String
    var recordedModelVersion: Int?
    var recordedScore: Double?
    var recordedBaseline: Double?
    var recordedVelocity: Double?
    var recordedFilteredBrightness: Double?
    var recordedFrequency: Double?
}

private struct ReplayOutput: Encodable {
    var instanceID: String
    var sequence: UInt64
    var timestamp: Double
    var uptime: Double
    var brightness: Double
    var reset: String?
    var trend: BrightnessTrendSnapshot?
    var frequency: Double
    var candidate: String?
    var recordedScore: Double?
    var recordedBaseline: Double?
    var recordedFrequency: Double?
    var recordedStateScoreError: Double?
}

/// Replay the visible observations through the production policy; no formula is copied here.
@main private enum TrendReplay {
    static func main() throws {
        let input = try JSONDecoder().decode([ReplayInput].self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        var machine = try BrightnessTrendStateMachine(configuration: MonitorConfiguration(cooldown: 0))
        var previous: ReplayInput?
        var output: [ReplayOutput] = []
        for row in input {
            var reset: String?
            if let previous {
                if row.instanceID != previous.instanceID {
                    machine = try BrightnessTrendStateMachine(configuration: MonitorConfiguration(cooldown: 0))
                    reset = "instance_changed"
                } else if row.sequence != previous.sequence + 1 {
                    machine.resetObservations()
                    reset = "missing_sequences"
                } else if row.uptime - previous.uptime > max(2, machine.pollInterval * 2) {
                    machine.resetObservations()
                    reset = "sampling_gap"
                }
            } else { reset = "visible_window_start" }
            let now = Date(timeIntervalSince1970: row.timestamp)
            let candidate = machine.sample(brightness: row.brightness, at: now, uptime: row.uptime,
                source: SampleSource(rawValue: row.source) ?? .poll)
            // This is an immediate-success counterfactual for scoring/dedup analysis, not a
            // claim that a real notification, shortcut or system appearance succeeded.
            if let candidate { machine.complete(candidate, result: .success, at: now) }
            var stateError: Double?
            if row.recordedModelVersion == 2, let score = row.recordedScore,
               let brightness = row.recordedFilteredBrightness, let velocity = row.recordedVelocity {
                let calculated = BrightnessTrendModel.score(brightness: brightness,
                    baseline: row.recordedBaseline, velocity: velocity, dynamic: false, quietDuration: 0)
                stateError = calculated.score - score
            }
            output.append(ReplayOutput(instanceID: row.instanceID, sequence: row.sequence,
                timestamp: row.timestamp, uptime: row.uptime, brightness: row.brightness, reset: reset,
                trend: machine.trend, frequency: 1 / machine.pollInterval,
                candidate: candidate?.target.rawValue, recordedScore: row.recordedScore,
                recordedBaseline: row.recordedBaseline, recordedFrequency: row.recordedFrequency,
                recordedStateScoreError: stateError))
            previous = row
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(output))
    }
}
