import SwiftUI

@MainActor
struct NotificationStatsMenuView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("通知") {
                LabeledContent("通知权限", value: controller.authorization)
                Button("请求通知权限") { controller.requestNotifications() }
                    .disabled(controller.busy)
                Button("发送测试通知") { controller.sendTestNotification() }
                    .disabled(controller.busy)
                if let feedback = controller.testFeedback {
                    Text(feedback).font(.caption)
                }
            }

            Section {
                if let snapshot = controller.snapshot {
                    if let submission = snapshot.submission {
                        LabeledContent("最近提交结果", value: submission.result.rawValue)
                        LabeledContent("请求目标", value: submission.target.rawValue)
                        LabeledContent("请求亮度 / 来源", value: "\(formatted(submission.brightness)) / \(submission.source.rawValue)")
                        dateRow("结果时间", submission.timestamp)
                        Text(submission.identifier).font(.caption).textSelection(.enabled)
                        if let detail = submission.detail { Text(detail).font(.caption) }
                    } else {
                        Text("本次运行尚未提交通知")
                    }
                    LabeledContent("最近成功提交目标", value: snapshot.history?.target.rawValue ?? "无")
                    dateRow("最近成功提交时间", snapshot.history?.submittedAt)
                    LabeledContent("亮度事件回调", value: String(snapshot.counters.eventCallbacks))
                    LabeledContent("轮询次数", value: String(snapshot.counters.polls))
                    LabeledContent("总采样次数", value: String(snapshot.counters.samples))
                    LabeledContent("通知提交次数", value: String(snapshot.counters.notificationAttempts))
                    LabeledContent("通知提交成功", value: String(snapshot.counters.notificationSuccesses))
                    LabeledContent("扩展启动次数", value: String(snapshot.counters.extensionStarts))
                }
            } header: { Text("统计") } footer: {
                Text("成功表示系统接受通知请求，不代表已展示或快捷指令已执行。统计为累计值，可能因扩展异常终止丢失最后一次写入。")
            }

            Section {
                HStack {
                    Text("通知冷却（秒）")
                    Spacer()
                    TextField("通知冷却（秒）", value: $controller.configuration.cooldown,
                             format: .number.precision(.fractionLength(0...6)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                }
                Button("保存并应用配置") { controller.saveConfiguration() }
                    .disabled(controller.busy)
            } header: { Text("监听配置") } footer: {
                Text("依据屏幕亮度相对于上一稳定状态的变化评分。评分未达切换条件时保持既有目标。")
            }

            Section("日志导出") {
                Button("导出运行日志") { controller.exportLogs(stream: .runtime) }
                    .disabled(controller.busy)
                Button("导出 Boost 日志") { controller.exportLogs(stream: .boost) }
                    .disabled(controller.busy)
                if controller.busy { ProgressView("处理中") }
            }

            ControllerFeedbackView(controller: controller)
        }
        .navigationTitle("通知与统计")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dateRow(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title, value: date?.formatted(date: .abbreviated, time: .standard) ?? "无")
    }
    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
