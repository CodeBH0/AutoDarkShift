import SwiftUI

@MainActor
struct DashboardView: View {
    @ObservedObject var controller: AppController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("当前状态") {
                LabeledContent("当前监听", value: controller.activeBusinessText)
                LabeledContent("监听状态", value: controller.samplingText)
                if let snapshot = controller.displayedSnapshot {
                    LabeledContent("监听轮询频率", value: snapshot.activePollInterval.map {
                        "\(Int((1 / $0).rounded())) Hz"
                    } ?? (controller.messageBusinessEnabled ? "仅亮度消息" : "未采样"))
                    LabeledContent("趋势评分 S", value: snapshot.trend.map { formatted($0.score) } ?? "无")
                    LabeledContent("最近采样亮度", value: actualBrightness(snapshot))
                } else {
                    LabeledContent("监听轮询频率", value: "未采样")
                    LabeledContent("趋势评分 S", value: "无")
                    LabeledContent("最近采样亮度", value: "无")
                }
                LabeledContent("当前 App 可见外观", value: colorScheme == .dark ? "深色" : "浅色")
            }

            Section("监听方式") {
                Toggle("Packet Tunnel 监控", isOn: Binding(
                    get: { controller.autoDarkShiftEnabled },
                    set: { controller.setAutoDarkShiftEnabled($0) }
                ))
                .disabled(controller.businessControlsDisabled)

                Toggle("App 内监控", isOn: Binding(
                    get: { controller.messageBusinessEnabled },
                    set: { controller.setMessageBusinessEnabled($0) }
                ))
                .disabled(controller.businessControlsDisabled || !controller.messageBusinessAvailable)
                Text("两条路径互斥，开启一条会先停止另一条。Packet Tunnel 需要 VPN 连接；App 内监控使用 iOS 26 亮度消息，无轮询，后台执行许可来自 PiP 或 Location。")
                    .font(.caption).foregroundStyle(.secondary)
                if !controller.messageBusinessAvailable {
                    Text("App 内监控需要 iOS 26 或更新版本。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                NavigationLink {
                    MonitoringMenuView(controller: controller)
                } label: {
                    Label("切换监听", systemImage: "waveform.path")
                }
                NavigationLink {
                    NotificationStatsMenuView(controller: controller)
                } label: {
                    Label("通知与统计", systemImage: "bell.badge")
                }
            }

            ControllerFeedbackView(controller: controller)
        }
        .navigationTitle("仪表")
        .scrollDismissesKeyboard(.interactively)
    }

    private func actualBrightness(_ snapshot: RuntimeSnapshot) -> String {
        guard let sample = snapshot.sample else { return "无采样记录" }
        return sample.brightness.map(formatted) ?? "非法输入：\(sample.rawValue)"
    }

    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
