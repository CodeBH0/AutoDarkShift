import Foundation

enum MonitorChannelError: LocalizedError, CustomNSError {
    case emptyReply, timeout, bridgeUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .emptyReply:
            return "扩展通信未返回数据，当前无法读取运行详情或确认配置应用结果。"
        case .timeout:
            return "扩展通信超时，运行详情或配置应用结果暂未取得。"
        case .bridgeUnavailable(let detail): return "本机扩展日志通道不可用：\(detail)"
        }
    }
    static var errorDomain: String { "AutoDarkShift.MonitorChannel" }
    var errorCode: Int { switch self { case .emptyReply: return 1; case .timeout: return 2; case .bridgeUnavailable: return 3 } }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "扩展通信暂不可用"] }
}

/// Retries only transport unavailability, never a rejected/undecodable application reply.
@MainActor final class MonitorMessageChannel {
    typealias Transport = (Data, @escaping (Data?) -> Void) throws -> Void
    private let timeoutNanoseconds: UInt64
    private let retryNanoseconds: UInt64
    init(timeoutNanoseconds: UInt64 = 2_000_000_000, retryNanoseconds: UInt64 = 200_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryNanoseconds = retryNanoseconds
    }

    func send(_ request: MonitorRequest, transport: @escaping Transport) async throws -> MonitorReply {
        let payload = try SharedJSON.encoder().encode(request)
        for attempt in 0..<2 {
            do {
                let data = try await exchange(payload, transport: transport)
                return try SharedJSON.decoder().decode(MonitorReply.self, from: data)
            } catch let error as MonitorChannelError {
                if attempt == 1 { throw error }
                try await Task.sleep(nanoseconds: retryNanoseconds)
            }
        }
        throw MonitorChannelError.timeout
    }

    func probe(transport: @escaping Transport) async throws {
        var data = MonitorWire.probePrefix
        data.append(Data(UUID().uuidString.utf8))
        guard try await exchange(data, transport: transport) == data else { throw ProjectError.message("系统消息回显内容不匹配。") }
    }

    private func exchange(_ payload: Data, transport: @escaping Transport) async throws -> Data {
        let waiter = MessageWaiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiter.continuation = continuation
                waiter.deadline = Task { [timeoutNanoseconds] in
                    do { try await Task.sleep(nanoseconds: timeoutNanoseconds) }
                    catch { return }
                    waiter.finish(.failure(MonitorChannelError.timeout))
                }
                do {
                    try transport(payload) { response in
                        Task { @MainActor in
                            if let response { waiter.finish(.success(response)) }
                            else { waiter.finish(.failure(MonitorChannelError.emptyReply)) }
                        }
                    }
                } catch { waiter.finish(.failure(error)) }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(.failure(CancellationError())) }
        }
    }
}

/// Only transport absence activates the independent fallback. Rejection/decoding errors are surfaced.
@MainActor final class MonitorTransportRouter {
    private(set) var usesFallback = false
    private var tail: Task<MonitorReply, Error>?
    private var generation = UUID()
    private var sessionGeneration = UUID()

    func reset() {
        usesFallback = false
        generation = UUID()
        sessionGeneration = UUID()
        tail?.cancel()
        tail = nil
    }

    func send(primary: @escaping @MainActor () async throws -> MonitorReply,
              fallback: @escaping @MainActor () async throws -> MonitorReply) async throws -> MonitorReply {
        let previous = tail
        let token = UUID()
        let session = sessionGeneration
        generation = token
        let job = Task { @MainActor in
            if let previous { _ = await previous.result }
            try Task.checkCancellation()
            guard session == self.sessionGeneration else { throw CancellationError() }
            if self.usesFallback {
                let reply = try await fallback()
                guard session == self.sessionGeneration else { throw CancellationError() }
                return reply
            }
            do {
                let reply = try await primary()
                guard session == self.sessionGeneration else { throw CancellationError() }
                return reply
            }
            catch is MonitorChannelError {
                let reply = try await fallback()
                guard session == self.sessionGeneration else { throw CancellationError() }
                self.usesFallback = true
                return reply
            }
        }
        tail = job
        defer { if generation == token { tail = nil } }
        return try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}

@MainActor private final class MessageWaiter {
    var continuation: CheckedContinuation<Data, Error>?
    var deadline: Task<Void, Never>?
    func finish(_ result: Result<Data, Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        deadline?.cancel()
        deadline = nil
        pending.resume(with: result)
    }
}
