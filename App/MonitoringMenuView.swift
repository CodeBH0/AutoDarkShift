import SwiftUI

@MainActor
struct MonitoringMenuView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Form {
            Section("切换监听") {
                Label(controller.samplingText,
                      systemImage: controller.samplingIsLive ? "waveform.path" : "info.circle")
                    .foregroundStyle(controller.samplingIsLive ? .green : controller.runtimeError != nil ? .red : .secondary)
                if let notice = controller.runtimeNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("当前业务", value: controller.activeBusinessText)
                if let snapshot = controller.displayedSnapshot {
                    LabeledContent("最近监听阶段", value: snapshot.phase.rawValue)
                    dateRow("状态更新时间", snapshot.updatedAt)
                    dateRow("采样心跳", snapshot.heartbeatAt)
                    if !controller.messageBusinessEnabled {
                        LabeledContent("心跳年龄", value: controller.heartbeatAge.map { "\(formatted($0)) 秒" } ?? "无")
                        LabeledContent("过期判定", value: "\(formatted(controller.heartbeatLimit)) 秒")
                        dateRow("最近轮询", snapshot.lastPollAt)
                        LabeledContent("实际轮询间隔", value: snapshot.lastPollInterval.map { "\(formatted($0)) 秒" } ?? "无")
                        LabeledContent("目标轮询频率", value: snapshot.activePollInterval.map { "\(Int((1 / $0).rounded())) Hz" } ?? "未采样")
                    } else {
                        Text("仅接收亮度消息，不启动轮询。没有新消息时不更新采样心跳。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let trend = snapshot.trend {
                        LabeledContent("记录使用的模型", value: snapshot.schemaVersion >= 3 ? "数学模型 v2" : "历史模型 v1")
                        LabeledContent("趋势评分 S", value: formatted(trend.score))
                        LabeledContent("亮度位置 A", value: formatted(trend.position))
                        LabeledContent("累计变化 Δ", value: formatted(trend.change))
                        LabeledContent(snapshot.schemaVersion >= 3 ? "预测贡献 V" : "历史归一化速度 V", value: formatted(trend.speed))
                        LabeledContent("变化速度", value: "\(formatted(trend.velocity)) / 秒")
                        LabeledContent("变化起始亮度", value: trend.baseline.map(formatted) ?? "等待明显变化")
                        if !controller.messageBusinessEnabled {
                            LabeledContent("动态采样", value: trend.dynamicSampling ? "进行中" : "常规 1 Hz")
                        }
                        LabeledContent("连续低速时长", value: "\(formatted(trend.quietDuration)) 秒")
                    }
                    if let sample = snapshot.sample {
                        LabeledContent("实际亮度", value: sample.brightness.map(formatted) ?? "非法输入：\(sample.rawValue)")
                        LabeledContent("数据来源", value: sample.source.rawValue)
                        dateRow("采样时间", sample.timestamp)
                        LabeledContent("采样序号", value: String(sample.sequence))
                        LabeledContent("距上次采样", value: sample.actualInterval.map { "\(formatted($0)) 秒" } ?? "首次")
                    } else {
                        Text("尚无采样记录")
                    }
                    LabeledContent("既有目标", value: snapshot.desiredTarget?.rawValue ?? "等待趋势评分")
                    LabeledContent("待处理目标", value: snapshot.pendingTarget?.rawValue ?? "无")
                    LabeledContent("配置已确认", value: controller.displayedConfigurationConfirmed ? "是" : "未确认当前编辑配置")
                    Text("监听实例：\(snapshot.instanceID)").font(.caption).textSelection(.enabled)
                    if let error = snapshot.lastError { errorText("监听最近错误", error) }
                } else {
                    Text("暂未取得运行详情")
                }
                Button("查询监听状态") { controller.queryMonitoring() }
                    .disabled(controller.busy || (!controller.messageBusinessEnabled && !controller.canReadMonitoring))
                if controller.busy { ProgressView("处理中") }
            }
            ControllerFeedbackView(controller: controller)
        }
        .navigationTitle("切换监听")
        .navigationBarTitleDisplayMode(.inline)
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
