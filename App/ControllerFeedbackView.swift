import SwiftUI

@MainActor
struct ControllerFeedbackView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if let message = controller.message {
            Section("操作结果") { Text(message).textSelection(.enabled) }
        }
        if controller.appError != nil || controller.disconnectError != nil || controller.runtimeError != nil || controller.storageError != nil {
            Section("错误信息") {
                if let error = controller.appError { errorText("App 操作", error) }
                if let error = controller.runtimeError { errorText("监听通信", error) }
                if let error = controller.storageError { errorText("运行存储", error) }
                if let error = controller.disconnectError { errorText("系统断开原因", error) }
            }
        }
    }

    private func errorText(_ title: String, _ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
