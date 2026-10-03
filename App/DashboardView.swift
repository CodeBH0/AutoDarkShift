import SwiftUI

@MainActor
struct DashboardView: View {
    @ObservedObject var controller: AppController
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("当前状态") {
                LabeledContent("监听状态", value: controller.samplingText)
                if let snapshot = controller.snapshot {
                    LabeledContent("监听轮询频率", value: snapshot.activePollInterval.map {
                        "\(Int((1 / $0).rounded())) Hz"
                    } ?? "未采样")
                    LabeledContent("趋势评分 S", value: snapshot.trend.map { formatted($0.score) } ?? "无")
                    LabeledContent("实际亮度", value: actualBrightness(snapshot))
                } else {
                    LabeledContent("监听轮询频率", value: "未采样")
                    LabeledContent("趋势评分 S", value: "无")
                    LabeledContent("实际亮度", value: "无")
                }
                LabeledContent("当前 App 可见外观", value: colorScheme == .dark ? "深色" : "浅色")
            }

            Section("功能模块") {
                Toggle("Auto Dark Shift", isOn: Binding(
                    get: { controller.autoDarkShiftEnabled },
                    set: { controller.setAutoDarkShiftEnabled($0) }
                ))
                .disabled(controller.busy)

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
