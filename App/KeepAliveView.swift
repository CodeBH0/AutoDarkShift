import SwiftUI

@MainActor
struct KeepAliveView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("保活方案") {
                ForEach(controller.keepAliveEntries, id: \.id) { entry in
                    KeepAliveEntryRow(entry: entry, controller: controller)
                }
            }

            if let notice = controller.storageNotice {
                Section { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }

            ControllerFeedbackView(controller: controller)
        }
        .navigationTitle("保活")
    }
}

@MainActor
private struct KeepAliveEntryRow: View {
    let entry: KeepAliveEntry
    @ObservedObject var controller: AppController

    private var statusColor: Color {
        entry.state.lastError == nil ? Color.secondary : Color.red
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if entry.id == .pip {
                Text(entry.name)
                HStack {
                    Button(entry.isEnabled ? "关闭悬浮窗" : "开启悬浮窗") {
                        controller.setKeepAliveEnabled(!entry.isEnabled, method: .pip)
                    }
                    .buttonStyle(.bordered)
                    .disabled(entry.state.phase == .stopping)
                    Button("一键0.1pt") { controller.minimizePiPWindow() }
                        .buttonStyle(.bordered)
                        .disabled(entry.state.phase != .active || entry.isTransitioning)
                }
                Text("开启后将浮窗拖到侧边，再点“一键0.1pt”。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle(entry.name, isOn: Binding(
                    get: { entry.isEnabled },
                    set: { controller.setKeepAliveEnabled($0, method: entry.id) }
                ))
                .disabled(!entry.isEnabled &&
                          (entry.state.phase == .stopping || entry.isTransitioning))
            }

            HStack(spacing: 6) {
                if entry.isTransitioning { ProgressView().controlSize(.small) }
                Text(entry.state.description)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            if let error = entry.state.lastError {
                Text(error).font(.caption).foregroundStyle(Color.red).textSelection(.enabled)
            }
            if entry.id == .location {
                Text("请在前台开启并允许定位，再离开 App。连续定位会增加耗电；位置不保存或上传。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
