import Foundation

enum MonitoringReadbackAvailability: String {
    case notChecked, available, unavailable, failed
}

/// Tracks observable replies, not whether the independent listener is working.
struct MonitoringReadback {
    private(set) var availability: MonitoringReadbackAvailability = .notChecked
    private(set) var issue: String?
    private(set) var consecutiveUnavailable = 0
    private(set) var nextQueryAt = Date.distantPast

    func shouldQuery(at date: Date) -> Bool { date >= nextQueryAt }

    mutating func reset() { self = Self() }

    mutating func receivedReply(at date: Date) {
        availability = .available
        issue = nil
        consecutiveUnavailable = 0
        nextQueryAt = date.addingTimeInterval(1)
    }

    /// Returns true when the diagnostic changed; repeated absence is not a new incident.
    @discardableResult mutating func receivedError(_ error: Error, at date: Date) -> Bool {
        let previousAvailability = availability
        let previousIssue = issue
        issue = describeError(error)
        if error is MonitorChannelError {
            availability = .unavailable
            consecutiveUnavailable += 1
            let delays: [TimeInterval] = [30, 60, 120, 300]
            nextQueryAt = date.addingTimeInterval(delays[min(consecutiveUnavailable - 1, delays.count - 1)])
        } else {
            // Rejected, incompatible or undecodable replies remain actionable failures.
            availability = .failed
            consecutiveUnavailable = 0
            nextQueryAt = date.addingTimeInterval(10)
        }
        return previousAvailability != availability || previousIssue != issue
    }
}
