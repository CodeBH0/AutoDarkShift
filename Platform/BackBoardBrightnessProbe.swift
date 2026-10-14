import Foundation
import Darwin

/// Resolves the supplied Float getter once and keeps its framework loaded for
/// the lifetime of the process. Availability is separate from a successful read.
enum BackBoardBrightnessProbe {
    typealias Getter = @convention(c) () -> Float
    static let path = "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices"
    static let symbol = "BKSDisplayBrightnessGetCurrent"

    private struct LoadedAPI {
        let handle: UnsafeMutableRawPointer?
        let getter: Getter?
        let stage: String
        let error: String?
    }

    private static let loaded: LoadedAPI = {
        dlerror()
        guard let handle = dlopen(path, RTLD_NOW) else {
            return LoadedAPI(handle: nil, getter: nil, stage: "dlopen", error: loaderError())
        }
        dlerror()
        guard let address = dlsym(handle, symbol) else {
            return LoadedAPI(handle: handle, getter: nil, stage: "dlsym", error: loaderError())
        }
        return LoadedAPI(handle: handle, getter: unsafeBitCast(address, to: Getter.self),
                         stage: "resolved", error: nil)
    }()

    static var availabilityFields: [String: String] {
        ["api": symbol, "frameworkPath": path, "available": String(loaded.getter != nil),
         "loadStage": loaded.stage, "loaderError": loaded.error ?? "none"]
    }

    static func requireAvailable() throws {
        guard loaded.getter != nil else {
            throw ProjectError.message("BackBoard 探针无法加载 \(symbol)（\(loaded.stage)）：\(loaded.error ?? "未知错误")")
        }
    }

    static func read() -> Float? { loaded.getter?() }

    private static func loaderError() -> String {
        dlerror().map { String(cString: $0) } ?? "动态加载器未提供错误详情"
    }
}
