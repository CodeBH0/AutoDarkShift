import Foundation

struct MonitorBridgeCredentials: Codable {
    var port: UInt16 = UInt16.random(in: 49152...65535)
    var token = UUID().uuidString + UUID().uuidString

    func validated() throws -> Self {
        guard port >= 49152, token.count >= 64 else { throw ProjectError.message("本机日志通道配置无效。") }
        return self
    }
}

struct MonitorBridgeEnvelope: Codable {
    var token: String
    var payload: Data
}

enum MonitorWire {
    static let maximumFrameBytes = 512 * 1024
    static let probePrefix = Data("AutoDarkShift.TransportProbe.v1:".utf8)

    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumFrameBytes else { throw ProjectError.message("日志通道消息长度无效。") }
        let size = UInt32(payload.count)
        var data = Data([UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
        data.append(payload)
        return data
    }

    static func frameLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw ProjectError.message("日志通道消息头不完整。") }
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...maximumFrameBytes).contains(length) else { throw ProjectError.message("日志通道消息超过长度限制。") }
        return length
    }
}

/// A snapshot is held for the duration of a paged export, so live rotation cannot change offsets.
@MainActor final class MonitorDiagnosticPager {
    private struct Snapshot { var data: Data; var createdAt: Date }
    private var snapshots: [String: Snapshot] = [:]

    func page(for request: MonitorRequest, load: () throws -> String) throws -> MonitorReply {
        guard let id = request.exportID, UUID(uuidString: id) != nil else {
            throw ProjectError.message("日志导出缺少有效编号。")
        }
        let offset = request.exportOffset ?? 0
        guard offset >= 0 else { throw ProjectError.message("日志页偏移无效。") }
        let now = Date()
        snapshots = snapshots.filter { now.timeIntervalSince($0.value.createdAt) <= 120 }
        if snapshots[id] == nil {
            guard offset == 0 else { throw ProjectError.message("日志导出快照已失效，请重新导出。") }
            if snapshots.count >= 4, let oldest = snapshots.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                snapshots.removeValue(forKey: oldest)
            }
            let loaded = Data(try load().utf8)
            guard loaded.count <= MonitorWire.maximumFrameBytes else { throw ProjectError.message("日志导出快照超过容量。") }
            snapshots[id] = Snapshot(data: loaded, createdAt: now)
        }
        guard let data = snapshots[id]?.data else { throw ProjectError.message("日志快照不存在。") }
        guard offset <= data.count else { throw ProjectError.message("日志页偏移超出快照。") }
        let end = min(data.count, offset + 4096)
        return MonitorReply(success: true, message: "扩展日志页。", diagnosticPage: data.subdata(in: offset..<end),
                            exportID: id, exportNextOffset: end < data.count ? end : nil, exportTotalBytes: data.count)
    }

    static func collect(id: String, fetch: (MonitorRequest) async throws -> MonitorReply) async throws -> String {
        var data = Data()
        var expectedTotal: Int?
        while true {
            try Task.checkCancellation()
            let reply = try await fetch(MonitorRequest(command: .exportDiagnosticPage, exportID: id, exportOffset: data.count))
            guard reply.success, reply.exportID == id, let page = reply.diagnosticPage,
                  let total = reply.exportTotalBytes, (0...MonitorWire.maximumFrameBytes).contains(total),
                  expectedTotal == nil || expectedTotal == total, page.count <= 4096,
                  data.count + page.count <= total else { throw ProjectError.message("扩展日志分页回复无效。") }
            expectedTotal = total
            data.append(page)
            if let next = reply.exportNextOffset {
                guard !page.isEmpty, next == data.count, next < total else { throw ProjectError.message("扩展日志分页没有前进。") }
            } else {
                guard data.count == total, let text = String(data: data, encoding: .utf8) else {
                    throw ProjectError.message("扩展日志未完整取回。")
                }
                // Only a complete, parseable JSONL snapshot may replace the durable app cache.
                for line in text.split(separator: "\n") {
                    _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
                }
                return text
            }
        }
    }
}
