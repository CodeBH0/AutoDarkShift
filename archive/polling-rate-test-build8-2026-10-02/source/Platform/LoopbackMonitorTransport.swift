import Foundation
import Network

/// Length-prefixed TCP on 127.0.0.1 only. No Bonjour, LAN listener, HTTP, or external server.
@MainActor final class LoopbackMonitorServer {
    private var listener: NWListener?
    private var peers: [UUID: NWConnection] = [:]
    private var deadlines: [UUID: Task<Void, Never>] = [:]
    private let credentials: MonitorBridgeCredentials
    private let handle: (Data) -> Data?
    private let record: (String, [String: String]) -> Void

    init(credentials: MonitorBridgeCredentials, handle: @escaping (Data) -> Data?,
         record: @escaping (String, [String: String]) -> Void) {
        self.credentials = credentials
        self.handle = handle
        self.record = record
    }

    func start() throws {
        _ = try credentials.validated()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: credentials.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.record("loopback_listener_ready", ["host": "127.0.0.1", "port": String(self?.credentials.port ?? 0)])
                case .failed(let error): self?.record("loopback_listener_failed", ["error": String(describing: error)]); self?.stop()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] peer in
            MainActor.assumeIsolated { self?.accept(peer) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.cancel() }
        for deadline in deadlines.values { deadline.cancel() }
        peers.removeAll()
        deadlines.removeAll()
    }

    private func accept(_ peer: NWConnection) {
        guard peers.count < 8 else { peer.cancel(); return }
        let id = UUID()
        peers[id] = peer
        deadlines[id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.close(id)
        }
        peer.start(queue: .main)
        receiveExactly(peer, count: 4) { [weak self] header in
            guard let self, let header, let count = try? MonitorWire.frameLength(header) else { self?.close(id); return }
            self.receiveExactly(peer, count: count) { [weak self] data in
                guard let self else { return }
                guard let data, let envelope = try? SharedJSON.decoder().decode(MonitorBridgeEnvelope.self, from: data),
                      envelope.token == self.credentials.token else { self.close(id); return }
                guard let response = self.handle(envelope.payload), let frame = try? MonitorWire.frame(response) else {
                    self.close(id); return
                }
                peer.send(content: frame, completion: .contentProcessed { [weak self] _ in
                    MainActor.assumeIsolated { self?.close(id) }
                })
            }
        }
    }

    private func close(_ id: UUID) {
        peers.removeValue(forKey: id)?.cancel()
        deadlines.removeValue(forKey: id)?.cancel()
    }

    private func receiveExactly(_ peer: NWConnection, count: Int, completion: @escaping (Data?) -> Void) {
        peer.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            MainActor.assumeIsolated { completion(error == nil && data?.count == count ? data : nil) }
        }
    }
}

@MainActor final class LoopbackMonitorClient {
    func send(_ payload: Data, credentials: MonitorBridgeCredentials) async throws -> Data {
        let credentials = try credentials.validated()
        let envelope = try SharedJSON.encoder().encode(MonitorBridgeEnvelope(token: credentials.token, payload: payload))
        let frame = try MonitorWire.frame(envelope)
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: credentials.port)!, using: .tcp)
        let exchange = LoopbackExchange(connection: connection)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                exchange.continuation = continuation
                exchange.deadline = Task {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    exchange.finish(.failure(MonitorChannelError.bridgeUnavailable("连接或回复超时")))
                }
                connection.stateUpdateHandler = { state in
                    MainActor.assumeIsolated {
                        switch state {
                        case .ready:
                            connection.send(content: frame, completion: .contentProcessed { error in
                                MainActor.assumeIsolated {
                                    if let error { exchange.fail(error); return }
                                    exchange.receiveHeader()
                                }
                            })
                        case .failed(let error), .waiting(let error): exchange.fail(error)
                        case .cancelled: exchange.finish(.failure(CancellationError()))
                        default: break
                        }
                    }
                }
                connection.start(queue: .main)
            }
        } onCancel: { Task { @MainActor in exchange.finish(.failure(CancellationError())) } }
    }
}

@MainActor private final class LoopbackExchange {
    let connection: NWConnection
    var continuation: CheckedContinuation<Data, Error>?
    var deadline: Task<Void, Never>?
    init(connection: NWConnection) { self.connection = connection }

    func receiveHeader() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [self] data, _, _, error in
            MainActor.assumeIsolated {
                if let error { fail(error); return }
                guard let data, let count = try? MonitorWire.frameLength(data) else {
                    finish(.failure(MonitorChannelError.bridgeUnavailable("回复头不完整"))); return
                }
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { [self] data, _, _, error in
                    MainActor.assumeIsolated {
                        if let error { fail(error); return }
                        guard let data, data.count == count else {
                            finish(.failure(MonitorChannelError.bridgeUnavailable("回复数据不完整"))); return
                        }
                        finish(.success(data))
                    }
                }
            }
        }
    }

    func fail(_ error: Error) { finish(.failure(MonitorChannelError.bridgeUnavailable(String(describing: error)))) }
    func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(with: result)
    }
}
