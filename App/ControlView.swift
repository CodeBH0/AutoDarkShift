import SwiftUI
import UIKit

@MainActor
struct ControlView: View {
    @StateObject private var controller = AppComposition.makeController()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingExport = false

    var body: some View {
        NavigationStack {
            Form {
                Section("保活与通知") {
                    LabeledContent("当前保活方案", value: controller.keepAliveName)
                    LabeledContent("保活状态", value: controller.keepAliveStatusText)
                    LabeledContent("通知权限", value: controller.authorization)
                    Button("请求通知权限") { controller.requestNotifications() }
                        .disabled(controller.busy)
                    Toggle("保活", isOn: Binding(get: { controller.keepAliveEnabled },
                                               set: { controller.setKeepAliveEnabled($0) }))
                        .disabled(controller.busy || controller.keepAliveTransitioning)
                    if let notice = controller.storageNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if controller.busy { ProgressView("处理中") }
                }
                Section {
                    LabeledContent("评分切换条件", value: "≤ −0.50 深色；≥ 0.50 浅色")
                    LabeledContent("自动采样频率", value: "1 / 10 / 30 / 60 / 120 Hz")
                    numberField("通知冷却（秒）", value: $controller.configuration.cooldown)
                    Button("保存并应用配置") { controller.saveConfiguration() }
                        .disabled(controller.busy)
                } header: { Text("亮度趋势模型") } footer: {
                    Text("依据屏幕亮度相对于上一稳定状态的变化评分。评分未达切换条件时保持既有目标；相同屏幕亮度轨迹无法区分真实环境照度。")
                }
                Section("切换监听") {
                    Label(controller.samplingText, systemImage: controller.samplingIsLive ? "waveform.path" : "info.circle")
                        .foregroundStyle(controller.samplingIsLive ? .green : controller.runtimeError != nil ? .red : .secondary)
                    if let notice = controller.runtimeNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    if let snapshot = controller.snapshot {
                        LabeledContent("最近监听阶段", value: snapshot.phase.rawValue)
                        dateRow("状态更新时间", snapshot.updatedAt)
                        dateRow("采样心跳", snapshot.heartbeatAt)
                        LabeledContent("心跳年龄", value: controller.heartbeatAge.map { "\(formatted($0)) 秒" } ?? "无")
                        LabeledContent("过期判定", value: "\(formatted(controller.heartbeatLimit)) 秒")
                        dateRow("最近轮询", snapshot.lastPollAt)
                        LabeledContent("实际轮询间隔", value: snapshot.lastPollInterval.map { "\(formatted($0)) 秒" } ?? "无")
                        LabeledContent("目标轮询频率", value: snapshot.activePollInterval.map { "\(Int((1 / $0).rounded())) Hz" } ?? "未采样")
                        if let trend = snapshot.trend {
                            LabeledContent("趋势评分 S", value: formatted(trend.score))
                            LabeledContent("亮度位置 A", value: formatted(trend.position))
                            LabeledContent("累计变化 Δ", value: formatted(trend.change))
                            LabeledContent("归一化速度 V", value: formatted(trend.speed))
                            LabeledContent("方向一致性 D", value: formatted(trend.direction))
                            LabeledContent("变化速度", value: "\(formatted(trend.velocity)) / 秒")
                            LabeledContent("变化起始亮度", value: trend.baseline.map(formatted) ?? "等待明显变化")
                            LabeledContent("动态采样", value: trend.dynamicSampling ? "进行中" : "常规 1 Hz")
                            LabeledContent("连续低速时长", value: "\(formatted(trend.quietDuration)) 秒")
                        }
                        if let sample = snapshot.sample {
                            LabeledContent("实际亮度", value: sample.brightness.map(formatted) ?? "非法输入：\(sample.rawValue)")
                            LabeledContent("数据来源", value: sample.source.rawValue)
                            dateRow("采样时间", sample.timestamp)
                            LabeledContent("采样序号", value: String(sample.sequence))
                            LabeledContent("距上次采样", value: sample.actualInterval.map { "\(formatted($0)) 秒" } ?? "首次")
                        } else { Text("尚无采样记录") }
                        LabeledContent("既有目标", value: snapshot.desiredTarget?.rawValue ?? "等待趋势评分")
                        LabeledContent("待处理目标", value: snapshot.pendingTarget?.rawValue ?? "无")
                        LabeledContent("配置已确认", value: controller.runtimeConfirmed && snapshot.appliedConfiguration == controller.configuration ? "是" : "未确认当前编辑配置")
                        Text("监听实例：\(snapshot.instanceID)").font(.caption).textSelection(.enabled)
                        if let error = snapshot.lastError { errorText("监听最近错误", error) }
                    } else { Text("暂未取得运行详情") }
                    Button("查询监听状态") { controller.queryMonitoring() }
                        .disabled(controller.busy || !controller.keepAliveState.phase.canMessage)
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
                        } else { Text("本次运行尚未提交通知") }
                        LabeledContent("最近成功提交目标", value: snapshot.history?.target.rawValue ?? "无")
                        dateRow("最近成功提交时间", snapshot.history?.submittedAt)
                        LabeledContent("亮度事件回调", value: String(snapshot.counters.eventCallbacks))
                        LabeledContent("轮询次数", value: String(snapshot.counters.polls))
                        LabeledContent("总采样次数", value: String(snapshot.counters.samples))
                        LabeledContent("通知提交次数", value: String(snapshot.counters.notificationAttempts))
                        LabeledContent("通知提交成功", value: String(snapshot.counters.notificationSuccesses))
                        LabeledContent("扩展启动次数", value: String(snapshot.counters.extensionStarts))
                    }
                    Button("发送测试通知") { controller.sendTestNotification() }.disabled(controller.busy)
                    if let feedback = controller.testFeedback { Text(feedback).font(.caption) }
                    Button("导出运行日志") { controller.exportLogs() }.disabled(controller.busy)
                } header: { Text("通知与统计") } footer: {
                    Text("成功表示系统接受通知请求，不代表已展示或快捷指令已执行。统计为累计值，可能因扩展异常终止丢失最后一次写入。")
                }
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
            .navigationTitle("AutoDarkShift")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { controller.setForeground(scenePhase == .active) }
            .onDisappear { controller.setForeground(false) }
            .onChange(of: scenePhase) { _, phase in controller.setForeground(phase == .active) }
            .onChange(of: controller.exportURL) { _, url in showingExport = url != nil }
            .sheet(isPresented: $showingExport, onDismiss: { controller.exportURL = nil }) {
                if let url = controller.exportURL { ShareSheet(url: url) }
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...6)))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 110)
        }
    }
    private func dateRow(_ title: String, _ date: Date?) -> some View {
        LabeledContent(title, value: date?.formatted(date: .abbreviated, time: .standard) ?? "无")
    }
    private func errorText(_ title: String, _ error: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
    private func formatted(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
