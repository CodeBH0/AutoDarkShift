import Foundation

enum RuntimeStorageMode: String, Codable {
    case appGroup = "app-group-v1"
    case localIPC = "local-ipc-v1"
}

/// The app selects one explicit mode and passes it to the provider. Local files are never shared.
struct RuntimeStoreSelection {
    let store: SharedStore
    let mode: RuntimeStorageMode
    let fallbackReason: String?

    static func forApp(shared: () throws -> SharedStore, local: () throws -> SharedStore) throws -> Self {
        do { return Self(store: try shared(), mode: .appGroup, fallbackReason: nil) }
        catch { return Self(store: try local(), mode: .localIPC, fallbackReason: describeError(error)) }
    }

    static func forProvider(mode: RuntimeStorageMode, shared: () throws -> SharedStore,
                            local: () throws -> SharedStore) throws -> Self {
        // Do not independently fall back: that would make app/provider disagree on storage.
        Self(store: try mode == .appGroup ? shared() : local(), mode: mode, fallbackReason: nil)
    }

    static func localStore(directoryName: String) throws -> SharedStore {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                              appropriateFor: nil, create: true)
        return try SharedStore(directory: root.appendingPathComponent(directoryName, isDirectory: true))
    }
}
