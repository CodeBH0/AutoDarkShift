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
        try locked(exclusive: false) {
            try (read(MonitorConfiguration.self, name: "configuration.json") ?? MonitorConfiguration(revision: "defaults-v1")).validated()
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

    func saveProviderDiagnostics(_ text: String) throws {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= MonitorWire.maximumFrameBytes else { throw ProjectError.message("扩展日志缓存为空或超过容量。") }
        for line in text.split(separator: "\n") { _ = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
        try locked(exclusive: true) { try data.write(to: url("provider-diagnostics.jsonl"), options: Self.writeOptions) }
    }

    func providerDiagnostics() throws -> String? {
        try locked(exclusive: false) {
            let path = url("provider-diagnostics.jsonl")
            guard files.fileExists(atPath: path.path) else { return nil }
            return String(decoding: try Data(contentsOf: path), as: UTF8.self)
        }
    }

    private func logURL(_ index: Int, prefix: String = "runtime") -> URL { url("\(prefix)-\(index).jsonl") }

    func append(_ record: LogRecord) throws {
        try append(record, prefix: "runtime", maxBytes: maxLogBytes, fileCount: logFileCount)
    }

    /// Separate retention prevents frequent runtime logs from evicting benchmark summaries.
    func appendPollingResult(_ record: LogRecord) throws {
        try append(record, prefix: "polling-results", maxBytes: 32 * 1024, fileCount: 2)
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

    /// Read while writers are locked; tolerate only a truncated final line left by process death.
    func exportData(metadata: [String: String]) throws -> Data {
        try locked(exclusive: false) {
            var data = try SharedJSON.encoder().encode(LogRecord(instanceID: "app", event: "export_metadata", fields: metadata))
            data.append(0x0A)
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
            data.append(try pollingResultData())
            let cachedPath = url("provider-diagnostics.jsonl")
            if files.fileExists(atPath: cachedPath.path) {
                let cached = try Data(contentsOf: cachedPath)
                let acquiredAt = try files.attributesOfItem(atPath: cachedPath.path)[.modificationDate] as? Date ?? Date()
                data.append(try SharedJSON.encoder().encode(LogRecord(timestamp: acquiredAt, instanceID: "app", event: "provider_logs_cache_export", fields: [
                    "bytes": String(cached.count), "source": "provider_originated_persisted_copy"
                ])))
                data.append(0x0A)
                data.append(cached)
            }
            return data
        }
    }

    private func pollingResultData() throws -> Data {
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

    /// At most 64 KiB, including complete stage/summary records even after runtime log rotation.
    func pollingResults() throws -> String {
        try locked(exclusive: false) { String(decoding: try pollingResultData(), as: UTF8.self) }
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
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("AutoDarkShift-Exports", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Bound app-local exports, retaining the new file for the share sheet.
        for old in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where old.pathExtension == "jsonl" {
            try files.removeItem(at: old)
        }
        let result = directory.appendingPathComponent("AutoDarkShift-\(UUID().uuidString).jsonl")
        try data.write(to: result, options: .atomic)
        return result
    }
}
