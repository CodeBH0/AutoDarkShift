import Foundation

enum MonitoringBusiness: String, Codable, Equatable {
    case standard
    case message
    case backBoard = "backboard"
}

/// Serializes the businesses and enables one only after every other reports
/// disabled sampling and terminal notification state.
@MainActor final class ExclusiveMonitoringBusiness {
    private struct Endpoint {
        let business: MonitoringBusiness
        let client: any MonitoringClient
        let store: any MonitorStore
        let preflight: () throws -> Void
    }
    private let endpoints: [Endpoint]
    private var operation: Task<MonitorReply?, Error>?
    private var operationID: UUID?

    init(standard: any MonitoringClient, standardStore: any MonitorStore,
         message: any MonitoringClient, messageStore: any MonitorStore,
         preflightMessage: @escaping () throws -> Void = {},
         backBoard: (any MonitoringClient)? = nil, backBoardStore: (any MonitorStore)? = nil,
         preflightBackBoard: @escaping () throws -> Void = {}) {
        var endpoints = [Endpoint(business: .standard, client: standard, store: standardStore, preflight: {}),
                         Endpoint(business: .message, client: message, store: messageStore, preflight: preflightMessage)]
        if let backBoard, let backBoardStore {
            endpoints.append(Endpoint(business: .backBoard, client: backBoard, store: backBoardStore,
                                      preflight: preflightBackBoard))
        }
        self.endpoints = endpoints
    }

    func select(_ business: MonitoringBusiness?) async throws -> MonitorReply? {
        try await enqueue { try await self.performSelect(business) }
    }

    /// Restores the persisted selection; conflicts prefer BackBoard, then message.
    /// performSelect durably disables all stores before contacting any host.
    func resumeSelected() async throws -> MonitorReply? {
        try await enqueue {
            var selected: MonitoringBusiness?
            for endpoint in self.endpoints {
                if try endpoint.store.configuration().isEnabled { selected = endpoint.business }
            }
            return try await self.performSelect(selected)
        }
    }

    private func enqueue(_ work: @escaping @MainActor () async throws -> MonitorReply?) async throws -> MonitorReply? {
        let previous = operation
        let id = UUID()
        let next = Task { @MainActor in
            if let previous { _ = try? await previous.value }
            return try await work()
        }
        operation = next
        operationID = id
        defer {
            if operationID == id {
                operation = nil
                operationID = nil
            }
        }
        return try await next.value
    }

    private func performSelect(_ business: MonitoringBusiness?) async throws -> MonitorReply? {
        // Establish the fail-closed state in persistent storage before any query
        // can reconcile and create a host. Save standard first for conflict recovery.
        let disabled = try endpoints.map { try disabledConfiguration(in: $0.store) }
        for (endpoint, configuration) in zip(endpoints, disabled) {
            try save(configuration, to: endpoint.store)
        }

        var stoppedReply: MonitorReply?
        for (endpoint, configuration) in zip(endpoints, disabled) {
            stoppedReply = try await stopAndConfirm(client: endpoint.client, store: endpoint.store,
                                                     disabled: configuration) ?? stoppedReply
        }

        guard let business else { return stoppedReply }
        guard let target = endpoints.first(where: { $0.business == business }) else {
            throw ProjectError.message("所选监听业务未注册。")
        }
        try target.preflight()
        let targetStore = target.store
        let targetClient = target.client
        var enabled = try targetStore.configuration()
        enabled.cooldown = try endpoints[0].store.configuration().cooldown
        enabled.isEnabled = true
        enabled.revision = UUID().uuidString
        try targetStore.saveConfiguration(try enabled.validated())
        do {
            let reply = try await targetClient.applyConfiguration(enabled)
            guard reply.success, reply.appliedRevision == enabled.revision,
                  let snapshot = reply.snapshot, snapshot.appliedConfiguration == enabled,
                  snapshot.phase == .running || snapshot.phase == .sleeping else {
                throw ProjectError.message("目标业务未确认应用配置：\(reply.message)")
            }
            return reply
        } catch {
            // A failed reply can mean the remote accepted the request but its
            // response was lost. Roll storage back and try to stop it before return.
            let rollback = try disabledConfiguration(in: targetStore)
            try? targetStore.saveConfiguration(rollback)
            _ = try? await stopAndConfirm(client: targetClient, store: targetStore, disabled: rollback)
            throw error
        }
    }

    private func stopAndConfirm(client: any MonitoringClient, store: any MonitorStore,
                                disabled: MonitorConfiguration) async throws -> MonitorReply? {
        if let host = client as? MonitoringHostCoordinator {
            let reply = try await host.disableAndDrain(disabled)
            guard reply.success, let snapshot = reply.snapshot, Self.isInactive(snapshot, revision: disabled.revision) else {
                throw ProjectError.message("业务停用及通知结算未获确认：\(reply.message)")
            }
            try persistHistory(snapshot.history, in: store)
            return reply
        }

        let initial = try await client.queryStatus()
        guard initial.success, let initialSnapshot = initial.snapshot else {
            throw ProjectError.message("无法确认业务运行状态：\(initial.message)")
        }
        try persistHistory(initialSnapshot.history, in: store)
        if initialSnapshot.phase == .stopped && initialSnapshot.submission?.result != .submitting {
            return initial
        }

        let disabledReply = try await client.applyConfiguration(disabled)
        guard disabledReply.success, disabledReply.appliedRevision == disabled.revision else {
            throw ProjectError.message("关闭业务配置未获确认：\(disabledReply.message)")
        }
        try persistHistory(disabledReply.snapshot?.history, in: store)

        var reply = disabledReply
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            guard reply.success, let snapshot = reply.snapshot else {
                throw ProjectError.message("业务停止状态不可读：\(reply.message)")
            }
            try persistHistory(snapshot.history, in: store)
            if Self.isInactive(snapshot, revision: disabled.revision) { return reply }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw ProjectError.message("业务停止超时；未启动另一业务。")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            reply = try await client.queryStatus()
        }
    }

    private static func isInactive(_ snapshot: RuntimeSnapshot, revision: String) -> Bool {
        guard snapshot.submission?.result != .submitting else { return false }
        if snapshot.phase == .stopped { return true }
        return snapshot.appliedConfiguration.revision == revision &&
            !snapshot.appliedConfiguration.isEnabled && snapshot.activePollInterval == nil
    }

    private func disabledConfiguration(in store: any MonitorStore) throws -> MonitorConfiguration {
        var configuration = try store.configuration()
        configuration.isEnabled = false
        configuration.revision = UUID().uuidString
        return configuration
    }

    private func save(_ configuration: MonitorConfiguration, to store: any MonitorStore) throws {
        try store.saveConfiguration(configuration.validated())
    }

    private func persistHistory(_ history: SubmissionHistory?, in store: any MonitorStore) throws {
        guard let history else { return }
        if let current = try store.history(), current.submittedAt >= history.submittedAt { return }
        try store.saveHistory(history)
    }

}
