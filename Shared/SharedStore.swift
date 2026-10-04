import Foundation
import Darwin

/// All processes use one advisory lock. Snapshots are also atomically replaced.
/// Only ENOENT is treated as absence; corrupt data and entitlement errors are surfaced.
final class SharedStore: MonitorStore {
    private let root: URL
    private let maxLogBytes = 256 * 1024
    private let logFileCount = 4
    private let files = FileManager.default

    convenience init() throws {
#if os(iOS)
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ProjectError.message("App Group 容器不可用。请检查两个 Target 的签名与 App Group entitlement。")
        }
        try self.init(directory: container.appendingPathComponent("AutoDarkShift", isDirectory: true))
#else
        throw ProjectError.message("共享容器仅在 iOS 可用；测试应注入临时目录。")
#endif
    }

    /// Explicit local directories are for diagnostics/tests, never an implicit shared-store fallback.
    init(directory: URL) throws {
        root = directory
#if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
#else
        let attributes: [FileAttributeKey: Any] = [:]
#endif
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        // A container URL alone does not establish write access under the installed signature.
        try locked(exclusive: true) {
            let probe = url("probe-\(UUID().uuidString)")
            try Data("ready".utf8).write(to: probe, options: Self.writeOptions)
            defer { try? files.removeItem(at: probe) }
            guard try Data(contentsOf: probe) == Data("ready".utf8) else {
                throw ProjectError.message("存储读写检查失败。")
            }
        }
    }

    private static var writeOptions: Data.WritingOptions {
#if os(iOS)
        return [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
#else
        return [.atomic]
#endif
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func locked<T>(exclusive: Bool, _ body: () throws -> T) throws -> T {
        let fd = Darwin.open(url("store.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        while flock(fd, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url(name)) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               failure.code == CocoaError.Code.fileReadNoSuchFile.rawValue { return nil }
            throw error
        }
        return try SharedJSON.decoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        try SharedJSON.encoder().encode(value).write(to: url(name), options: Self.writeOptions)
    }

    func configuration() throws -> MonitorConfiguration {
        try configuration(defaultValue: MonitorConfiguration(revision: "defaults-v1"))
    }

    /// A new parallel business starts disabled without changing legacy defaults.
    func configuration(defaultValue: MonitorConfiguration) throws -> MonitorConfiguration {
        try locked(exclusive: false) {
            try (read(MonitorConfiguration.self, name: "configuration.json") ?? defaultValue).validated()
        }
    }
    func saveConfiguration(_ configuration: MonitorConfiguration) throws {
        let validated = try configuration.validated()
        try locked(exclusive: true) { try write(validated, name: "configuration.json") }
    }
    func snapshot() throws -> RuntimeSnapshot? {
        try locked(exclusive: false) { try read(RuntimeSnapshot.self, name: "status.json") }
    }
    func saveSnapshot(_ snapshot: RuntimeSnapshot) throws {
        try locked(exclusive: true) { try write(snapshot, name: "status.json") }
    }
    func history() throws -> SubmissionHistory? {
        try locked(exclusive: false) { try read(SubmissionHistory.self, name: "submission-history.json") }
    }
    func saveHistory(_ history: SubmissionHistory) throws {
        try locked(exclusive: true) { try write(history, name: "submission-history.json") }
    }

    private func providerCacheName(_ stream: MonitorLogStream) -> String {
        stream == .runtime ? "provider-diagnostics.jsonl" : "provider-boost-traces.jsonl"
    }

    func saveProviderDiagnostics(_ text: String, stream: MonitorLogStream = .runtime) throws {
        let data = Data(text.utf8)
        guard (stream == .boost || !data.isEmpty), data.count <= MonitorWire.maximumDiagnosticBytes else {
            throw ProjectError.message("扩展日志缓存为空或超过容量。")
        }
        guard data.isEmpty || data.last == 0x0A else { throw ProjectError.message("扩展日志缓存末行不完整。") }
        for line in text.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        try locked(exclusive: true) {
            // Upgrade before replacing the mixed cache; a failed Boost sync must keep its acquired history.
            if stream == .runtime, !files.fileExists(atPath: url(providerCacheName(.boost)).path),
               let oldBoost = try cachedProviderData(.boost), !oldBoost.isEmpty {
                try oldBoost.write(to: url(providerCacheName(.boost)), options: Self.writeOptions)
            }
            try data.write(to: url(providerCacheName(stream)), options: Self.writeOptions)
        }
    }

    /// Split a pre-v2 mixed cache on read; new snapshots use independent atomic files.
    private func cachedProviderData(_ stream: MonitorLogStream) throws -> Data? {
        let path = url(providerCacheName(stream))
        if stream == .boost, files.fileExists(atPath: path.path) { return try Data(contentsOf: path) }
        let legacy = url(providerCacheName(.runtime))
        guard files.fileExists(atPath: legacy.path) else { return nil }
        let source = try Data(contentsOf: legacy)
        var result = Data()
        for line in source.split(separator: 0x0A) {
            let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            let captureEvents: Set<String> = ["boost_trace_start", "boost_trace_sample", "boost_trace_end",
                "boost_trace_export_boundary", "boost_trace_export_omitted"]
            let isBoost = captureEvents.contains(object?["event"] as? String ?? "") || object?["s"] != nil
            if isBoost == (stream == .boost) { result.append(contentsOf: line); result.append(0x0A) }
        }
        if stream == .boost, result.isEmpty { return nil }
        return result
    }

    func providerDiagnostics(stream: MonitorLogStream = .runtime) throws -> String? {
        try locked(exclusive: false) { try cachedProviderData(stream).map { String(decoding: $0, as: UTF8.self) } }
    }

    private func logURL(_ index: Int, prefix: String = "runtime") -> URL { url("\(prefix)-\(index).jsonl") }

    func append(_ record: LogRecord) throws {
        try append(record, prefix: "runtime", maxBytes: maxLogBytes, fileCount: logFileCount)
    }

    private func append(_ record: LogRecord, prefix: String, maxBytes: Int, fileCount: Int) throws {
        var bounded = record
        bounded.fields = record.fields.mapValues { String($0.prefix(2048)) }
        var line = try SharedJSON.encoder().encode(bounded)
        line.append(0x0A)
        guard line.count <= maxBytes else { throw ProjectError.message("日志单条记录超过容量上限。") }
        try locked(exclusive: true) {
            let active = logURL(0, prefix: prefix)
            let size = (try? files.attributesOfItem(atPath: active.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + line.count > maxBytes {
                let oldest = logURL(fileCount - 1, prefix: prefix)
                if files.fileExists(atPath: oldest.path) { try files.removeItem(at: oldest) }
                for index in stride(from: fileCount - 2, through: 0, by: -1) {
                    let source = logURL(index, prefix: prefix)
                    if files.fileExists(atPath: source.path) {
                        try files.moveItem(at: source, to: logURL(index + 1, prefix: prefix))
                    }
                }
            }
            if !files.fileExists(atPath: active.path) {
                try Data().write(to: active, options: Self.writeOptions)
            }
            let handle = try FileHandle(forUpdating: active)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let lastByte = try handle.read(upToCount: 1)
                if lastByte?.first != 0x0A {
                    // Process termination can interrupt append. Repair the tail before another line.
                    try handle.seek(toOffset: 0)
                    let damaged = try handle.readToEnd() ?? Data()
                    let validLength = damaged.lastIndex(of: 0x0A).map { UInt64($0 + 1) } ?? 0
                    try handle.truncate(atOffset: validLength)
                }
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    /// Independent full-resolution Boost captures. Open files are never rotated away.
    func appendBoostTrace(id: String, records: [LogRecord], finished: Bool) throws {
        guard UUID(uuidString: id) != nil else { throw ProjectError.message("亮度日志编号无效。") }
        var data = Data()
        for record in records {
            data.append(try BoostTraceEncoding.encode(record)); data.append(0x0A)
        }
        try locked(exclusive: true) {
            let active = url("boost-trace-\(id).open.jsonl")
            let complete = url("boost-trace-\(id).jsonl")
            guard !files.fileExists(atPath: complete.path) else { throw ProjectError.message("亮度日志已结束，不能再次追加。") }
            let size = try repairedTraceSize(at: active)
            guard size + data.count <= 8 * 1024 * 1024 else {
                var marker = try SharedJSON.encoder().encode(LogRecord(instanceID: records.first?.instanceID ?? "store", event: "boost_trace_end", fields: [
                    "traceID": id, "complete": "false", "reason": "capture_size_limit", "retainedBytes": String(size)
                ])); marker.append(0x0A)
                try appendTraceData(marker, to: active)
                try files.moveItem(at: active, to: complete)
                try pruneBoostTraces()
                throw ProjectError.message("单次亮度日志超过 8 MiB；已保留部分记录并标记 capture_size_limit。")
            }
            try appendTraceData(data, to: active)
            if finished { try files.moveItem(at: active, to: complete) }
            try pruneBoostTraces()
        }
    }

    private func repairedTraceSize(at path: URL) throws -> Int {
        guard files.fileExists(atPath: path.path) else { return 0 }
        let handle = try FileHandle(forUpdating: path)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end > 0 else { return 0 }
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1)?.first == 0x0A { return Int(end) }
        try handle.seek(toOffset: 0)
        let damaged = try handle.readToEnd() ?? Data()
        let size = damaged.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        try handle.truncate(atOffset: UInt64(size))
        return size
    }

    private func appendTraceData(_ data: Data, to path: URL) throws {
        if !files.fileExists(atPath: path.path) { try Data().write(to: path, options: Self.writeOptions) }
        _ = try repairedTraceSize(at: path)
        let handle = try FileHandle(forUpdating: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func boostTracePaths() throws -> [URL] {
        try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("boost-trace-") && $0.pathExtension == "jsonl" }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first == second ? $0.lastPathComponent < $1.lastPathComponent : first < second
            }
    }

    private func pruneBoostTraces() throws {
        var completed = try boostTracePaths().filter { !$0.lastPathComponent.contains(".open.") }
        var bytes = try completed.reduce(0) { total, path in
            total + ((try files.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        while completed.count > 8 || bytes > 16 * 1024 * 1024 {
            let oldest = completed.removeFirst()
            bytes -= (try files.attributesOfItem(atPath: oldest.path)[.size] as? NSNumber)?.intValue ?? 0
            try files.removeItem(at: oldest)
        }
    }

    /// A new listener closes orphan captures; opening an App store does not interrupt a live trace.
    func recoverBoostTraces(instanceID: String, at date: Date) throws {
        try locked(exclusive: true) {
            for path in try boostTracePaths() where path.lastPathComponent.contains(".open.") {
                let id = String(path.lastPathComponent.dropFirst("boost-trace-".count).dropLast(".open.jsonl".count))
                let record = LogRecord(timestamp: date, instanceID: instanceID, event: "boost_trace_end", fields: [
                    "traceID": id, "complete": "false", "reason": "process_interrupted",
                    "detail": "Retained samples are partial; the final buffered second may be missing."
                ])
                var line = try SharedJSON.encoder().encode(record); line.append(0x0A)
                try appendTraceData(line, to: path)
                try files.moveItem(at: path, to: url("boost-trace-\(id).jsonl"))
            }
            try pruneBoostTraces()
        }
    }

    /// Whole retained files only; exports never crop a Boost into a misleading sample tail.
    private func boostTraceData(maxBytes: Int = 12 * 1024 * 1024) throws -> Data {
        var segments: [Data] = []
        var bytes = 0
        var omitted: [String] = []
        for path in try boostTracePaths().reversed() {
            let segment = try Data(contentsOf: path)
            let completeLines = segment.lastIndex(of: 0x0A).map { Data(segment.prefix(through: $0)) } ?? Data()
            var exported = completeLines
            if path.lastPathComponent.contains(".open.") {
                let id = String(path.lastPathComponent.dropFirst("boost-trace-".count).dropLast(".open.jsonl".count))
                exported.append(try SharedJSON.encoder().encode(LogRecord(instanceID: "store", event: "boost_trace_export_boundary", fields: [
                    "traceID": id, "complete": "false", "reason": "capture_active_at_export"
                ]))); exported.append(0x0A)
            }
            if bytes + exported.count <= maxBytes {
                segments.append(exported); bytes += exported.count
            } else { omitted.append(path.lastPathComponent) }
        }
        var data = Data()
        if !omitted.isEmpty {
            data.append(try SharedJSON.encoder().encode(LogRecord(instanceID: "store", event: "boost_trace_export_omitted", fields: [
                "files": omitted.joined(separator: ","), "reason": "whole_capture_export_budget", "exportBudgetBytes": String(maxBytes)
            ]))); data.append(0x0A)
        }
        for segment in segments.reversed() { data.append(segment) }
        return data
    }

    func boostTraceDiagnostics() throws -> String {
        try locked(exclusive: false) { String(decoding: try boostTraceData(), as: UTF8.self) }
    }

    /// Read while writers are locked; tolerate only a truncated final line left by process death.
    func exportData(metadata: [String: String], stream: MonitorLogStream = .runtime, includeProviderCache: Bool = true) throws -> Data {
        try locked(exclusive: false) {
            var data = try SharedJSON.encoder().encode(LogRecord(instanceID: "app", event: "export_metadata", fields: metadata.merging(["stream": stream.rawValue]) { _, new in new }))
            data.append(0x0A)
            if stream == .runtime {
                for name in ["configuration.json", "status.json", "submission-history.json"] {
                    let path = url(name)
                    if files.fileExists(atPath: path.path) {
                        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
                        data.append(try JSONSerialization.data(withJSONObject: ["event": "export_snapshot", "file": name, "data": object], options: [.sortedKeys]))
                        data.append(0x0A)
                    }
                }
                for index in stride(from: logFileCount - 1, through: 0, by: -1) {
                    let path = logURL(index)
                    if files.fileExists(atPath: path.path) {
                        let segment = try Data(contentsOf: path)
                        if let end = segment.lastIndex(of: 0x0A) { data.append(segment.prefix(through: end)) }
                    }
                }
                data.append(try legacyDiagnosticData())
            } else { data.append(try boostTraceData()) }
            let cachedPath = url(providerCacheName(stream))
            if includeProviderCache, let cached = try cachedProviderData(stream) {
                let acquiredAt = (try? files.attributesOfItem(atPath: cachedPath.path)[.modificationDate] as? Date) ?? Date()
                data.append(try SharedJSON.encoder().encode(LogRecord(timestamp: acquiredAt, instanceID: "app", event: "provider_logs_cache_export", fields: [
                    "bytes": String(cached.count), "source": "provider_originated_persisted_copy", "stream": stream.rawValue
                ])))
                data.append(0x0A)
                data.append(cached)
            }
            return data
        }
    }

    /// Read-only compatibility: keep build 7/8 result files exportable after retiring the test.
    private func legacyDiagnosticData() throws -> Data {
        var data = Data()
        for index in stride(from: 1, through: 0, by: -1) {
            let path = logURL(index, prefix: "polling-results")
            if files.fileExists(atPath: path.path) {
                let segment = try Data(contentsOf: path)
                if let end = segment.lastIndex(of: 0x0A) { data.append(segment.prefix(through: end)) }
            }
        }
        return data
    }

    /// Existing archived diagnostic records only; no producer or writer remains in this version.
    func legacyDiagnostics() throws -> String {
        try locked(exclusive: false) { String(decoding: try legacyDiagnosticData(), as: UTF8.self) }
    }

    func exportLogs(metadata: [String: String]) throws -> URL {
        try Self.writeExport(exportData(metadata: metadata))
    }

    /// A bounded control-channel payload containing only complete JSONL records, without snapshots.
    func diagnosticTail(maxBytes: Int = 32 * 1024) throws -> String {
        try locked(exclusive: false) {
            var data = Data()
            for index in stride(from: logFileCount - 1, through: 0, by: -1) {
                let path = logURL(index)
                if files.fileExists(atPath: path.path) {
                    let segment = try Data(contentsOf: path)
                    if let end = segment.lastIndex(of: 0x0A) { data.append(segment.prefix(through: end)) }
                }
            }
            if data.count > maxBytes {
                data = Data(data.suffix(maxBytes))
                // Drop the leading fragment; retain only complete JSONL records.
                if let newline = data.firstIndex(of: 0x0A) { data = Data(data.suffix(from: newline + 1)) }
                else { data = Data() }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    static func writeExport(_ data: Data) throws -> URL {
        try writeExports([.runtime: data])[0]
    }

    static func writeExports(_ streams: [MonitorLogStream: Data]) throws -> [URL] {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("AutoDarkShift-Exports", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Bound app-local exports, retaining the new file for the share sheet.
        for old in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where old.pathExtension == "jsonl" {
            try files.removeItem(at: old)
        }
        let id = UUID().uuidString
        return try MonitorLogStream.allCases.compactMap { stream in
            guard let data = streams[stream] else { return nil }
            let result = directory.appendingPathComponent("AutoDarkShift-\(stream.rawValue)-\(id).jsonl")
            try data.write(to: result, options: .atomic)
            return result
        }
    }
}
