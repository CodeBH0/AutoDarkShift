import SwiftUI

@MainActor
struct DashboardView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: AppPreferences
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                Toggle("Packet Tunnel 监控", isOn: Binding(
                    get: { controller.autoDarkShiftEnabled },
                    set: { controller.setAutoDarkShiftEnabled($0) }
                ))
                .disabled(controller.businessControlsDisabled)

                Toggle("App 内监控", isOn: Binding(
                    get: { controller.appMonitoringEnabled },
                    set: { controller.setAppMonitoringEnabled($0) }
                ))
                .disabled(controller.businessControlsDisabled || !controller.appMonitoringAvailable)
            } header: { Text("监听方式") } footer: {
                if preferences.developerModeEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("两条路径互斥。Packet Tunnel 需要 VPN 连接；App 内监控使用 BKS 轮询，后台执行许可来自 PiP 或 Location。")
                        if !controller.appMonitoringAvailable {
                            Text("App 内监控当前不可用。")
                        }
                    }
                }
            }

            Section("当前状态") {
                LabeledContent("当前监听", value: controller.activeBusinessText)
                LabeledContent("监听状态", value: controller.samplingText)
                if let snapshot = controller.displayedSnapshot {
                    LabeledContent("监听轮询频率", value: snapshot.activePollInterval.map {
                        "\(Int((1 / $0).rounded())) Hz"
                    } ?? "未采样")
                    dateRow("最近轮询", snapshot.lastPollAt)
                    LabeledContent("采样心跳", value: controller.heartbeatAge.map { "\(formatted($0)) 秒前" } ?? "无")
                    LabeledContent("趋势评分 S", value: snapshot.trend.map { formatted($0.score) } ?? "无")
                    LabeledContent("动态采样", value: snapshot.trend.map { $0.dynamicSampling ? "进行中" : "常规 1 Hz" } ?? "无")
                    LabeledContent("最近采样亮度", value: actualBrightness(snapshot))
                } else {
                    LabeledContent("监听轮询频率", value: "未采样")
                    LabeledContent("最近轮询", value: "无")
                    LabeledContent("采样心跳", value: "无")
                    LabeledContent("趋势评分 S", value: "无")
                    LabeledContent("动态采样", value: "无")
                    LabeledContent("最近采样亮度", value: "无")
                }
                LabeledContent("当前 App 可见外观", value: colorScheme == .dark ? "深色" : "浅色")
            }

            if preferences.developerModeEnabled {
                Section("高级功能") {
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

    private func dateRow(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title, value: date?.formatted(date: .abbreviated, time: .standard) ?? "无")
    }
}
